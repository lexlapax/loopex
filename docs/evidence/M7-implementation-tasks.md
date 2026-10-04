# M7 Implementation Tasks

Execution checklist supplied by the maintainer. The accepted
[plan](../plans/M7.md#concept) and its
[technical companion](../plans/M7-technical.md#technical-depth) govern scope
and proof obligations. This checklist records work; it introduces no decisions.
Part of the [evidence index](README.md).

Progress reports use the maintainer's original T00–T19 checklist. Each task's
Original checklist section preserves its supplied items; only those checkboxes
count toward original-checklist completion. Added implementation subtasks are
tracked separately and do not increase the original denominator. An unchecked
original item may have substantial partial implementation; it closes only when
its entire stated outcome is proved.

Retired original rows use `[-]` and remain in the 186-item denominator.
They are counted separately from done and todo, never as passing evidence. The
[pre-1.0 maintainer override](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02)
retires older-version compatibility obligations; current-format proofs remain.

Run `python3 scripts/m7-task-status.py` for the current T00–T19 tally. The
[read-only reporter](../../scripts/m7-task-status.py) counts the two sections
separately and refuses missing/duplicate task headings or a changed original
186-item denominator. Historical progress paragraphs are not tally inputs.

At each task or subtask completion, report done and remaining counts for both
the original checklist and the added implementation subtasks, separately and
grouped by T00–T19. Empty added sections mean no added subtasks are recorded;
they do not mean the original task is complete. This follows the maintainer's
2026-10-01 update to the active implementation goal.

## Historical restart checkpoint — 2026-10-03, maintenance endings

The maintainer resumed the implementation goal after restarting on 2026-10-03.
Current work below records subsequent source changes and verification.

The maintainer requested a safe stop, commit and push before restarting. Product
implementation is committed and pushed on `m7` at
`ff21bed908d7213026ed55ce4c04bfdda94ad5dd`; its documentation-only child is
`007dfe94eee8d22c77b0bb95b4cbc84407909b34`. This checkpoint adds no product
changes. M7 remains In progress. No agents or maintainer decisions are pending.
Implementation is paused at this checkpoint for the requested restart. Resume
the goal explicitly on `m7` from this checkpoint and Current work below.

The exact-candidate full current-pair fast check passed all 11 application suites
in 1,394.2 measured runner seconds, 1,394 reported check seconds. Complete output:
`/private/tmp/loopex-m7-ff21bed9-fast-check.log`, SHA-256
`4220dfb2af023b1ad8ecf88ae30f59e0fb6fa32eeea8f6aa0d6ab2b5752927d2`.
Execution handle `53173` is terminal and collected. Do not poll or rerun it.
The detached verification checkout remains clean at the tested implementation
SHA. Focused current/floor and gate outputs and their inventory were rehashed;
all matched the retained digests below. No floor full check, release check or
milestone closure is claimed from this current-pair integration pass.
Post-run process inspection found no remaining check runner, suite VM or CLI
signal fixture matching the task-owned commands. The historical T16 leak
investigation remains open; this inspection does not replace its required tests.

T01–T19 originals: 51 done / 122 todo / 6 retired. Added subtasks:
172 done / 9 todo. Including T00: originals 51 / 128 / 7; added 176 / 10.
No checklist row changed during this stop. Run the checkbox reporter for the
per-task and subtask status; historical progress text is not the tally source.

First resume work is T07's live serial-owner integration. The ending/expiry
implementation now preserves the leading episode terminal and adjacent run
ending pair, rejects partial or forged transactions, settles expired first
preparation and undispatched aborts, and reuses the existing owner commit fence.
It does not yet invoke automatic episode admission from ordinary preflight,
dispatch unexpired maintenance, charge maintenance attempts, commit checkpoints
or implement standalone compact. Do not close the original T07 rows from the
focused ending/recovery proof.

The latest source/dispatch exploration was read-only. Resume from these existing
boundaries:

- `MaintenanceConfiguration.request/4` already builds the exact captured system
  instruction and source user message, tools empty, continuation nil, reasoning
  none and 1,024 output reservation. Its request has the existing nine Model port
  fields; the port has no run or turn identity. A maintenance-specific journal
  identity does not require a fictional run or a new Model port contract.
- `SessionState.compaction_units/2`, `projected_lineage/4` and
  `CompactionSource.select/4` supply eligible ordered units, bounded projection
  and complete-prefix/excerpt selection. Selection must preflight the whole
  maintenance request and honor the retained first-preparation clock.
- ADR 0043 requires distinct maintenance request, attempt and settlement kinds
  with episode identity, summary ordinal and compaction purpose. Ordinary
  `ProviderAttempt.binding_from_opened/2` and
  `Control.provider_position_binding/4` currently verify the ordinary opened
  row read from the exact journal position. Extend that verified boundary for
  the accepted maintenance identity; never accept an argument-only permit or
  write the ordinary attempt kinds for maintenance.
- Read ADR 0043's revision-4 source/receipt fields before constructing the
  maintenance staging record. Each summary dispatch consumes parent model-call
  and turn units and charges provider usage once. Retries preserve the summary
  operation identity. Successful settlement remains checkpoint-pending and
  cannot append an ordinary answer or complete the parent run. The current
  ending-prefix factory copies episode usage; update it to include the ending
  attempt's validated charge when settlement is added.

Keep all approved current contracts and the pre-1.0 current-only disposition.
Remaining work includes chat joins, helpers, protocol /3 and /4, superseded
contract removal, fixture/attempt tracking and release evidence. T16 retains
the 2,100-ms provider-launcher interrupted-wait defect, Task.Supervisor cleanup
diagnostics and CLI signal-fixture process joins. No paid provider call was made
for this checkpoint. Closure, merge to main, tags and publication remain
separate maintainer decisions.

## Historical restart checkpoint — 2026-10-02, maintenance admission

Historical checkpoint. The goal resumed after this stop; Current work below
records the active implementation and latest verification.

The maintainer requested another safe stop for restart. The goal is paused,
M7 remains In progress, and implementation is committed and pushed on `m7` at
`85e15036836f496d19860f84e7d7ece224699a2f`. This checkpoint changes only this
handoff document. No product edits followed that implementation. No agents,
check handles or maintainer decisions are pending. Resume from this checkpoint
and Current work below; earlier handoffs describe their own revisions.

The admission reducer and ordinary-terminal fence passed 53 focused tests on
each supported pair. The final source/output inventory, final gate output and
previous full-check output were rehashed before this stop; all matched their
recorded SHA-256 digests below. The full current-pair check still covers
`9e9768396d4d2a782e6ce87a56273f290bf289f8`, not the later admission source.
Run the next full check once on a clean committed live-owner integration
candidate. The detached verification checkout remains at that earlier SHA in
`/Users/spuri/.codex/worktrees/m7-trace-check/loopex`.

Process inspection found three abandoned CLI signal-fixture VMs and their
orphaned wrappers from four days earlier. Their arguments identified
`LoopexCli.AskOSSignalDriver.main()` and temporary `loopex-ask-os-signal-*`
fixtures. Only those nine fixture-owned processes were terminated; all exited
on SIGTERM, with no final kill required. No task-owned fixture process remained.
The editor language server was left running. This is cleanup of an observed
fixture leak, not a new passing proof. Investigate signal-fixture process joins
under T16 before relying on future fixture cleanup claims.

T01–T19 originals: 51 done / 122 todo / 6 retired. Added subtasks:
171 done / 8 todo. Including T00: originals 51 / 128 / 7; added 175 / 9.

| Task | Original done / todo / retired | Added done / todo |
| --- | ---: | ---: |
| T01 | 7 / 0 / 0 | 0 / 0 |
| T02 | 9 / 0 / 0 | 18 / 0 |
| T03 | 5 / 2 / 1 | 4 / 0 |
| T04 | 5 / 6 / 0 | 24 / 1 |
| T05 | 0 / 10 / 0 | 1 / 0 |
| T06 | 1 / 6 / 0 | 11 / 0 |
| T07 | 0 / 11 / 0 | 10 / 0 |
| T08 | 5 / 6 / 0 | 25 / 1 |
| T09 | 8 / 0 / 0 | 10 / 2 |
| T10 | 1 / 9 / 0 | 15 / 0 |
| T11 | 1 / 14 / 0 | 5 / 0 |
| T12 | 6 / 4 / 0 | 9 / 0 |
| T13 | 2 / 8 / 0 | 2 / 0 |
| T14 | 0 / 10 / 0 | 0 / 0 |
| T15 | 0 / 4 / 5 | 5 / 2 |
| T16 | 1 / 8 / 0 | 32 / 2 |
| T17 | 0 / 10 / 0 | 0 / 0 |
| T18 | 0 / 7 / 0 | 0 / 0 |
| T19 | 0 / 7 / 0 | 0 / 0 |

First resume work is T07's live serial-owner integration. Existing
`SessionState.propose_maintenance_episode/5` retains automatic ordinary-limit
admission and owner-succession capture. It is not invoked by the coordinator.
Source selectors, summary admission and request construction are available;
summary dispatch, maintenance-specific attempts/settlements, checkpoints,
standalone compact and complete recovery remain open.

The latest exploration was read-only. ADR 0043 requires an episode terminal
first in the same transaction as an ending run, preserving refusal/terminal or
settlement/terminal adjacency. The current fence rejects a run terminal while
maintenance is active; implement and prove the accepted complete ordering before
joining that ending path. Source-preparation expiry must derive from the retained
admission + 60,000-ms cutoff and committed run cutoff. Existing context-refusal
validation assumes no episode and re-derives ordinary-history preparation
causes, so it cannot merely accept a fabricated maintenance-expiry reason.
`commit_model_settlement` currently reads the first proposal record; review that
assumption when adding the required episode-terminal prefix. Reuse the existing
owner transaction and unknown-commit resolution before adoption/publication.
No new schema proposal from this exploration was implemented or accepted.

Keep the current-contract-only pre-1.0 disposition. All earlier explicit
maintainer approvals remain recorded below. Remaining work includes chat joins,
helpers, coordinated protocol /3 and /4, current-contract cleanup, fixture
tracking and release evidence. T16 also retains the provider launcher's
2,100-ms interrupted-wait defect and Task.Supervisor cleanup diagnostics.
No paid provider call was made while preparing this stop. Closure, merge to
main, tags and publication remain separate maintainer decisions.

## Historical restart handoff — 2026-10-02, before admission

Historical snapshot. Resume from the latest checkpoint and Current work below.

The maintainer requested a safe pause and a committed, pushed resume record.
No product edits were made after implementation `9e9768396d4d2a782e6ce87a56273f290bf289f8`.
Its full current-pair fast check passed all eleven application suites in
1,387.4 measured seconds. Complete output:
`/private/tmp/loopex-m7-9e976839-fast-check.log`, SHA-256
`9831595f0665c91833150ca5d34578a8be62c1086a6d6a84224c7524d167c9b5`.
Wrapper handle `53188` is terminal and collected; do not poll or restart it.
The clean verification checkout remains detached at that tested implementation
in `/Users/spuri/.codex/worktrees/m7-trace-check/loopex`. Subsequent primary-branch
changes are handoff documentation only. No agents or decisions are pending.
Preserve the current-only pre-1.0 override; retired originals are not passes.
The implementation goal is paused at the maintainer's request, not completed;
M7 remains In progress. Resume requires no active worker or test process.

T01–T19 original items: 51 done / 122 todo / 6 retired. Added subtasks:
170 done / 8 todo. Including T00: 51 / 128 / 7 original and 174 / 9 added.

| Task | Original done / todo / retired | Added done / todo |
| --- | ---: | ---: |
| T01 | 7 / 0 / 0 | 0 / 0 |
| T02 | 9 / 0 / 0 | 18 / 0 |
| T03 | 5 / 2 / 1 | 4 / 0 |
| T04 | 5 / 6 / 0 | 24 / 1 |
| T05 | 0 / 10 / 0 | 1 / 0 |
| T06 | 1 / 6 / 0 | 11 / 0 |
| T07 | 0 / 11 / 0 | 9 / 0 |
| T08 | 5 / 6 / 0 | 25 / 1 |
| T09 | 8 / 0 / 0 | 10 / 2 |
| T10 | 1 / 9 / 0 | 15 / 0 |
| T11 | 1 / 14 / 0 | 5 / 0 |
| T12 | 6 / 4 / 0 | 9 / 0 |
| T13 | 2 / 8 / 0 | 2 / 0 |
| T14 | 0 / 10 / 0 | 0 / 0 |
| T15 | 0 / 4 / 5 | 5 / 2 |
| T16 | 1 / 8 / 0 | 32 / 2 |
| T17 | 0 / 10 / 0 | 0 / 0 |
| T18 | 0 / 7 / 0 | 0 / 0 |
| T19 | 0 / 7 / 0 | 0 / 0 |

Resume work begins with T07's durable compaction episode. Read accepted
ADR 0043's maintenance records and checkpoint
transaction rules, then the SessionState reducer and SessionCoordinator
admission/staging/settlement paths. Existing compaction source selection,
summary admission and maintenance-request helpers are implemented, but no live
maintenance lifecycle or checkpoint/replay integration has been added. The
latest exploration was read-only. Complete explicit and automatic paths,
fixed admission cutoffs, usage-once accounting, checkpoint uncertainty and
recovery before closing original T07 items. Do not invent an unapproved public
or persistent contract.

Other unfinished work: remaining chat joins and built multi-prompt proof,
helpers, coordinated protocol /3 and /4, current-only contract cleanup,
fixture/attempt tracking and release evidence. T16 also retains the provider
launcher 2,100-ms interrupted-wait defect and Task.Supervisor cleanup diagnostic
investigation. Closure, main merge, tag and publication still require their
separate maintainer decisions. No paid provider calls were made in this pause
preparation.

## Restart handoff — 2026-10-01

Historical snapshot. Resume from Current work below and the checkbox reporter;
this handoff describes its own earlier revision.

The maintainer requested a pause for restart. Work remains on `m7`; no merge,
closure, tag or release is authorized. No delegated agents are running. The
full check process has finished; do not restart or poll its former session.
Original checklist: 25 done / 161 remaining. Added subtasks: 82 done / 11
remaining, including the two completed T16 repairs below. T01 remains the
only fully completed original top-level task.

The maintainer approved the published title-only history correction. `m7` and
`origin/m7` were advanced with an exact force-with-lease from
`7543f0776761edc73d2d218528e0258c0967ff4c` to
`1548e8c07dacd295e43de620e79b965adcf905e7`. All eleven replacement trees,
author/committer metadata and other messages match their originals. The
original history remains at local `codex/m7-before-title-fix`. The sole changed
title is `runtime(M7): prove conversation through failure and uncertainty`.
The mapping is retained at `/private/tmp/loopex-m7-title-correction.md`; its
pre-publication wording describes preparation, not the subsequent push.
Verification: `/private/tmp/loopex-m7-title-correction-verification.log`, SHA-256
`b9ff70547246dcdd1dd7da2b94bc1297ebaadd94159bcd95d63286625ce0b386`.

The full fast check ran once on unchanged commit
`1548e8c07dacd295e43de620e79b965adcf905e7` and exited 1. Preliminary gates
passed. Nine application suites passed; Core and composition each failed one
test. Complete output: `/private/tmp/loopex-m7-1548e8c0-fast-check.log`, SHA-256
`08c3964d8255e22f2af5e8e5bf842aeaeb5d3784218b8ad16923cc4d167a8d5c`.
This is failed evidence, not a successful integration check.

Both test repairs are applied in this checkpoint and pass focused verification:

- Composition's credential-plane test read seven acquisition messages although
  composition now owns eight processes. It consequently missed the final
  runtime edge. The runtime-owner failure test also read seven and silently
  omitted the runtime from cleanup assertions. Both now collect eight; the
  latter asserts that the final acquisition is Loopex and includes Transfers
  in its child-loss cases. Patch: `/private/tmp/loopex-m7-composition-owned-edges.patch`.
  Failure output: `/private/tmp/loopex-m7-1548e8c0-composition-failure.log`,
  SHA-256 `ace5d57df39332cab307fd2e3c1ca61c11c043b3d15861ee92b7647e10f47a9a`.
- Core's owner-group report test assumed the Logger application's translator
  filter existed. Isolated Core does not start Logger, so `Keyword.update!`
  received an empty filter list. The serial test now starts Logger explicitly,
  restores the filters and stops only applications it started. The actual
  supervisor-failure assertions remain intact. Patch:
  `/private/tmp/loopex-m7-owner-log-start.patch`. Failure output:
  `/private/tmp/loopex-m7-1548e8c0-core-failure.log`, SHA-256
  `1698e317a660a67d3a4f66062bdb2399dbbf63bc8ef2f93740f3cb1715c724b2`.

The complete affected files pass on both supported toolchains, with Core run
from its own application directory to exercise the Logger startup condition.
Current: two Core tests in 0.05 seconds and six composition tests in 0.3 seconds.
Floor: two Core tests in 0.06 seconds and six composition tests in 0.3 seconds.
No timeout, retry, assertion or required check was weakened. Complete outputs:

- `/private/tmp/loopex-m7-resume-owner-current.log`, SHA-256
  `8d4443374a16f3974bf383b13b449c0bfab5417aa145c7a89c7ee6bab51a6694`.
- `/private/tmp/loopex-m7-resume-owner-floor.log`, SHA-256
  `1c17a31517401409abc508636337ae354aba2155dc2e3e2ce84e2fb9e95fd2af`.
- `/private/tmp/loopex-m7-resume-composition-current.log`, SHA-256
  `5d5fb53f59b2e18894769f0f1a61774351de46aedb3924fbb675efd56bb8e8ce`.
- `/private/tmp/loopex-m7-resume-composition-floor.log`, SHA-256
  `ab3335d4e822a8c55b0293501117dde0d5acbd791b8006c798dfa5ae6bfa8fcd`.

First resume action: run the full fast check once on this committed repair
candidate, retaining the complete output and exact SHA. No full check has run
on these repaired bytes. Do not repeat the failed parent as a pass.
Then resume T02 bounded preparation and early spill, preserving its fixed
reservation/deadline rules and frozen native prefixes. The three contract
questions under Current work remain unanswered; the history-correction approval
did not resolve them. No paid provider calls were made during this check.

<a id="current-work"></a>
## Current work

- Done: audit and close original T04 item 4, file/flag precedence,
  validation and effective-value display. ConfigSelection owns flag over the
  permitted LOOPEX_HOME state-root value over file over harmless literal defaults;
  file paths remain config-relative, flags use invocation cwd, arrays replace
  earlier arrays and no-helpers only narrows delegation. Authored validation
  runs before overrides and merged relationship validation runs afterward.
  ConfigInspection resolves actual selected model/instruction/role costs before
  reporting, emits ordered escaped pointers and exact decimal quantities with
  selected origins, and excludes credential slot names/values and private
  captures. Actual command dispatch and a separate cold OS entrypoint exercise
  config validate/show without acquiring a runtime, credentials or provider call.

  The complete six file/grammar/selection/schema/inspection/duplicate-aware JSON
  suites pass all 64 cases on current in 10.5 seconds and floor in 10.4 seconds.
  Handles `14064` and `45986` are terminal and collected. Two complete logs and
  thirteen unchanged production/test source identities are retained in
  `/private/tmp/loopex-m7-t04-precedence-audit-proof-inventory.tsv`, SHA-256
  `da38203de5fca1b1c3251d1398a78ac20187f9c4baa58e91d07935c5bf9a9e18`.
  This audit changes no production or test code. T04's role/delegation retention,
  maintenance changes and remaining constructor/cleanup joins remain open;
  inspection role captures do not claim a durable helper binding.

  The documentation-only repository check passes in 19 reported seconds.
  Complete output is `/private/tmp/loopex-m7-t04-precedence-audit-docs-v1.log`,
  SHA-256 `734cc1673db0ccba4e56a397020f1418930185d987904ae1a0cb8e27ff614845`.
  Handle `58024` is terminal and collected; all fifteen inventory digests were
  reverified before commitment. No full suite is rerun for this prose-only child.

  T01–T19 originals are 69 done / 104 todo / 6 retired; added remain
  239 done / 10 todo. Including T00, originals are 69 / 110 / 7 and added
  are 243 / 11. The separate exact-0823aa50 integration run remains under
  handle `41618`; later feature tests have their own focused evidence above.

- Done: complete the feature fixture's required nil-mode question through
  actual committed model-question and explicit operator-answer records before
  any file effect. Two cases select choice-1/empty and choice-2/literal_null
  from the catalog's exact question and choices. The next Model-port request
  contains the selected answer. A real Local Executor writes only the permitted
  feature file and runs the exact pinned external runner/oracle; successful
  cleanup-confirmed receipts retain all three passing oracle assertions.
  After runtime, Store, executor and lease joins, the independent same-argv
  oracle also passes. Each oracle covers the selected default, both explicit
  modes and unchanged ordinary rows. Runner/oracle pins and complete allowed
  workspace diffs are checked around the independent run.

  The seven-case fixture-policy group passes warning-free on current in
  5.6 seconds and floor in 5.5 seconds. Handles `24348` and `41795` are terminal
  and collected. Six failed/corrected logs and the final test identity are in
  `/private/tmp/loopex-m7-feature-question-proof-inventory.tsv`, SHA-256
  `6bde8b45456471da50376c5e30b988373cfc1176fe94599f0285efbe3a3a06f1`.
  Earlier failed witnesses used a nonexistent detach facade, incorrect private
  record kinds/answer field and an incorrectly escaped generated default-argument
  expression; they remain failed evidence. Runtime-owned attachment cleanup and
  exact supervisor/process joins are retained. No production code or timeout
  changes, paid calls or attended evidence are introduced.

  Formatting, warning-free compilation, documentation ordering, status/index
  links, whitespace and the original checklist denominator pass in 15.5 seconds.
  Complete output is `/private/tmp/loopex-m7-feature-question-metadata-v1.log`,
  SHA-256 `008deea1b6e6c279785f1f8f67e3adadebba4a2e888c1f4edbbc36f2c26e29a6`.
  Handle `33447` is terminal and collected. All seven retained inventory digests
  were reverified before commitment.

  T13 original item 2 and one added proof subtask close. T01–T19 originals are
  68 done / 105 todo / 6 retired; added subtasks are 239 done / 10 todo.
  Including T00, originals are 68 / 111 / 7 and added are 243 / 11.
  The scripted Model port and explicit test-operator answers prove the fixture's
  required behavior; the separate human-attended campaign remains open.
  The exact `0823aa5061620b9506ce7399f89f5fee8c52e3d2` full fast check remains
  running under handle `41618`; its result is not claimed for this test child.

- Done: bind a private trusted M7 fixture policy through the existing chat
  composition seam, after ordinary explicit-file and closed registry-profile
  validation. The capture binds the selected case, literal argv, physical
  workspace, current tool generations and external file modes/digests into its
  policy identity. Startup and each policy decision recheck the capture.
  Alternate shell text, arguments, generations, leases, mutable paths and
  workspace-owned runner/oracle pins refuse; review refuses mutations.
  Ordinary chat supplies no fixture capture and the policy registry is unchanged.

  Effective startup settings and chat status retain the closed harness policy
  identity and manifest digest while the authored registry profile remains
  separately visible. Diagnostic admission allows harness provenance only for
  that exact four-field policy identity, preserving whole-row drop, queue,
  writer, loss accounting and cleanup bounds. Pending and already-answered
  policy questions require the independent capture's exact identity before
  activation. Changed manifests abandon the prepared capability without
  altering its journal or dispatching model/executor work.

  A real Chat/Local Store/Local Executor witness commits the repair and its
  exact approved oracle invocation, denies alternate raw shell text, checks
  the committed successful receipt and scrubbed environment, joins all owned
  processes, resumes the same session with retained tool settings despite
  changed file defaults, and independently reruns the pinned oracle after
  shutdown. Both runs execute its three assertions. File pins are rechecked
  before and after the independent run and the fixture's allowed diff is
  verified. The scripted Model port supplies no paid provider attempt.

  All 52 affected chat/configuration/fixture tests pass on the current pair in
  25.5 seconds and the floor pair in 26.3 seconds. All 20 diagnostic consumer
  cases pass on each pair in 0.8 seconds. Final handles `95446`, `45923`,
  `66091` and `51979` are terminal and collected. Failed/corrected outputs and
  seven final source/test identities are retained in the 31-entry immutable
  `/private/tmp/loopex-m7-fixture-policy-proof-inventory.tsv`, SHA-256
  `89a298d5fc26335897e2a7216833bbfee72af34edf8174cf34ceedbd8b04c036`.

  Earlier outputs remain failed evidence. Initial iterations repaired fixture
  compilation, the actual session-directory API, genesis/root context budgets,
  string-keyed settings rows and the existing cross-toolchain suite judge.
  The line-filtered v5 invocation selected a neighbouring validation case after
  formatting moved the declaration; it proves no real chat flow. Whole-file
  v13 first proves that flow. The added resume v2 cases compared against a
  baseline from before a second owner-advancing prepare; capture each exact
  prepare's baseline instead. The v3 parallel runners collided in temporary
  fixture roots because VM-local unique integers are not unique across VMs.
  Final v4 commands give current/floor processes distinct TMPDIR roots as well
  as distinct build caches. No timeout, assertion, required case or product
  guarantee was relaxed; failed outputs are not relabeled.

  Formatting, warning-free compilation, documentation ordering, status/index
  links, dependency direction, whitespace and the original checklist denominator
  pass in 16.4 measured seconds. Complete metadata output is
  `/private/tmp/loopex-m7-fixture-policy-metadata-v1.log`, SHA-256
  `8e4a17a9b015c279a4f27426f54cbde24b8a3de5628ceeacdb2a68b4a255f66c`. Handle `30912` is terminal and collected.
  Every retained output and final source digest was reverified before commitment.

  Two added T13 subtasks close. T01–T19 originals remain 67 done / 106 todo /
  6 retired; added subtasks are 238 done / 10 todo. Including T00, originals
  remain 67 / 112 / 7 and added are 242 / 11. The original trusted wrapper,
  complete fixture flows and attended campaign remain open: the root command
  and attempt-index admission must be joined before any paid execution.
  The separate transport-creation decision remains pending; this checkpoint
  implements no dependent transport change.

- Done: implement the accepted attempts-index envelope's canonical framing and
  chain verification in the private M7 evidence helper `AttemptFrames`.
  Reuse the existing protocol sorted-key JSON encoder and duplicate-aware
  configuration decoder. The exact six-field envelope covers its five unsigned
  members with SHA-256, without LF, and bounds the complete JSON object to
  65,536 bytes. Verified chains require sequence one/null predecessor and
  matching campaign, consecutive sequences and exact preceding digests.
  A trailing incomplete append returns the verified preceding head and exact
  unresolved tail as an error, including an otherwise complete JSON object
  missing its LF; it is never acknowledged as a complete index.

  Seven new tests pin an independently computed literal Python-stdlib JSON/SHA
  vector, nested ordering, exact multibyte boundary, every truncation position,
  gaps/reorder/repeated rows/forks/foreign campaigns, duplicate and escaped
  duplicate keys, changed/unknown/missing envelope fields, malformed hashes,
  unsupported implementation terms, floats, invalid Unicode, excess nesting
  and exact integers above the floating-point precision range. With the eight
  adjacent decoder cases, all fifteen pass warning-free on both supported
  toolchains, 0.06 seconds each. The first current invocation passed its seven
  assertions but emitted a compiler warning for an unpinned bitstring size;
  it remains failed warning-free evidence. Pin the existing size variable and
  retain that output beside the separate corrected proofs. Handles `39538`,
  `79707` and `9498` are terminal and collected.

  Complete failed/corrected outputs and final source/test hashes are retained
  in `/private/tmp/loopex-m7-attempt-frames-proof-inventory.tsv`, SHA-256
  `1f44753e49801211e5d280e2749ea750cac23cfa95a975cb6e722f86a49647d7`.
  This helper verifies only the already accepted frame and chain contract.
  Event-body schemas, ownership/transition admission, locked IO, fsync-before-
  dispatch, handoff, redaction and runner selection remain open. It opens no
  file, dispatches no case and supplies no authority from a valid frame.
  No campaign or new event-body schema was pinned by this implementation.

  Formatting, warning-free compilation, documentation ordering, status,
  dependency direction, staged whitespace and task-denominator checks pass in
  15.9 measured seconds. Complete immutable output is
  `/private/tmp/loopex-m7-attempt-frames-metadata-v2.log`, SHA-256
  `376c17435de7d141e1e19956188d3c5dd3d45c3c303ec178aed95f7fe440d58c`. The first metadata
  invocation correctly refused the not-yet-tracked new source at the dependency
  gate. Its complete failed output remains retained at
  `/private/tmp/loopex-m7-attempt-frames-metadata.log`, SHA-256
  `69b8f65d29530ece6f10a54f3effe05c3910680773e09691920ce4c07d6cab60`. Staging the new
  ordinary source files supplies the gate's existing prerequisite; no gate was
  changed. Handles `87879` and `12712` are terminal and collected.

  One added T14 subtask closes; all ten original T14 rows remain open.
  T01–T19 originals remain 67 done / 106 todo / 6 retired; added are
  236 done / 10 todo. Including T00, originals remain 67 / 112 / 7 and
  added are 240 / 11. No paid provider call or dependent transport-creation
  implementation has begun. M7 remains In progress.

- Done: the single full current-pair fast check of clean committed
  `217b8b90a455aa4ccb3fbd2aae668fbe33405811` passes all eleven applications,
  3,814 cases with 44 exclusions, in 1,015.7 measured wrapper seconds and
  1,016 reported check seconds. Complete immutable output is
  `/private/tmp/loopex-m7-217b8b90-fast-check.log`, SHA-256
  `eb1b710379d9e7acd90acd9fccf004b07d642fe2799f6ec7fe04fd3b31753fe9`.
  Handle `74828` is terminal and collected. This proves the repaired current
  candidate; the preceding c45af182 full run remains FAIL. The detached
  verification checkout is clean at the tested SHA. No floor full check,
  release matrix, attended witness or milestone closure is claimed.

  Audit the original checklist against that candidate's implementation and
  actual tests. T12 items 1 and 2 close: the closed startup options and captured
  v3 configuration forward instructions, canonical model/reasoning, provider
  references, maintenance, question and trace selections. Real startup checks
  inspect the admitted Core coordinator's exact maintenance instructions/model
  and route references. Public embedded-session HTTP cases preserve the exact
  host system text through two prompts and beyond the startup ticket, plus
  question/trace continuation and bounded actor joins. The ReqLLM wire cases
  retain buffered responses, one request per call, native provider controls,
  verified local TLS and synthetic selected-key checks. Credential cleanup's
  separate production-cutoff/release guarantees and the attended question
  witness remain open under T12 items 9 and 10.

  T15 item 2 closes: the actual Local Store/Executor restart cases inject a
  fault after the effect receipt and before the public fact, then either
  reconcile the exact receipt or remove its file and report outcome_unknown.
  The first executor dispatches once; the successor dispatch map stays empty.
  Workspace bytes, once-only public events, solicited identity validation and
  exact owned-process joins are checked. Current-format backup/restore remains
  open; this closes only the nonredispatch guarantee.

  Current-pair evidence comes from the exact candidate's passing complete
  Composition, ReqLLM and ReferenceClient suites. Additional floor-toolchain
  audits pass 67 option/preflight/public-model/trace cases in 42.2 seconds,
  eighteen real-startup cases in 17.7 seconds, five buffered wire cases in
  5.8 seconds and 21 ReferenceClient cases in 4.0 seconds, with two existing
  real-provider exclusions. The first floor ReferenceClient invocation could
  not start Mix.PubSub because sandbox TCP access returned eperm. It ran no
  tests and remains an environment failure; the separately named authorized
  local-TCP invocation supplies the passing proof. All six complete outputs
  and ten audited source hashes are retained in
  `/private/tmp/loopex-m7-original-support-audit-proof-inventory.tsv`, SHA-256
  `41e952867c01f9157e4eff85170ed48a43e2fddf27580290121ed206c5fbb9c9`.
  Handles `64314`, `11167`, `7815` and `49567` are terminal and collected.

  The documentation-only checkpoint passes formatting, warning-free
  compilation, structure/status/dependency gates and documentation ordering
  in eighteen reported seconds. Complete immutable output is
  `/private/tmp/loopex-m7-original-support-audit-docs-check.log`, SHA-256
  `df8f302f5b2d350d0f14062a0c943706ec3f71ae2677056bfd4199b9fcb52834`. Handle `89701` is terminal and collected.

  Three original rows close, with no added subtask or denominator changes.
  T01–T19 originals are 67 done / 106 todo / 6 retired; added are
  235 done / 10 todo. Including T00, originals are 67 / 112 / 7 and added
  are 239 / 11. No product source changed during this evidence audit.
  The transport-creation decision remains pending, separately from the
  maintainer's accepted durable view. No dependent transport work or paid
  provider call has begun. M7 remains In progress.

- Done repairs after failed integration: the single full current-pair fast
  check of clean committed `c45af18217a34d70a50d31e031c06afe49f4bc3f`
  completed with exit 1. All eleven applications ran: 3,808 cases pass, six
  fail and 44 are excluded. Core has three binding-read fixture failures;
  ReqLLM has three packaged-host fixture failures. All nine other application
  suites pass. Complete immutable output is
  `/private/tmp/loopex-m7-c45af182-fast-check.log`, SHA-256
  `f60887cfddd9de590fe8be0947472c01c144d3f3211acf5f0043a6f636b306c6`.
  Its last progress clock reports 1,018 seconds; the CLI suite reports 677
  seconds. Handle `81426` is terminal and collected. This candidate remains
  FAIL and will not be rerun into a pass.

  The binding-read fixture selected any one-record page and therefore held a
  snapshot's genesis read rather than Control's provider-attempt binding.
  Target the actual `model_attempt_opened_v1` row within the existing Store
  callback, retaining the exact session and journal position in the observer
  message. The timeout case now additionally joins that exact killed reader.
  All seven original regression cases pass on both pairs, 6.9 seconds each,
  with the original 700-ms authority, 800-ms hold, 1,000-ms read allowance,
  cleanup waits, sibling progress and supersession/effect assertions unchanged.
  No production source or public contract changes.

  The packaged-host fixtures still expect the superseded compiled system
  instruction and an undated response identity for the captured dated Haiku
  alias. Migrate their independent exact request oracle to current host
  instructions/environment and current alias/reply identity. Retain real
  production escript builds, plain OTP extraction, catalog controls, ambient
  dotenv negatives and separate application-startup checks. Driver compilation
  deliberately lacks the host graph; runtime API invocation replaces static
  undefined-function calls without disabling warnings. Paired packaged v1
  passes three of five cases and fails two on each pair, current 109.5 and
  floor 107.0 seconds. Those remaining exact-body failures expose superseded
  string-form Anthropic messages and an explicit false stream field. Pin the
  current registered Haiku's native text blocks and absent buffered stream
  control separately from the current generic unknown-model route. Keep both
  v1 outputs and fixture-source copies as failed evidence. V1 handles `99770`
  and `63492` are terminal and collected. Corrected v2 passes all five cases
  on both pairs, current 114.9 and floor 116.9 seconds. All original routes,
  including unknown-model generic rendering, and catalog/startup controls remain
  covered. Builds use the exact archived c45af182 production source; the final
  separately compiled test/driver bytes are retained by digest. V2 handles
  `62841` and `55925` are terminal and collected. No production request,
  credential, catalog, cleanup or packaging behavior was changed.

  The twelve focused cases pass on each pair. Complete outputs, failed v1
  sources and final verified fixture hashes are retained in
  `/private/tmp/loopex-m7-current-host-fixture-proof-inventory.tsv`, SHA-256
  `42dc63b4294c1f9aebbc4b102de466523cb40a4c074225df841f7756c4fd40b3`.
  The original failed full candidate is not relabeled. Commit/push these
  repairs and run one full fast check from the new clean exact candidate.

  Formatting, warning-free compilation, compiled documentation ordering,
  status/index links, dependency direction, whitespace and the original task
  denominator pass in 18.9 measured seconds. Complete immutable metadata output
  is `/private/tmp/loopex-m7-current-host-fixture-metadata.log`, SHA-256
  `6b647f8e5ca67e95e77df57d6c8466635cbfdf57a913748746b146c9a63cf61a`.
  Metadata handle `83166` is terminal and collected; both Core proof handles
  `63637` and `11414` are terminal and collected. All twelve retained output
  and source digests were verified against the inventory before commitment.

  Two added T16 repairs close. Original T01–T19 counts remain
  64 done / 109 todo / 6 retired; added counts are 235 done / 10 todo.
  Including T00, originals remain 64 / 115 / 7 and added are 239 / 11.
  Transport creation still awaits
  the separately retained maintainer decision. No dependent transport work
  or paid provider call has begun.

- Done: complete the physical Local Store crash campaign for both automatic
  and standalone maintenance. Thirty cases kill the actual Store at five
  boundaries, preparation capture, request/open staging, settlement,
  checkpoint and publication, at each of before-linearization,
  after-linearization-before-result and exact recovery re-presentation. The
  existing Local fault probe changes no stored frame, receipt, clock or
  authority. Independent reopened-record checks pin the precise preceding or
  committed record kind, raw record/event prefixes, atomic outbox, once-only
  summaries/checkpoints/settlements/charges, safe continuation, conservative
  failure without ambiguous redispatch, stale-writer recovery and exact result
  replay. Runtime, Store, model, executor and probe actors are joined.

  This exposed and repaired a cleanup-truth defect: a run-owned episode
  inherited an unsettled provider attempt yet reported confirmed cleanup.
  Derive uncertainty from the authenticated attempt-owner epoch and retained
  owner-loss/abort/deadline settlement, using the existing unknown result
  variant. Parent outcome, spending, result keys, persistent fields and limits
  stay unchanged. Seven existing successor cases now pin inherited open,
  abort and deadline cleanup as unknown, preserve completed-reply/source
  cleanup, and reject both directions of forged cleanup during strict replay.
  This corrects implementation of the existing cleanup invariant; it adds no
  public or persistent schema and no compatibility fallback.

  Final paired proof passes all 313 ordinary Core maintenance cases, with the
  two existing production-cutoff exclusions, in 14.1 current / 13.6 floor
  seconds. The 30 new crash cases, two physical reopen cases and eighteen
  adjacent creation/question cases pass all 50 in 19.3 current / 17.8 floor
  seconds. Complete outputs, including fixture/expected-refusal errors, the
  reproduced production defect and warning-gate failures, are retained in
  `/private/tmp/loopex-m7-maintenance-local-crash-proof-inventory.tsv`, SHA-256
  `d896bf0a449566a07506bd08541181da5e4415f9075cad75a7ca9dd266193ec8`.
  A run with passing test assertions but compiler warnings remains FAIL;
  generated-case predicates now expand before function compilation and both
  pairs remain warning-free. No cutoff was inflated and no check was relaxed.

  Original T07 item 10 closes, plus two added subtasks for the disk campaign
  and cleanup repair. T01–T19 originals are 64 done / 109 todo / 6 retired;
  added are 233 done / 10 todo. Including T00, originals are 64 / 115 / 7 and
  added are 237 / 11. Item 11 remains open for complete current-surface
  preservation; coordinated transport generation and real-provider long
  conversation remain open. The transport-creation decision below is still
  unanswered. Next verification is one full current-pair fast check from the
  clean committed integration candidate, preserving all complete output and
  its exact SHA. This paired component proof is not a full fast/release or
  closure matrix result.

  Formatting, warning-free compilation, compiled documentation order,
  status/index links, dependency direction, whitespace and the unchanged
  original-checklist denominator pass. Complete output:
  `/private/tmp/loopex-m7-maintenance-local-crash-metadata.log`, SHA-256
  `54f1cf187bb8ff007e2f638b4d8cc5b492c100cd89ca5c5207c86ffad35d5af7`.
  Final Core handles `91039`/`88753`, composition handles `75909`/`37345`
  and metadata handle `97430` are terminal and collected. The attached
  `m7-trace-check` verification checkout was inspected clean and detached at
  `a160e5b073206fa453f208c569012ddf6e4f8402`; reuse it for the candidate's full
  check after switching to that exact committed SHA. Keep the pending
  transport decision separate from this independent completed work.

- Done: prove standalone and automatic compaction through a physical Local
  Store close, reopen and public session resume. The new composition cases use
  the actual disk Store and public commands, with the reusable scripted Model
  port as the provider witness. They retain exact raw record/event prefixes and
  log bytes, recover the complete checkpoint/configuration/usage/deadline state,
  replay the standalone command result, and dispatch the next ordinary prompt
  with the exact retained summary provenance. All runtime, Store and fixture
  actors are new on reopen. No summary redispatch or duplicate checkpoint/event/
  maintenance charge occurs, and every actor is stopped and joined.

  The two new cases and eighteen adjacent durable-creation/question-restart
  cases pass on both pairs: 20 current in 9.9 seconds and 20 floor in 9.6
  seconds. Initial fixture failures remain retained: the first automatic
  genesis used a system ceiling above its context ceiling; the corrected
  genesis then exposed an irreducible oversized current input. The fixture now
  selects a current input that fits while the combined history overflows.
  Product admission limits and all original test cutoffs remain unchanged.
  The initial sandbox Mix TCP-lock failure is evidence unavailable, not PASS.

  Complete immutable outputs and the final test-source digest are retained in
  `/private/tmp/loopex-m7-maintenance-local-restart-proof-inventory.tsv`, SHA-256
  `6679af81621ed3edacceed2d866a948f52d7deacf15e80dfe2c2a5e091a29124`.
  One added T07 subtask closes. T01–T19 original counts remain 63 done /
  110 todo / 6 retired; added counts are 231 done / 10 todo. Including T00,
  originals remain 63 / 116 / 7 and added are 235 / 11. The two broader T07
  originals remain open for physical Store/process crash cuts and complete
  current-surface preservation; real-provider long-conversation and closure
  evidence remain separate. The transport-creation decision below is still
  unanswered. This proof introduces no dependent transport implementation.

  Formatting, warning-free compilation, compiled documentation ordering,
  status/index links, dependency direction and both staged/unstaged whitespace
  checks pass. Metadata outputs are retained in
  `/private/tmp/loopex-m7-maintenance-local-restart-metadata-inventory.tsv`,
  SHA-256 `2dddfa53f3c4c2bd70ca17b43cf7f1b7210f6202de2f8612e0d5b9344812e2a6`.
  The first metadata invocation used the nonexistent `loopex.docs` task after
  successful format/compile; the remaining commands then passed using the
  actual `loopex.docs_check` task. Neither invocation is a full fast/release
  check. Test handles `24508` and `9873` and metadata handles `93179` and
  `84948` are terminal and collected. Next independent work is the persistent
  Local Store crash matrix at the declared transaction fault points, preserving
  exact unknown-commit identity, dispatch permits, writer fencing and original
  cleanup bounds.

- Done: audit the original T07 checklist against the complete current
  maintenance implementation at clean
  `1259d0df62e5de649b3cf0c14f61bc7e0ec51eea`. Owner-selected bounded excerpts,
  frozen dispatch capture, absent/invalid summarizer distinction, complete
  natural output and progress admission, bounded attempts/terminal results,
  uncertainty before publication and once-only usage, and the required
  oversized/small/trailing/omission/length/non-progress cases are implemented
  and proved. The evidence map below ties each original row to its actual
  source and tests rather than inferring completion from added-subtask counts.

  All twelve current Core maintenance/source/standalone files pass 313
  ordinary cases on each pair, with two production-cutoff lane exclusions:
  current 14.2 seconds, floor 13.5 seconds. Both excluded cases were then run
  explicitly with `--only long_bound`: two pass on each pair, current 126.8
  seconds and floor 126.1 seconds. Captured 60,000-ms deadlines, exact worker
  joins, retained checkpoints/raw facts/usage and original fixture grace stay
  unchanged. This is focused proof, not a complete release run.

  Complete immutable outputs and the pending transport proposal are retained in
  `/private/tmp/loopex-m7-t07-original-audit-proof-inventory.tsv`, SHA-256
  `8c19ddf0f3d111663e17c2a3df276c8cf7761155ed5ef5deed864fc697741188`.
  Seven original T07 boxes close; its two broader persistent-Store fault and
  end-to-end preservation proofs remain open. T01–T19 originals are now
  63 done / 110 todo / 6 retired; added counts stay 230 done / 10 todo.
  Including T00, originals are 63 / 116 / 7 and added are 234 / 11.

- Pending maintainer decision: select the entry point for host-captured v3
  transport creation settings. Recommended constructor context supplies
  initial_configuration, immutable tool_selection, policy_defer_mode and
  runtime_configuration.cleanup_grace_ms alongside the runtime to foreground
  and daemon constructors. Core gains no default-setting state; transport
  embedders update constructor calls. Alternative runtime defaults add the same
  bounded plain template to Core startup and implicit creation, retaining
  simpler transport constructors but adding a public runtime option and
  per-runtime defaults. Both preserve exact metadata/genesis identity,
  historical no-activation replay, unknown-commit fences, original relay
  dispositions and cleanup bounds. Hosts resolve model facts/instructions;
  neither admits client-authored capability facts, credential references or
  superseded genesis. The public/cross-app contract needs approval under
  AGENTS.md and the repository ADR skill. The one unanswered question and its
  concrete proposal are retained at
  `/private/tmp/loopex-m7-transport-creation-decision.md`; dependent transport
  implementation has not begun. The T07 audit is independent of that decision.

- Done: durable `ask` captures complete current v3 genesis before placement or
  credential custody. Composition owns adapter defaults, capability resolution
  and compiled tool definitions; the command forwards prepared plain data. The
  approved public create receives the canonical model, exact captured reference
  instructions, derived context capacity, reply reserve and immutable selected
  tools together. Runtime composition uses the same model and capacity. No
  credential reference or value enters genesis.

  Cases prove capture refusal before later authority, all three tool profiles,
  exact retained creation through the real public facade and Local Store, and
  Store reopen/resume despite changed runtime context defaults. The remaining
  workflow, trace, resource-admission and cleanup cases keep their existing
  bounds. The old CLI ephemeral resource-fault fixture now prepares current
  genesis before owner activation and supplies it to its fake facade, so it
  reaches the original catalog/activation fault again.

  Final focused CLI proof passes 42 cases on the current pair in 30.7 seconds.
  Floor proof passes the same 41 workflow cases in 30.1 seconds and the
  command-boundary case separately in 1.4 seconds: the floor Mix line selector
  selected only that one case when combined with unqualified files. Durable
  composition/provider-binding cases pass 30 each in 15.8 current-pair and
  13.8 floor-pair seconds. Formatting, warning-free compilation, documentation,
  status and dependency checks pass.

  The first complete CLI runs remain FAIL: 548 of 550 cases passed on current
  in 663.0 seconds; floor reported 554 tests, two failures and six exclusions
  in 682.1 seconds. Both failures were the superseded ephemeral fixture and
  the new command's concrete-adapter imports. The fixture was migrated and
  capture moved into composition without changing the boundary check. Corrected
  focused cases prove both repairs; no corrected complete CLI or eleven-app,
  release or closure result is claimed. Earlier focused failure output is also
  retained. No paid provider call was made.

  Exact source hashes and eleven complete outputs are retained in
  `/private/tmp/loopex-m7-durable-ask-genesis-proof-inventory.tsv`, SHA-256
  `abc5184c79b5e71fd8951c01624456a55fbe542c388f95ddcebfd97e1d7f1e7f`.
  This closes one added T04 host-migration subtask. T01–T19 originals remain
  56 done / 117 todo / 6 retired; added counts are 230 done / 10 todo.
  Including T00, originals are 56 / 123 / 7 and added are 234 / 11.
  Transport and older command creation paths still need current genesis before
  Core v2 readers/writers and the instruction fallback can be removed. No
  maintainer decision is pending; M7 remains In progress.

- Done: ephemeral preflight now prepares complete current v3 genesis before
  owner activation. The accepted startup instructions, reasoning and system
  ceiling options pass through the shared configuration validator. Omitted
  context capacity derives from captured model limits; explicit capacity stays
  explicit. The canonical model identity, exact instructions, cleanup grace and
  immutable selected tools/name bindings are retained together. The private
  facade actor forwards that exact genesis through the approved public create
  API, and runtime registration uses the same retained definitions.

  Reference instruction capture moved from CLI into composition; chat,
  inspection and ephemeral startup use that one implementation. The old CLI
  module and old private actor arities are removed. Actual local HTTP requests
  prove the exact host system bytes across two prompts. Boundary cases prove
  closed startup grammar, unsupported reasoning, system-cost refusal before
  owner allocation, derived/explicit origins, route privacy and refusal of an
  oversized default workspace/question capture without silently raising 1,000.

  Current-format fixture preparation now precedes owner activation. Startup,
  call-owner loss, exact duplicate creation, question responder joins, hosted
  credential isolation, unknown-root and cleanup cases retain their existing
  time bounds. The old one-token failed-run fixture cannot pass current whole
  configuration admission; it now admits a 1,024-token context and submits a
  larger prompt, retaining the same real failed-run projection, exact observed
  limit, last-result and successful cleanup assertions. Question lifecycle
  fixtures explicitly select short instructions within the unchanged 1,000
  system ceiling. The hosted Anthropic fixture now returns the admitted dated
  model identity required by the current native decoder, replacing its old
  generic model marker. No production limit or decoder was weakened.

  Final complete composition suites pass 502 cases on each supported pair,
  with the real-provider case excluded: 273.5 current-pair and 266.8 floor-pair
  seconds. The affected chat/configuration/inspection cases pass 39 each in
  20.9 and 20.6 seconds. Formatting, warning-free compilation, documentation,
  status and dependency-direction checks pass. Earlier five/one-case focused
  failures and the 16-case first complete failure remain retained; their
  obsolete fixtures and the new fixture's nonexistent validation call were
  corrected before the final paired runs. All task-owned execution handles are
  terminal and collected. No paid provider call or full eleven-application,
  release or closure result is claimed.

  Exact source hashes and ten complete outputs are retained in
  `/private/tmp/loopex-m7-ephemeral-genesis-proof-inventory.tsv`, SHA-256
  `1ecfd5f09c9e06a7f8c5e9791e3342c1908bfc195e0bd3776502885ada76b9e3`.
  This closes one added T04 migration subtask. T01–T19 originals remain
  56 done / 117 todo / 6 retired; added counts are 229 done / 10 todo.
  Including T00, originals are 56 / 123 / 7 and added are 233 / 11.
  Durable ask and transport creation still need prepared current genesis before
  Core's v2 writer/reader and instruction fallback can be removed. No maintainer
  decision is pending; M7 remains In progress.

- Done: the thin embedded reference client now requires complete current v3
  genesis and forwards its original options and exact retained payload through
  the approved public creation API. It refuses options-only and superseded
  input. Host preparation remains outside this client; no runtime settings,
  capabilities or instructions are inferred by its production code.

  Its reference fixtures explicitly capture instructions, model facts, reply
  and context bounds, cleanup grace and immutable tool/name bindings. Real
  provider fixtures use the existing capability/mapping capture; deterministic
  adapters retain explicit fixture provenance. Record readers now require
  configuration-bound prompt and request kinds, including the retained real
  provider witness. The new case proves exact genesis retention, refusal of
  missing configuration or forged name bindings without consuming the command,
  and same-command duplicate creation with one retained genesis.

  The complete credential-free reference-client suite passes all 21 cases on
  both supported pairs, in 3.8 current-pair and 3.6 floor-pair seconds. Both
  real-provider cases remain excluded and unproved here. Current-format real
  Local effect/restart, prepared activation, receipt reconciliation and cancel
  recovery cases pass without changing their bounds. Formatting, warning-free
  compilation, documentation, status and dependency checks pass. The first
  runnable suite failed two old record-kind assertions; those readers were
  migrated before the final paired runs. The sandbox TCP-lock failure remains
  unavailable evidence, not a passing run.

  Complete run outputs and exact source hashes are retained in
  `/private/tmp/loopex-m7-reference-genesis-proof-inventory.tsv`, SHA-256
  `21f5306e167b6ae8ba289b522cefa42467511c515049389d8d198dfd3b3bc504`.
  This closes one added T04 migration subtask. Original T01–T19 counts remain
  56 done / 117 todo / 6 retired; added counts are 228 done / 10 todo.
  Including T00, originals are 56 / 123 / 7 and added are 232 / 11.
  Ephemeral, durable ask and transport creation still need prepared current
  genesis. Core's v2 writer/reader and instruction fallback remain open until
  all their callers migrate. This is focused evidence, not a full integration,
  release or milestone-closure result. No maintainer decision is pending.

- Done: shared Elixir and independent Node codecs now pin the complete
  revision-3 snapshot and its closed pending-question projection. The snapshot
  has ten fixed members: the existing session/cursor/run/phase fields plus
  required current configuration, nullable checkpoint, active maintenance,
  pending interaction and last compact completion. Semantic revision 3 remains
  an integer; observed quantities retain exact decimal domains. There is no
  old-revision or unresolved-configuration branch. All nested definitions are
  included in the literal schema, including both maintenance bound variants.

  Pending questions preserve explicit model_tool versus policy_defer producer,
  choice versus text kind, original opaque identities, ordered choices, exact
  turn and uint64 expiry. The public pending projection carries no response,
  command digest or private policy handle. Snapshot consistency checks cover
  run/phase pairing, question/run identity and maintenance exclusion, actual
  maintenance owner and configuration version, checkpoint version ordering,
  and the empty cursor-zero views. Literal files pin 74 question and 47 complete
  snapshot cases; independent Node proves 21 complete identity/UTF-8 boundaries.

  The final complete protocol suite, including nine Node cases, passes all 127
  tests on both supported pairs in 0.3 seconds each. Formatting, warning-free
  compilation, documentation, status and dependency-direction checks pass.
  The first metadata run rejected generic module dispatch and untracked new
  sources. Explicit codec calls and staging resolve those checks without
  changing any bound; both protocol suites pass on the resulting source. All
  initial/final outputs, including the failed metadata run, are retained in
  `/private/tmp/loopex-m7-snapshot-codec-proof-inventory.tsv`, SHA-256
  `f3f382283c60166d7055e94311b5c6dbbc062c8dbba8d516fd54956f414bd4db`.

  One added T05 subtask closes. T01–T19 originals remain 56 done / 117 todo /
  6 retired; added subtasks are 227 done / 10 todo. These codecs are prepared
  components, not yet the served snapshot or connection validators. The next
  integration must supply current v3 genesis configuration, retire the existing
  v2 writer/reader and fixtures under the pre-1.0 rule, publish the cursor
  projection, complete both payload manifests and switch only foreground /3
  and daemon /4 together with all consumers. Configure/compact routing,
  authority inventories and independent live workflows remain required; do not
  claim the old revision-2 snapshot or metadata-only digest satisfies M7.
  No agent, check handle or maintainer decision is pending at this checkpoint.

- Done: the bounded snapshot scan now retains latest configuration and
  checkpoint provenance at the same event cursor as run, question, maintenance
  and last compact. Initial configuration comes from exactly the immutable
  first private genesis row inside the existing attachment scan worker;
  subsequent changes come only from the acknowledged public outbox. Recovery
  independently compares reduced configuration and checkpoint identity with
  private state. Closed configuration changes require the next version and a
  settled prefix. Checkpoints require the captured episode/owner/model/version,
  the correct prior identity and inherited omission, excluding summaries and
  raw source records. Only current and requested-anchor projections are kept.

  Model-question attachments now retain producer and question kind. All three
  existing choice/text/decline vectors prove pending attachment, the same
  historical cursor after terminal settlement, and null at the terminal cursor.
  Four new tests cover every cursor/page width through configuration and
  checkpoint changes, exact large versions, privacy canaries, ownership/capture
  mismatch, version gaps, prior-chain and omission refusal. The 20-file
  configuration/maintenance/question/attachment/recovery selection passes
  373 tests with two long-bound exclusions on each pair, in 23.3 current / 22.9
  floor seconds. After aligning the snapshot kind with the existing public
  interaction view, the three model-question cases pass again in 1.9 / 1.7
  seconds. Complete outputs, including the initial failed new-fixture run, are
  inventoried in `/private/tmp/loopex-m7-cursor-projection-proof-inventory.tsv`.
  Its SHA-256 is
  `0e9eecb8e8773dc30e34da26a4d652179d8843fe8bc905c709be27e09ac3d441`.
  The first run's three new-fixture failures used duration_ms instead of the
  accepted deadline_ms; correcting the fixture changes no required bound.
  An earlier focused development run also identified the accumulator inventory
  needing its two newly retained fields. No retry of unchanged failing bytes
  counts as proof.

  One added T05 subtask closes. T01–T19 originals remain 56 done / 117 todo /
  6 retired; added subtasks are 226 done / 10 todo. The public snapshot still
  emits revision 2; publishing the new projections, complete protocol manifests,
  negotiated foreground /3 and daemon /4, and independent live workflows remain
  open. No full integration, release or closure result is claimed for this unit.
  Repository formatting, warning-free compilation, documentation ordering,
  status and dependency-direction checks pass; their collected terminal output
  is `/private/tmp/loopex-m7-cursor-projection-metadata-v1.log`, SHA-256
  `9a00b8df50ad1dbb7034b2185ab25ca140e84e3a18c13a290185dc3016d4d3cc`.

- Done: closed configuration/change and complete checkpoint codecs now share
  the accepted native projection with future snapshot and event consumers.
  Configuration carries seven public settings/provenance members, exact
  positive version and positive uint64 ceilings; no instruction body, capability,
  provider or credential map is admitted. Checkpoint carries the twelve existing
  public members, actual run/compact owner, three original-source reference
  variants, exact coverage/accounting and inherited source_excerpted. Summary,
  consumed source and private recovery fields refuse. The strategy revision
  remains the literal integer 3, distinct from decimal quantity fields.

  Complete schemas and 123 configuration/change plus 259 checkpoint vectors
  have pinned byte identities. Independent Node decoders retain BigInt counts
  and opaque Buffers; 34 full-byte checks exercise every identity position,
  model UTF-8 and instruction-version boundaries. Both supported pairs pass
  the complete protocol suite including eight Node cases: 120 tests in 0.3
  seconds. The serial reducer validates both actual native projections before
  retaining their existing event shapes. Configuration, compaction, owner
  recovery and uncertainty tests pass 352 on each pair, with two long-bound
  exclusions, in 19.0 current / 18.5 floor seconds. Complete outputs and digests
  are retained in `/private/tmp/loopex-m7-snapshot-payload-proof-inventory.tsv`,
  SHA-256 `5859f4e8bdac98ebaaac01409462a8b6030094ea05cb65530e71931961bde026`.
  An initial format command used a root-relative path from the application
  directory and stopped before tests; formatting from the root corrected it.
  All actual test runs pass. The codecs are not yet joined to generation-3/4
  wire emission or expanded snapshots. No new full integration or live client
  workflow is claimed by this focused component proof.

  One added T05 subtask closes. T01–T19 originals remain 56 done / 117 todo /
  6 retired; added subtasks are 225 done / 10 todo. Next is same-cursor
  configuration/checkpoint/question reduction and the complete negotiated
  protocol join. No agents or maintainer decisions are pending.

  Repository metadata checks pass in
  `/private/tmp/loopex-m7-snapshot-payload-metadata-v2.log`, SHA-256
  `f1e7dc7c8cfded05775d56301c0dcaf5c80a566476bee55d50a24c483e0b4fb7`:
  formatting, warning-free compilation, documentation, status and dependency
  direction. The initial formatting check requested a new test's argument
  layout; its failed output remains
  `/private/tmp/loopex-m7-snapshot-payload-metadata-v1.log`, SHA-256
  `b67e3e10e83646f3825a7d3b75bf0ab57cff38d9af38d09d4924c2db73622d9e`.
  The layout correction changes no assertion or bound.

- Done: clean pushed source `1c9ac8c8a552afa55d92bea8e117cf3b4dba7cc4`
  passed its one full current-pair fast integration check. All eleven suites
  pass: 3,759 tests with 42 lane-selected exclusions. The suite step took
  843 seconds and the runner took 918 seconds. Complete immutable output
  `/private/tmp/loopex-m7-1c9ac8c8-fast-check.log`, SHA-256
  `6ee6426b6a1f48b5322eaa000dd935d6cb67a81e19d122b2651f96858c14ecad`.
  Execution handle `83415` is terminal and collected. Do not poll it or rerun
  the full check on these bytes. This evidence-only child changes no source.
  Focused current/floor and independent Node proofs are retained below; no
  floor full check, selected live maintenance workflow, full release check or
  milestone closure is claimed. T01–T19 originals remain 56 done / 117 todo /
  6 retired; added subtasks are 224 done / 10 todo.

  Next: complete the closed configuration, checkpoint and interaction
  projections and publish the expanded snapshot with the coordinated
  foreground /3 and daemon /4 manifests, negotiation and Node workflows.
  The scan already reduces maintenance and last compact at its public cursor,
  but `public_snapshot` still emits revision 2 and both attachment mappings
  still use its previous shape. Initial configuration belongs to immutable
  genesis; subsequent configuration belongs to the public outbox. Do not read
  mutable current private state for an older attachment cursor. All broader
  original tasks and the separate T16 cleanup investigations remain open.
  No agents, check handles or maintainer questions are pending. The goal stays
  active on `m7`; closure, merge to main, tags and publication are separate.

- Done: share the existing three-member compact completion across the serial
  writer, both event transports and independent Node connection validators.
  The shared result codec now encodes/decodes required opaque episode/command
  identities beside the entire closed result union. A literal complete schema
  and 160 vectors pin nested result definitions, privacy refusals and exact
  quantities. Both outer identity ceilings receive full-byte boundary checks.
  The existing paged scan retains just the latest completion at the requested
  cursor, preserving the previous result during a new episode. Duplicate last
  completions and completion overlapping maintenance, runs or questions refuse.
  Public snapshot publication and generation-3/4 negotiation remain open.

  Owner/recovery/cursor tests pass 190 cases on each supported pair in 14.0
  seconds. The complete protocol suite, including all seven independent Node
  cases, passes 114 on each pair in 0.3 seconds. Foreground projection passes
  10 on each pair in 0.5 seconds; daemon projection passes 5 on each pair in
  0.04 seconds. Complete outputs and their SHA-256 digests are retained in
  `/private/tmp/loopex-m7-compact-completion-proof-inventory.tsv`, SHA-256
  `fd01f3dcb6c0710c39d531cd316d9c671071c77439187ae16582c57e78bd9057`.
  The inventory preserves both initial transport failures. Their new fixture
  filter used boolean `not` on nil; an explicit nil test fixes the fixture
  without changing production code or the refusal proof. An initial format
  command also used repository-relative paths from an application directory
  and failed before tests; the root-directory command corrected those paths.
  This closes one bounded added T05 subtask. T01–T19 originals remain
  56 done / 117 todo / 6 retired; added subtasks are 224 done / 10 todo.
  The full integration result for the combined scan/completion source is
  recorded above at its exact source commit.

  Formatting, warning-free compilation, documentation, status and dependency
  checks pass in `/private/tmp/loopex-m7-compact-completion-metadata-v2.log`,
  SHA-256 `b0f3ae4c79903fca991bb806078178051bb9377fdb1441d4b967339b6139e9d9`.
  The initial root formatting check found a new test's argument layout before
  compilation; its failed output is retained at
  `/private/tmp/loopex-m7-compact-completion-metadata-v1.log`, SHA-256
  `f20e79810774b5151a9d6f3d26dc3a10b9ed6d5124c0a9090ff1813598150572`.
  The corrected layout changes no assertion or bound.

- Done within the open T05 snapshot join: the existing paged scan retains one
  maintenance view at its tail and one at the requested public cursor. Both
  actual owner kinds use the closed native codec. Duplicate unchanged rows,
  episode/owner replacement, mismatched runs and overlapping questions refuse.
  Recovery compares that public reduction with its independent private replay.
  The expanded public snapshot is not emitted yet; generation-3/4 publication,
  manifests and independent live workflows remain open. No checklist row closes
  from this internal scan step, and task counts remain unchanged.

  Focused maintenance, source, recovery and attachment tests pass on both
  supported pairs: 320 passing with two long-bound exclusions. Current time
  13.7 seconds, output `/private/tmp/loopex-m7-maintenance-scan-current-v2.log`,
  SHA-256 `3afc432fe48ef75dc73502d73fe529a146fca9606fb0baee9d22b6e7272e7659`;
  floor time 13.0 seconds, output
  `/private/tmp/loopex-m7-maintenance-scan-floor-v2.log`, SHA-256
  `ea64eb8228a74e4516583ef15a15b644f3149b872426769584c55a9f1fb8436f`.
  Six new reducer tests cover every cursor and page width, admission-bound
  retention, exact quantities above uint64, private-field refusal and invalid
  transitions. The initial 87-case current run also passed in 5.5 seconds,
  `/private/tmp/loopex-m7-maintenance-scan-current-v1.log`, SHA-256
  `ba2b41840b75ddf366f65053192d424464b353d9808b15c69d56f16a56fab406`.
  This is focused evidence, not a new full integration or release run.

- Done: the clean pushed event-writer candidate
  `da1ba2b49a510d43c33dfd30047ade17def81d9d` passed its one full current-pair
  `bash scripts/check.sh` integration run. All eleven application suites pass,
  with 3,745 tests passing and 41 lane-selected exclusions. The suite step took
  834 seconds; the runner took 905 seconds. Complete immutable output
  `/private/tmp/loopex-m7-da1ba2b4-fast-check.log`, SHA-256
  `d1c246fb0a79dcbcac5a2c7bb73e36c22095a346c9127e4d131aac0b713f2413`.
  Core passes all 1,254 tests on these exact bytes, including the updated
  overflow terminal inventory. The earlier complete Core failure remains a
  failed run of its prior fixture bytes. No source change or suite rerun is
  made by this evidence-only child. Counts remain original T01–T19
  56 done / 117 todo / 6 retired; added 223 done / 10 todo. Snapshot reduction,
  complete generation-3/4 negotiation and independent live maintenance proof
  remain open, as do cleanup diagnostics and the closure matrix.

- Done: the serial reducer derives `context.maintenance_changed` from the
  authenticated before/after episode allowlist for both actual owners. It emits
  one non-null admission and one null terminal view, preserving retained
  admission bounds while attempts, stages and usage change. Proposal and
  recovery share this derivation; the private journal position fixes event
  identity across uncertainty. A changed view precedes the same private row's
  outcome events. Source/summary text, instruction captures and provider maps
  remain absent. Both transports use the closed codec, and both independent
  connections refuse malformed view events.

  All twelve maintenance/standalone/source/summary files pass: 305 tests on
  each supported pair, with two long-bound exclusions. Current measured time
  14.0 seconds, output `/private/tmp/loopex-m7-maintenance-view-events-current-v8.log`,
  SHA-256 `508a82965bc32b8267187afc26306be990e76d6a349457117e9fe54eb0077a16`;
  floor time 13.0 seconds, output
  `/private/tmp/loopex-m7-maintenance-view-events-floor-v8.log`, SHA-256
  `a8ace83e574bae662d5560d88aceb32cfe336b9f47e9c6e3678c5760cd90b9ad`.
  Existing capture/cancellation tests now prove one admission and terminal view
  across all three Store uncertainty phases and exact owner succession; the
  held terminal transaction includes its null view before linearization.
  Run-owned recovered cutoff cases also retain exactly that two-view sequence.
  Public tampering, missing/duplicate rows and private-canary additions refuse.
  Foreground delivery passes 9 cases in 0.5 seconds on each pair; daemon wire
  records pass 4 cases in 0.02 seconds on each pair. Each projects null, both
  owners and a run allowance above uint64 using the exact literal payload.

  The complete current Core run retained a FAIL, 1,253/1,254 passing with
  eight long-bound exclusions in 215.6 seconds, output
  `/private/tmp/loopex-m7-maintenance-view-core-current-v7.log`, SHA-256
  `e9b6502b59dfec05ab6b8d290701832a4da7b4746eff7ac07dc0668b97a6dcf6`.
  Its sole assertion expected compact completion without the now-required
  terminal view. The final focused run updates that inventory and preserves
  the original hard-overflow refusal proof; it does not relabel the full run.
  That full output also records an OwnerGroup `Supervisor.Default`
  `shutdown_error/noproc` for a coordinator child; cleanup diagnostics remain
  unresolved under the expanded T16 investigation.

  All failing attempts, final pair/transport outputs and final source patch are
  retained in `/private/tmp/loopex-m7-maintenance-view-emitter-proof-inventory.tsv`,
  SHA-256 `69688dada587b61ed80f0cb3716d9b344068df7cc15856dfbea88f922bee905b`. Earlier failures were assertions expecting private-only
  admission or terminal inventories and mistakes in new canary/outbox fixture
  fields. The v4 runs repeated the still-wrong canary body assertion because a
  text replacement failed to match its formatted lines; both remain failed.
  No retry is treated as a pass and no bound or existing refusal is weakened.
  Snapshot reduction, complete generation-3/4 manifests/negotiation, live
  independent maintenance workflows and publication-watermark fault proof
  remain open. This completes one added T05 event-writer subtask only.
  Formatting, warning-free compilation, current-tree status, documentation and
  dependency direction pass; complete metadata output
  `/private/tmp/loopex-m7-maintenance-view-emitter-metadata-v1.log`, SHA-256
  `81f12f05d3898fe8bf133c747bd5cdae38041f80108d6d6a0f681a46dc8e303a`.

- Done: the exact clean `a160e5b073206fa453f208c569012ddf6e4f8402`
  selected Node release lane passed in 342 seconds under Node 22.14.0.
  Fresh-source extraction/build and independent Git-tree/archive checks took
  156 seconds; foreground, protocol, daemon and CLI lanes executed 4, 5, 1
  and 1 tests respectively. The CLI case joins controller loss and takeover.
  Complete output is `/private/tmp/loopex-m7-a160e5b0-node-check.log`, SHA-256
  `5eba6ade0f87802cfbc21f6cc9c7550f1c40f30ef8734dd463e059d84b6fcf8f`.
  All retained lane/build/inventory/source-identity outputs and exact
  NUL-delimited manifest bytes are inventoried in
  `/private/tmp/loopex-m7-a160e5b0-node-proof-inventory.tsv`, SHA-256
  `54c0972f1b73d3af73a0309e652482fc5ff0c8785960e511c5a590a6cac45ea3`. The pre-build source manifest digest is
  `536b868c45d2451282a0648f6bb84c0553344262e9b739ad73ecd3cc861fbc10`.
  This is selection-only evidence for that candidate, not the full closure
  matrix or live maintenance under the pending generation-3/4 negotiation.

- Done: the approved maintenance-view payload has a shared Elixir encoder/decoder,
  an independent Node decoder and 201 literal vectors. Run allowances and
  configuration versions remain unbounded exact positive integers; only
  retained deadlines and standalone bounds use their specified ceilings.
  Null inactive views, both owners, unknown/private fields, malformed decimals,
  canonical identities and complete UTF-8/opaque byte ceilings are proved.
  All 109 protocol tests, including six Node cases, pass on each supported pair
  in 0.3 seconds. Current output
  `/private/tmp/loopex-m7-maintenance-view-protocol-current-v1.log`, SHA-256
  `e05113f00725f77afa2fde5ef8fcab65bd3eb416a61886e8e680745dd89d9637`;
  floor output `/private/tmp/loopex-m7-maintenance-view-protocol-floor-v1.log`,
  SHA-256 `3bc779fa079bb73a1689de5a8439e7c2893d3c6586691969e52f6d287564aeee`.
  The new independent consumer executes all 201 literals plus 15 full-boundary
  and non-plain-object checks. No event writer, snapshot reducer or live
  transport had adopted the new view at this codec-only checkpoint; subsequent
  event-writer work is recorded above. Snapshot/negotiated T05 obligations remain open.
  Formatting, warning-free current compilation, status/documentation and
  dependency direction pass on the staged source. Complete metadata output
  `/private/tmp/loopex-m7-maintenance-view-metadata-v2.log`, SHA-256
  `d5c95ffbd92dd2ce0457bf2ed19540952c4f5af985877d36846e312afbe32948`.
  The first dependency check correctly refused the then-untracked new source;
  its failing diagnostic remains `/private/tmp/loopex-m7-maintenance-view-metadata-v1.log`,
  SHA-256 `d58ef8592279d0425a9ba94c85aff7a3506ef2c48aea97bd3e3d4b944112adca`.
  Staging supplies the ordinary 100644 blob required by that check. No source
  behavior or dependency budget was changed to obtain the passing result.

- Done: the clean committed candidate
  `a160e5b073206fa453f208c569012ddf6e4f8402` passed its one full current-pair
  `bash scripts/check.sh` run. All eleven application suites passed, with
  3,737 tests passing and 40 lane-selected exclusions. The suite step took
  831 seconds; the runner took 903 seconds. Complete immutable output is
  `/private/tmp/loopex-m7-a160e5b0-fast-check.log`, SHA-256
  `a4e4f15e259075eda8261a583adaf1e4b233de749c3b4c83b3f5313b9cc2abaf`.
  This verifies the combined source changes. It does not establish the exact
  untraced schedule of the failed `520ff308` parent, resolve Task.Supervisor
  cleanup diagnostics, or replace the floor/closure release matrix.

- Accepted, implementation open: the maintainer selected the durable
  `context.maintenance_changed` view. ADR 0043 and the
  [decision disposition](../developer/agent-context-map.md#disposition-m7-durable-maintenance-view-2026-10-03)
  retain its exact closed projection and same-cursor snapshot/replay obligations.
  Add no private captures to the public plane. This adds a T05 subtask and
  closes no original item.

- Running: join the accepted durable maintenance view to current
  protocol/snapshot contracts. The combined standalone-capacity and quiesce
  startup-order repair passes the exact-candidate full check below. The full `520ff308` failure remains
  recorded as FAIL; the reproduced private-handshake defect is repaired below. Standalone pre-dispatch capacity completion
  is implemented and passes the focused selection on both supported pairs.
  The separate concurrent owner-stop Task.Supervisor diagnostic remains open.
  The callback/discovery integration is complete at clean pushed
  `6058eb95b7b312905e55c7baa0401e6af18ceba1`. Original T08 production-contract
  and native-fidelity proofs and added T15 callback migration remain complete.
  Current T01–T19 tally is original 56 done / 117 todo / 6 retired; added
  223 done / 10 todo. The goal remains active. The maintainer requested the
  three decisions one at a time and selected explicit checkpoint ownership
  and the narrow reply-reserve preparation refusal, then approved the captured
  1,000-ms stalled-stderr startup cutoff with exact writer joins. All three
  decisions are resolved. The reply-reserve implementation and focused proof
  are complete. Combined integration also passes at its named revision. The
  approved standalone checkpoint owner and successful completion are now
  implemented with focused proof below. Full protocol/snapshot integration
  remains open. The cleanup repair is committed
  and pushed at `052e0e01`.

- Done: a quiesce cancellation confirmed by Control now closes a fence whose
  startup notice has not arrived. Previously the phase owner waited for its own
  DOWN even though it had no PID or monitor. Control's acknowledgement already
  proves its worker DOWN or absence. Announced workers still require the phase
  owner's independent exact monitor join. Deadlines, Store ownership, authority,
  existing population tests and production bounds are unchanged.

  The failing-before transport-delay witness uses actual Control, the original
  runtime child inventory, real session termination and a real fence worker.
  It delays only the private startup notice and forwards Control's actual
  cleanup disposition. Both an expired worker and one suspended until cancellation
  reproduced `runtime_unavailable`; all 28 existing active cases passed. Complete
  failing output `/private/tmp/loopex-m7-quiesce-late-fence-start-before-v2.log`,
  SHA-256 `1ed2221c998d6a43f5594f418d9bf53295de565ebb5cfa19e12a099d9284c213`.
  The first post-fix current/floor outputs remain FAIL because the new fixture
  compared Store state before the legitimate durable idle-abort admission.
  The final fixture captures unchanged facts at the exact fence-start gate,
  preserving all outcome, elapsed-cutoff and worker/relay/root join assertions.

  Final complete-file current proof: 30 pass, four long-bound exclusions in
  7.2 seconds, `/private/tmp/loopex-m7-quiesce-late-fence-start-current-v2.log`,
  SHA-256 `23bdc93f6e4cd03b51fed0d5a29dec104b90d12aace1ce6e2ed29f2d7d4eea77`.
  Floor proof: 30 pass, four exclusions in 6.9 seconds,
  `/private/tmp/loopex-m7-quiesce-late-fence-start-floor-v2.log`, SHA-256
  `5ea1f7ea81789a98356b90d79c221734ecf3cb7e59248be4001910b89b2afa71`.
  The unchanged production-cutoff case separately passes on both pairs: 63 actual
  blocked Store readers are reaped and the sibling completes within the original
  elapsed/cutoff bounds. Current in 126.1 seconds,
  `/private/tmp/loopex-m7-quiesce-production-fence-current-v1.log`, SHA-256
  `dcd94e64f15124f1d0a4005a0b44b4ca34576a4fcc485bfc82124a253b5e6c63`;
  floor in 126.0 seconds,
  `/private/tmp/loopex-m7-quiesce-production-fence-floor-v1.log`, SHA-256
  `d7c0001ea5f7f005442f6e1638a8067b6a703ab20cba67776a6d1ace20a7beb5`.
  These focused long-bound cases do not replace the complete release lane.

  Final binding review also reproduced an acknowledgement sent to a foreign
  phase owner while the operation was still registered. Control now acknowledges
  an absent operation only from its nil lookup; a live mismatched binding is
  refused without acknowledgement or worker termination. The legitimate owner's
  cancellation still joins the exact killed worker and empties the inventory.
  Failing complete-file proof: 30 of 31 pass,
  `/private/tmp/loopex-m7-quiesce-foreign-cancellation-before-v1.log`, SHA-256
  `175a23d7398b0d4ae97b736f074d23009bbd3a1023dee33bcee171ef407dbe98`.
  The final combined complete-file selection passes 31 active cases, four
  long-bound exclusions, in 7.2 seconds on each pair. Current output:
  `/private/tmp/loopex-m7-quiesce-ordering-current-v3.log`, SHA-256
  `937c721cfafa2570cbe45434486d8654c5fded032b73263ae71bc2ea8dbe4574`;
  floor output `/private/tmp/loopex-m7-quiesce-ordering-floor-v3.log`, SHA-256
  `d33e337b1373b4346a2319c1b61ff5f049acbc70fbc519b6ff8342f9a3936295`.
  The production-cutoff results above cover the preceding startup-order fix;
  the later binding guard leaves that legitimate cancellation branch unchanged.
  Full release/closure proof of the final candidate remains required.
  Final warning-free compilation, formatting, status, compiled documentation
  and dependency checks pass. Complete immutable output:
  `/private/tmp/loopex-m7-quiesce-ordering-metadata-v2.log`, SHA-256
  `c1df0005869b25ebe9304e954313fda5684d798417995a0365551c5e601f6026`.

  Prior diagnostic passes did not resolve the integration failure. Runtime
  tracing's first broad selection hit its existing rate ceiling. The two attempts
  using twelve ExUnit cases/modules ran the inspected fence phases serially;
  their names do not prove concurrent load. The task-owned twelve-runtime probe
  used concurrent tasks and passed, but its diagnostic sink belonged to the parent
  and its per-task retained trace files are empty. None proves the original
  full-run failure's precise schedule. The controlled startup-order witness
  establishes a reachable defect producing the same symptom, not a trace of
  that historical failure. The next combined full integration run remains required.
  All failed/passing diagnostic source, observations, redacted traces, final
  proof and exact source patch are retained in
  `/private/tmp/loopex-m7-quiesce-ordering-proof-inventory-v3.tsv`, SHA-256
  `347e6e8af95751e52d43108977b1a7ebe44f746ed2a02ce6a223b817898b7db6`.

- Done: standalone pre-dispatch capacity endings derive the captured attempt
  and token allowances without waiting for the command deadline. A useful partial
  checkpoint and actual usage survive exhaustion; a fitted checkpoint still
  completes at its last attempt or with fewer than 1,024 tokens remaining.
  Initial budgets 1 and 1,023 refuse before dispatch with zero actual charge.
  Further-prefix reserve boundaries 1 and 1,023, actual exhaustion and overshoot,
  forged observations and all six initial/partial completion uncertainty phases
  preserve the existing standalone bound schema. The new preparation reserve
  cause remains run-only. No public contract or timeout changes.

  The final four-file Core selection passes 186 cases on each supported pair:
  current in 10.3 seconds, floor in 10.0 seconds. Complete immutable outputs:
  `/private/tmp/loopex-m7-standalone-capacity-bounds-current-v4.log`, SHA-256
  `8b68646cf9b44007e64c0336798c62977aad899489c030598f9b1668e110bb01`, and
  `/private/tmp/loopex-m7-standalone-capacity-bounds-floor-v4.log`, SHA-256
  `61865b8aebf36dbbf19f8e6469de149f17dce72222d2dacff8c4c3f66bbb94ae`.
  The integrated four files match the verified isolated worktree byte for byte.
  External failing-before probe on `520ff308` reported deadline exhaustion where
  the actual attempt allowance was already spent; retained source and complete
  failure are listed in the immutable inventory below. Capacity v2 and v3 on both
  pairs remain FAIL, 185 of 186 passing, because a rejection assertion expected
  a different internal error. The v3 retry tested unchanged failing bytes after
  an edit assertion failed; it supplies no new proof. The corrected v4 assertion
  requires exact rejection of the run-only cause, and every case passes.
  Intermediate passing outputs, failed outputs, probe source and integrated patch
  are retained in `/private/tmp/loopex-m7-standalone-capacity-proof-inventory.tsv`,
  SHA-256 `3e7256d941309159971a3eba3b8b63efad91d47e46d0f151fcbb770dcc459b3b`.
  Warning-free compilation, formatting, status, compiled documentation and
  dependency checks pass. Complete immutable output:
  `/private/tmp/loopex-m7-standalone-capacity-metadata-v1.log`, SHA-256
  `d5c3455b52517e1dd085737b8e436dbff9de5f8f28c246f1772836b369662501`.
  No full integration pass of this later capacity fix is claimed.

- Open integration defect: the clean pushed checkpoint-owner candidate
  `520ff308328f9bf033abf87fce57f8b1e6dec254` ran the full current-pair fast check
  once. All eleven application suites completed: 3,718 passed, one failed,
  40 excluded. The failure is RuntimeQuiesceTest's sixty-three blocked fences
  sharing one cutoff while a sibling completes; `Quiesce.run/3` returned
  `{:error, :runtime_unavailable}`. Its exact failed schedule was not traced;
  the reachable startup-order defect and repair are recorded above. Additional
  focused current/floor VMs ran during part of this integration run; that fact
  does not establish resource contention as the cause. This candidate remains
  FAIL and must not be rerun or relabeled as passing. Complete immutable output:
  `/private/tmp/loopex-m7-520ff308-fast-check.log`, SHA-256
  `85eead6f40d2d9d2da4a5c5d534a07fd2df1078e11c7b8793600ad30576b1382`.
  T16 tracks the investigation separately from the Task.Supervisor diagnostic.

- Done: approved standalone checkpoint ownership and live completion use the
  actual command ID, distinct private checkpoint kind and shared public owner
  codec. Original conversation, run identities, run charges and deadlines are
  unchanged. Three-prefix hard-limit repair retains contiguous original coverage
  and cumulative usage. All three Store uncertainty phases at checkpoint and
  terminal/completion boundaries recover exactly once without another summary.
  Duplicate completion and owner restart retain the checkpoint/result. Abort and
  expiry retain actual usage; the useful-settlement expiry fixture now pauses
  the exact Store settlement across its existing 1,000-ms command cutoff rather
  than depending on the former missing checkpoint phase. Provider callback and
  worker joins preserve existing fixture and product bounds. No new timeout or
  compatibility reader is introduced.

  The final four-file core selection passes 171 cases on each supported pair;
  it includes rejection of forged checkpoint owners in private rows and public
  events and complete private-reader pagination without acquiring an owner.
  The approved public payload passes four protocol cases on each pair, including
  the independent Node consumer of 36 literal vectors and four identity/shape
  boundary checks. Foreground delivery passes eight cases and daemon records
  three on each pair. Both transport projections encode the owner's original
  opaque bytes; both Node connections validate checkpoint owners and reject the
  old owning `run_id` alias. Complete retained outputs are immutable:

  | Selection | Output under `/private/tmp/` | SHA-256 |
  | --- | --- | --- |
  | Core current, 171 pass, 9.7 s | `loopex-m7-standalone-checkpoint-owner-core-current-v9.log` | `bc5d6e6e414da2cdcea8a2897e672b5249675c210d94e035ad0250fd8d2d6157` |
  | Core floor, 171 pass, 9.4 s | `loopex-m7-standalone-checkpoint-owner-core-floor-v3.log` | `fcf06a7444dc0215e74c5ba1acceea4423aa25d46338995932ee7a3759730005` |
  | Protocol current, Node included | `loopex-m7-checkpoint-owner-protocol-current-v1.log` | `c8fc33a4356b33633f71f29b15fb0703b8d9903833aa4ac2ab68929841d551bb` |
  | Protocol floor, Node included | `loopex-m7-checkpoint-owner-protocol-floor-v1.log` | `1bcf4c13d51dd2f9c16975bd04645ae052db37d5a1fbfb43848e9e6e3f8f057d` |
  | Foreground current | `loopex-m7-checkpoint-owner-foreground-current-v1.log` | `5b15fdc44a0b8927d376cb7768cdaabee50f663f535c01dbe27b72e7936e53d1` |
  | Foreground floor | `loopex-m7-checkpoint-owner-foreground-floor-v1.log` | `eb9efebe3db93e21de41c00656fc429841ce1f43beff9cf88828668b0ddd70a2` |
  | Daemon current | `loopex-m7-checkpoint-owner-daemon-current-v1.log` | `f05fedf1673b04a9a562e1cab611556bd100044bc6c318cb6e37c50e4b078289` |
  | Daemon floor | `loopex-m7-checkpoint-owner-daemon-floor-v1.log` | `22e2c87285273ea8e481acda1d53ac19de7fd26e103c455ccde5001c102b8d72` |

  Development failures remain failures of their tested bytes. Core current v1
  passed 138/139 and exposed the old implicit expiry stall;
  `loopex-m7-standalone-checkpoint-owner-core-current-v1.log`, SHA-256
  `9cafae062759f24cece7ab094f3905255b57e54f7e1873b7486632f20ab51879`.
  v2 could not acquire Mix's sandboxed TCP lock and provides unavailable evidence;
  digest `e10cbee50e01b07ab2cf163c0fede103c5bb7cfbb8a51f2ee434856106979efb`.
  v5 passed 145/147: the fault-injection Store lacks the optional provenance read
  callback, so pagination moved to the existing query-capable Store fixture;
  digest `32d990f6621583548ee4e0d539fafe0a0f7d8ab151bef52ed3dc30d464cfd1bb`.
  v6 passed 169/170 and found the private reader still refusing checkpointed
  completion; the current validator now admits positive-attempt checkpointed
  results and retains malformed/zero-attempt rejection;
  digest `df9eca10d175983912d2910335d84d27b57e7e049aba4a6d844b2e324b0ae88b`.
  Each version uses the same `loopex-m7-standalone-checkpoint-owner-core-current-vN.log`
  path pattern. Earlier successful intermediate selections remain retained but
  do not replace the final selections above. No full fast/release check of the
  new source, generation-3/4 snapshot integration or milestone closure is claimed.
  Compilation, formatting, bootstrap/status and documentation gates pass in
  `loopex-m7-checkpoint-owner-gates-v1.log`, SHA-256
  `a5aba128de75c20487fb4bb378521beb46e00d04effc73a788d30e4fd396cf77`.
  That aggregate run ends FAIL at the dependency gate because its new source
  file was not yet staged as a tracked ordinary blob. Staging the six new
  source/fixture files satisfies that prerequisite; the dependency-only rerun
  passes at `loopex-m7-checkpoint-owner-deps-gate-v2.log`, SHA-256
  `afd19a5ac98446e7ac7567baf3c06d8e74e030617bf1e577d421806d438a6d55`.
  Both outputs are retained under `/private/tmp/`; the first remains FAIL.
  Final warning-free compilation, formatting, status and documentation checks
  pass in 11.2 measured seconds; complete output
  `/private/tmp/loopex-m7-checkpoint-owner-final-metadata-v1.log`, SHA-256
  `a5907b2b56caf81d301873ed69f15edda922c2dd32565334cb7ecf0beded112a`.

- Done: combined integration at clean pushed
  `b4bee93bfd05f120c5c8cf87ec93e0469fc25a97` passes all eleven applications,
  3,703 cases with 39 expected exclusions, in 925 measured runner/check seconds.
  This is the only full fast check of that candidate. Complete immutable output
  `/private/tmp/loopex-m7-b4bee93b-fast-check.log`, SHA-256
  `493710000d90ff1a98cefe30656e91c5118c9abf46faee4b35ad5667ee2d71b5`.
  Execution handle `72770` is terminal and collected; do not poll or repeat it.
  The selected Node release workflow of that same clean candidate passes all
  four consumer lanes after a fresh source build: app-server 4, protocol 4,
  daemon 1 and CLI 1 executed cases. It reports 372 check seconds and measures
  373 runner seconds. Complete output
  `/private/tmp/loopex-m7-b4bee93b-node-release-v2.log`, SHA-256
  `c8f640534b6d4a82ed09a0b52b78036eb028b967107755d78395803dfb2f6560`.
  Handle `75782` is terminal and collected. The initial selected attempt refused
  before extraction because its external retained-output directory did not
  exist; creating that directory changed only the prerequisite. That refusal
  remains unavailable evidence at `/private/tmp/loopex-m7-b4bee93b-node-release.log`,
  SHA-256 `9fee65dc363edc0f0d1230b9e408ac3408917fa8da1af8ba72837528e2c3ae52`.
  Neither run is the floor/provider/attended/long-bound/full closure matrix.
  The separate concurrent owner-stop Task.Supervisor diagnostic remains open.
  The documentation-only integration record check passes in 17 seconds, retained
  at `/private/tmp/loopex-m7-b4bee93b-integration-record-docs-v1.log`, SHA-256
  `10e2b243c911e79eec3940eb170e3ac6722e1ba90d13e69cc4c46135913be60d`.

  The fresh-source lane verifies 1,137 pre-build archive records against the
  exact candidate. Its complete retained producer bytes and other outputs are
  under `/private/tmp/loopex-m7-b4bee93b-node-release-retained/`:

  | Retained file | SHA-256 |
  | --- | --- |
  | `source-archive-manifest` | `d95b581e2de208bf2f4591c0aebf76cd97ebb7f8ca987e7818df9cb1891011a0` |
  | `source-archive-manifest.after` | `ad53e9ba8fab3dd84c58283f595eea552eddd445e244892a1be95368eb6faf2b` |
  | `source-archive-manifest.source-identity` | `90dd1779f9732d36fc6cb594dbd8caa7ebb0a8e270386439e6d0f4ba58366f98` |
  | `source-inventory` | `02b2b994951c0201e1d05cfa0283d02557158a1c1e586b5c3cc49e8bd3db2fca` |
  | `fresh-source-build.log` | `15543c5c60a7b59c642b1c8cd68f1bccf0c13383ef47e51b3c53df85b34b0834` |
  | `escript-inventory.log` | `58719360a2dd2a350eb49a2df2a9891a222b47767ec018dbe83dcfb9403f4a3b` |
  | `node-client-loopex_app_server.log` | `020005740a436b857c6cf89d3372b50438e02bfe057287f16303516ecc560724` |
  | `node-client-loopex_protocol.log` | `234ff5b29bebcb1e602f00f905b3a97f59aa930d58c020dacae8fd78725c28fd` |
  | `node-client-loopex_daemon.log` | `bc5645f3e463385dfa25f2fe1aee3929f4556b1da33380d7c8fa299bd47d61cd` |
  | `node-client-loopex_cli.log` | `2e307f5cdd22a45149cc7f03401f3c8aebe6ece88f6dd34ca107e6a6033c1619` |

  Resume standalone work at `SessionState.maintenance_checkpoint_record/3`,
  its replay branch, `EffectIntents`' closed checkpoint schema/neutral reader,
  and `SessionCoordinator.advance_compact_episode/3`. The current successful
  compact branch intentionally emits nothing pending ownership implementation.
  Add the already-approved distinct command-owned private variant and shared
  public owner object; derive lineage from the last actual original run. The
  whole-session range may have null `first_kept`, unlike the current run-owned
  reader. A successful compact must use its existing command cutoff and episode
  usage, retain a verified checkpoint and complete through the existing leading
  episode/completion transaction. No synthetic run is permitted. Current public
  checkpoint schemas/vectors and snapshot/protocol integration remain required.
  Read-only exploration introduces no further decision. All three sequential
  questions are resolved; no maintainer answer, agent or check is pending.

- Approved: the captured 1,000-ms stalled-stderr writer-start cutoff and exact
  writer exit/join under the
  [maintainer disposition](../developer/agent-context-map.md#disposition-m7-stalled-stderr-startup-2026-10-03).
  The CLI fixture captures one cutoff before diagnostic dispatch, monitors the
  live IO writer before command cleanup, requires its exact shutdown DOWN and
  unchanged JSON output separation, then joins its fixture device normally.
  Production limits are unchanged. The first focused run fails the new exact
  writer DOWN assertion on both pairs, 32/33 cases pass in 6.5 seconds: the
  production DiagnosticLifetime join matches a PID then consumes the message
  even when its monitor reference belongs to the caller. The repair moves both
  PID and reference matching into the receive guard, retaining the foreign
  message and every captured cleanup bound. The exact writer-monitor regression
  stays intact. The second run preserves the exact foreign DOWN but fails the
  test's mistaken expected `:killed` reason on both pairs, 40/41 cases pass. The
  consumer stops its private supervisor first, so the writer exits with
  `:shutdown`. Correcting that expectation preserves the exact PID/reference
  and join. Both complete ask/chat files now pass 41 cases on each pair, in
  11.1 current and 10.9 floor seconds. Historical failed runs remain failed.
  Static formatting, warning-free compilation, repository/status and
  documentation gates passed. Complete output is retained at
  `/private/tmp/loopex-m7-stalled-stderr-metadata-v1.log`, SHA-256
  `c8ce67f3164e77b872ed513663fc891d12bc6bc2195746ffcc593014553f107a`.
  This closes the added fixture/monitor-message subtask. The separate concurrent
  owner-stop Task.Supervisor diagnostic remains open.

  | Retained complete failed output | SHA-256 |
  | --- | --- |
  | `/private/tmp/loopex-m7-stalled-stderr-startup-current-v1.log` | `98ce9629de66353fef50a1dad8e0c9141aa892aef29f95fcf049b8b076fd878c` |
  | `/private/tmp/loopex-m7-stalled-stderr-startup-floor-v1.log` | `f9e4f17a25c2915568c21be9c4456ffe3aa17d9d1a9e1fb0961be493cba9e7ea` |
  | `/private/tmp/loopex-m7-stalled-stderr-startup-current-v2.log` | `6fb24f4d7811738e6d2a4a32a737f7218b490a5be64b5071e637f33f61b4e118` |
  | `/private/tmp/loopex-m7-stalled-stderr-startup-floor-v2.log` | `a76e38e1eea0f7166110c99086f26f69b0218c81bdc6111024fe02dbd09795a8` |

  | Retained complete passing output | SHA-256 |
  | --- | --- |
  | `/private/tmp/loopex-m7-stalled-stderr-startup-current-v3.log` | `a3c4577cfb48d04507486206c2a05fef8b8f2914432297e127e7cc2de9d39469` |
  | `/private/tmp/loopex-m7-stalled-stderr-startup-floor-v3.log` | `d8119fb6b422db01c4cfd76559e5ede8058c2efead17c4b07729d601e7fde592` |

- Approved: explicit standalone checkpoint ownership. The maintainer selected
  distinct private run/compact kinds and actual owner IDs, plus the closed
  public `{owner: {kind, id}}` object. The
  [disposition](../developer/agent-context-map.md#disposition-m7-standalone-checkpoint-owner-2026-10-03)
  binds the retained proposal and preserves actual lineage boundaries, current
  restart/replay and uncertain-commit proof. Implementing the selected private
  kind, public projections, current schemas and independent vectors remains
  under T07/T05; this approval closes no implementation checkbox. The other
  two decisions were pending at this checkpoint; the reply-reserve choice is
  now recorded below, as is the subsequently approved stalled-stderr cutoff.
  The documentation-only check passes in 18 reported seconds. Complete output:
  `/private/tmp/loopex-m7-checkpoint-owner-decision-docs-v1.log`, SHA-256
  `8e6f27409661195b4c4a227a1ff7ebf8dfd006fed2cb809e31cc82d815c8c73f`.

- Done: the approved reply-reserve refusal now derives eligible phase,
  remaining turns and the exact positive 1–1,023-token interval from committed
  accounting. Actual bound exhaustion keeps its prior outcome; a fitted
  checkpoint cannot claim an unnecessary reservation failure. The existing
  episode/refusal/run-terminal transaction retains honest usage and its useful
  checkpoint. Live resumed owners prove zero new summary/ordinary dispatch,
  exact replay and all three ending Store-uncertainty phases. Current and floor
  selections pass 114 cases with two unchanged long-bound exclusions in 8.1 and
  7.3 seconds. The shared Elixir/Node codecs, closed schemas and literal vectors
  carry the approved cause. Both-pair protocol checks pass 19 cases, including
  actual pinned Node execution of 158 terminal and 120 compact vectors, in 0.3
  and 0.1 seconds. The standalone owner implementation and combined integration
  remain open.

  Development failures remain failed: the first reducer run passes 44/46 cases
  because new tests incorrectly expected pending-checkpoint capacity to require
  another reservation and treated the initial cancellation check as traversal.
  The corrected test commits useful progress before requiring another summary.
  The first protocol run passes 13/17 cases with two excluded because literal
  counts and exact-byte identities still named the superseded union. Their
  current identities now include the added case; every prior vector remains.
  No production bound, timeout, assertion or cleanup proof is weakened.
  The first two static runs refuse an extra governance row because ADR records
  require exactly their original Acceptance row. The amendment now retains
  maintainer authority and the approved packet identity in existing metadata,
  preserving that immutable Acceptance row. The corrected static gates pass.

  | Retained static output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-maintenance-reserve-static-current-v1.log` | FAIL, misplaced additional governance row | `54fb84ed644ec2d72cd29d314799b29228dea8eb2586fa3641fe33e5ccd364fc` |
  | `/private/tmp/loopex-m7-maintenance-reserve-static-current-v2.log` | FAIL, additional governance row still violates exact table | `32522589437f6a876e166f3551a911672a746ce9e9f0d917f676b1a1379c275b` |
  | `/private/tmp/loopex-m7-maintenance-reserve-static-current-v3.log` | PASS, compile/format/bootstrap/docs/dependencies/version/reporter | `8f7d22b4e270873944d229d3aaa165ecd2079173e28ef005fb4050abc62576d1` |

  | Complete retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-maintenance-reserve-reducer-current-v1.log` | FAIL, 44/46 | `aad4b315c55b1c1b8321397205cfaff55891738c7def6db1eace28a1bca1a700` |
  | `/private/tmp/loopex-m7-maintenance-reserve-reducer-current-v2.log` | PASS, 46 | `8cadc8b1d094cd7b661d61bc1445cbd433c8e49e9c955a5134a05e7188539d49` |
  | `/private/tmp/loopex-m7-maintenance-reserve-core-current-v1.log` | PASS, 113, two excluded; before fitted-checkpoint guard | `d877c11ac4d0eeb8a1dfdb8df1218ac5297148a4e2b3481dbdeafd415c8721bb` |
  | `/private/tmp/loopex-m7-maintenance-reserve-core-current-v2.log` | PASS, 114, two excluded | `fee31cf9df08ba1cc7204bfd637b2ded402b5d08605e23aad5af60491b4a36f4` |
  | `/private/tmp/loopex-m7-maintenance-reserve-core-floor-v1.log` | PASS, 114, two excluded | `d8f96113d1b67d9417d935ce3ca4b62b8d3112cf98ba414d8abe362d97e00633` |
  | `/private/tmp/loopex-m7-maintenance-reserve-protocol-current-v1.log` | FAIL, 13/17, two excluded | `25d66efe18152abdc43686b26c68981141298ed1dfe4ed8e2abe2f10e5bed9d6` |
  | `/private/tmp/loopex-m7-maintenance-reserve-protocol-current-v2.log` | PASS, 19 including Node | `2ca172d00fe5236398c0c525fa3f518ba73c68e5f530845fa5b86108ffbebdf8` |
  | `/private/tmp/loopex-m7-maintenance-reserve-protocol-floor-v1.log` | PASS, 19 including Node | `a9d4f7a3f1ce6c4774ceb072cc8a45cebfd8fbb0ce7b563bbc2f91524786b311` |
  | `/private/tmp/loopex-m7-maintenance-reserve-node-v1.log` | PASS, 94 context-terminal and 120 compact vectors plus boundaries | `e01a7d17fcd4725c0b08a6439628632fa92d3baf0828cb2a3790f91be210629e` |

- Approved: `maintenance_reply_reserve_unavailable` in the existing v2
  preparation-failure cause union. The
  [disposition](../developer/agent-context-map.md#disposition-m7-maintenance-reply-reserve-2026-10-03)
  binds the exact retained proposal. It preserves actual usage and zero summary
  dispatch when positive remaining tokens cannot fit the fixed 1,024-token
  reserve; actual budget/turn exhaustion keeps its existing bound outcome.
  The added T07 implementation/proof subtask is open. No contract implementation
  or checkbox is completed by the approval. The stalled-stderr startup cutoff
  was pending at this checkpoint and is now approved above.
  The documentation-only check and reporter pass, 18 reported check seconds.
  Complete output: `/private/tmp/loopex-m7-maintenance-reserve-decision-docs-v1.log`,
  SHA-256 `81ed6e34bcdbd03aafca3603cddcf56dd65696bf3cd91d92df78557fa81d6403`.

- Done: the single full current-pair fast check of clean pushed
  `6058eb95b7b312905e55c7baa0401e6af18ceba1` passes all eleven application
  suites: 3,696 cases pass, 39 expected exclusions. The wrapper measures
  916 seconds; the check's rounded step clock reports 917 seconds. Complete
  immutable output: `/private/tmp/loopex-m7-6058eb95-fast-check.log`, SHA-256
  `c93a4ad28b8e7d3a93e9b9929ec682059dbe424c2f9893be0e7cc5b5f756d532`.
  Handle `97582` is terminal and collected. This resolves the added T16
  callback/discovery integration obligation, including Core's formerly obsolete
  summary control. Both failed parents below remain failed. This current-pair
  integration is not the floor/provider/fresh-source closure matrix.

- Investigating: an external actual-runtime shutdown probe narrows the open
  T16 cleanup diagnostic. It monitors each held provider callback, private task
  children, worker supervisor, owner group and runtime root. The serial matrix
  joins all observed processes for 32 explicit stops and 32 normal parent exits
  without shutdown reports. A concurrent batch of 32 normal parent exits also
  joins every captured process within one 1,000-ms cutoff, but reports three
  Task.Supervisor shutdown_error/noproc entries for Task.Supervised children.
  The complete v2 probe therefore fails its diagnostic assertion, 1/2 cases
  pass in 0.7 seconds. No cleanup limit or logger error filter was changed.
  The installed Elixir 1.20.3 shutdown code uses a new monitor, unlinks a child,
  then reads an immediately available linked EXIT before dispatching shutdown;
  a late-exit race remains a hypothesis until a fix proves the actual trigger.
  Do not close T16's investigation from successful process joins alone.
  The same retained v2 probe passes both cases on Elixir 1.18.5/OTP 27.3.4
  in 0.7 seconds without reproducing a diagnostic. That floor observation
  does not erase the current-pair failure or establish a production repair.

  The initial probe's 64 serial joins pass, but its non-test filename triggers
  a discovery warning and exit 1 under warnings-as-errors. It is retained as
  failed evidence; v2 corrects that filename and adds the concurrent batch.
  Source and complete output identities are retained below. These temporary
  probes add no shipped test, production code or required-check substitution.

  | Retained source/output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-held-provider-shutdown-probe.exs` | Initial serial probe source | `1aad2cd049fc93f336cc971525308e86c46b781e300f3e2c0d5d8a11d5282d54` |
  | `/private/tmp/loopex-m7-held-provider-shutdown-probe-current-v1.log` | FAIL, discovery warning despite one assertion case passing | `b1088b39dd3180d67cee8b9a51ed17e323760df8076e2885fe52213c0666f280` |
  | `/private/tmp/loopex-m7-held-provider-shutdown-probe-v2_test.exs` | Corrected serial/concurrent probe source | `7f8df08c4b4c02c3fd1a26387d22b9c090f95c9f549770dadce5be3e09f9c044` |
  | `/private/tmp/loopex-m7-held-provider-shutdown-probe-current-v2.log` | FAIL, concurrent shutdown diagnostics, serial case passes | `627f5941f15abb4323567ce2d0f4d8e97c23118f0e30c02b3f735185733c235f` |
  | `/private/tmp/loopex-m7-held-provider-shutdown-probe-floor-v1.log` | PASS, two cases; no diagnostic observed on the floor | `47eed383d00f7c9fb91a56bb1d4074ef38224fa792928e557503ec1d12b28392` |
  | `/private/tmp/loopex-m7-6058eb95-integration-record-docs-v1.log` | PASS, documentation-only checkpoint and tally | `8153ccbb5fc1f48c379984de2392976c83178b2732b6a1e1ae940bf1e31b3c23` |
  | `/private/tmp/loopex-m7-6058eb95-integration-record-final-metadata-v1.log` | PASS, final bootstrap/status/docs/whitespace after floor observation | `1104c7dccbcf5f3261657a4817a893f2e9dca9db84d84967977b5fde5d589873` |

- Failed: the single full current-pair fast check of clean pushed
  `bad9f2203e8e346d25309e95d6e94a773741a9bb` ended exit 1 after 924 measured
  shell seconds. All ten other suites pass, including composition's complete
  489-case automatic discovery with one expected exclusion. Core passes
  1,216 of 1,217 cases with eight exclusions; the maintenance summary test at
  `maintenance_request_staging_test.exs:1895` still expected a dropped-nine-field
  callback to retain reported usage and become an incomplete summary. The current
  decoder correctly rejects it before accounting, producing the episode terminal,
  estimated remaining-allowance settlement and run terminal together. No production
  contract is changed to accept the retired shape. Aggregate is 3,695 passed /
  one failed / 39 excluded. Complete immutable output is
  `/private/tmp/loopex-m7-bad9f220-fast-check.log`, SHA-256
  `06f8022ccefcb5e145289602c69f96da7a320277bf6ce68e768461c941be5154`.
  Handle `29111` is terminal and collected. Do not poll it or rerun these failed
  bytes into green. The next exact candidate includes the current fixture repair.

  The positive summary matrix now uses a current eleven-field callback with
  unknown completion and invalid JSON, preserving all seven positive controls,
  exact reported 37/19 usage, single 56-token charge, atomic parent ending and
  replay/mutation checks. The retired nine-field callback moves to the malformed
  reply matrix with extra/missing response/completion/continuation fields.
  Those cases prove zero reported usage, the exact 10,000-token remaining charge,
  unchanged conversation, no checkpoint, one attempt, closed run/episode,
  exact unreadable result/terminal reason and no retry. The complete maintenance
  staging, summary, current provider reply and accounting provenance files pass
  all 72 cases on each supported pair with warnings-as-errors: current 2.1 seconds,
  floor 2.0 seconds. Known Task.Supervisor shutdown_error/noproc diagnostics
  remain under the separate open T16 investigation; these passes do not resolve
  it. Static compilation, formatting, bootstrap/status, documentation, dependency
  and version gates pass. No assertion, timeout or required check was weakened.

  | Retained complete output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-maintenance-current-callback-current-v1.log` | PASS, 72 cases, current pair | `3a243ef5f5959d1ceda7968af83f736a7ee0c1f328f766578e7653eff6fa9c09` |
  | `/private/tmp/loopex-m7-maintenance-current-callback-floor-v1.log` | PASS, 72 cases, floor pair | `655d743db7df687e58da22d57ac5c71698618b4c2d50b5b1627751ff3a5a1032` |
  | `/private/tmp/loopex-m7-maintenance-current-callback-static-current-v1.log` | PASS, complete collected static-check output | `ee072b28724e538287f9d157ae16e9e689f9a3cc61c805c18041bdf07360fed6` |
  | `/private/tmp/loopex-m7-maintenance-current-callback-final-metadata-v1.log` | PASS, final formatting/bootstrap/status/docs/tally/whitespace | `cfdd5db0125ed44cc1c54cc88c93aca4361ba7da196af81d88a41120c147a52c` |

- Prior checkpoint: migrate the model boundary to exact eleven-field current v3 callbacks
  and ten-field canonical replies, under the pre-1.0 current-contract decision.
  Remove public `ProviderAttempt.canonical_reply/2`, its eight-field projection
  and the nine-field fallback in `/3`. Current adapters, fixtures, types and
  conformance callers now emit/require all eleven members, including nil response
  identity and continuation. Generic mapping retains its previously normalized
  unknown/nil outcome; native capture supplies its validated completion/capsule.
  Store raw byte/depth/cardinality/plain-data admission still precedes content
  traversal, normalization and accounting, excluding only exactly echoed request
  bytes from measurement. Captured continuation requirements, exact digest/echo,
  collision refusal and once-only accounting remain. No wire generation,
  persistence kind, stop classification, deadline or compatibility shim changes.

  The summary validator now refuses superseded nine/eight-field callbacks rather
  than converting plausible usage into readable incomplete evidence. The current
  v3 settlement writer/replay proofs refuse retired generations at every retry
  and terminal position, malformed whole records and changed source/capsule data;
  live current restart, cancellation, permit/reconciliation and exact Store
  admission ceilings remain proved. The original monotonic-generation obligation
  is satisfied by the only admitted current generation, with cross-generation
  acceptance superseded by the maintainer override.

  Original T08 native fidelity maps to `native_content_test.exs`'s exact complete
  array reconstruction, `native_stream_test.exs`'s ordered assembly/signatures
  and every parser byte boundary, `native_request_test.exs`'s exact native arrays
  and original result IDs in both render modes, `native_transport_test.exs`'s
  actual streaming local HTTP for all nine cells, and
  `in_process_caller_wire_test.exs`'s actual buffered local TLS for all nine cells.
  These compare Unicode/empty text blocks, native field sets/order, thinking
  signatures, redacted blocks, IDs and parsed object arguments exactly, including
  literal data resembling references; unknown fields and malformed arguments
  refuse without repair. Core `model_continuation_test.exs` validates bounded
  reference consumption and source bindings. The counted provider thinking
  demonstrations and remaining broader T08 outcomes stay open.

  The first additional buffered proof failed because the fixture selected the
  one-byte credential `k`, which occurs in the now-required completion `unknown`.
  The existing exact-selected-value screen correctly refuses that mapped reply.
  Retain this failure. The fixture now explicitly proves its post-dispatch
  rejection/one write and uses noncolliding `z` for the one-byte success control;
  missing/empty/65,537-byte rejection and 65,536-byte success remain unchanged.
  Recursive key/value echoes, native-private echoes, host-request exceptions,
  actual TLS and exact cleanup all remain tested. No production screening or
  credential bound changes. Current v2 buffered output was invoked from the
  umbrella, which found the selected file only in ReqLLM and ran its five cases;
  all other applications reported unmatched paths and ran no cases.

  Each supported pair passes 416 selected cases with two expected real-provider
  exclusions; no external provider call, floor full check, release matrix or
  milestone closure is claimed. The final read-only AST audit finds zero complete
  retired callback literals or old projection calls/captures in 642 files. Its
  retained source is `/private/tmp/loopex-m7-current-callback-audit.exs`, SHA-256
  `79b70554daaba7cc216129ed4ee09d2bb8713eeea40894e532cc6e1ba4e06ee6`.
  The first audit result remains valid for the pre-fixture-repair source; the
  v2 result below covers final fixture edits. Initial formatting found a comma
  inserted at a multiline call boundary; correction preceded all test runs.

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-current-callback-core-current-v1.log` | PASS, 239 cases, 47.9 seconds | `fc425ec01e028df06d82a0e14a06322a2adf62e3cbb889c1b71f00dbaf6dcd9d` |
  | `/private/tmp/loopex-m7-current-callback-core-floor-v1.log` | PASS, 239 cases, 47.9 seconds | `e976793d8615d398375648a07963f1dc7c9b411e4804287ead6c23696d9e177c` |
  | `/private/tmp/loopex-m7-current-callback-reqllm-current-v1.log` | PASS, 110 cases, 16.3 seconds | `113fd0fd0a38725dd1b67da57b77e584802d5f1f300fb94ddf97bb8228d930cf` |
  | `/private/tmp/loopex-m7-current-callback-reqllm-floor-v1.log` | PASS, 110 cases, 16.1 seconds | `bd4cd8352cc7d27a0e07726e82c7711dbf7e846aa55c0a053cdeeedb3979a5e6` |
  | `/private/tmp/loopex-m7-current-callback-buffered-current-v1.log` | FAIL, 4/5 cases; selected one-byte key collides with required completion | `e06c65f4552a3d0563e19922dea9bec6775a5d640f5ed9e16d74c60d6ef83ba3` |
  | `/private/tmp/loopex-m7-current-callback-buffered-current-v2.log` | PASS, 5 cases, 6.1 seconds; explicit collision refusal and unchanged key bounds | `c410f7146fc84df235048a6d36747db105bcdb48104c2be56eed99d2a049e74c` |
  | `/private/tmp/loopex-m7-current-callback-buffered-floor-v1.log` | PASS, 5 cases, 6.1 seconds | `26188a9b3c08563cc85ef6163bb460aab96e72f94a91bd22231346ce793b6fbe` |
  | `/private/tmp/loopex-m7-current-callback-composition-current-v1.log` | PASS, 42 cases, 5.0 seconds | `6c888a60d55a756f0403673705bf7f62aca0a5a17b2bdcad9e1802fd3976b66a` |
  | `/private/tmp/loopex-m7-current-callback-composition-floor-v1.log` | PASS, 42 cases, 5.1 seconds | `13e234a40a823da73744f9df08a5db13d6e689987c029b468f8f885b1860640b` |
  | `/private/tmp/loopex-m7-current-callback-reference-current-v1.log` | PASS, 20 cases, two excluded, 3.8 seconds | `2932f6c9460ccf30639678ccbc2789f95243e87b23f6b0cb773e84b24496122a` |
  | `/private/tmp/loopex-m7-current-callback-reference-floor-v1.log` | PASS, 20 cases, two excluded, 3.7 seconds | `d5a9687f63e03bb0d265404509c39641cff9e9a4f8876de78305554d858429d0` |
  | `/private/tmp/loopex-m7-current-callback-audit-v2.log` | PASS, 642 parsed application source/test files, zero retired callback literals or two-argument calls/captures | `95e61c046cdbeb9c75dec1e2a4bd4dd49bd17cfc17deb91c1d4480d0935aa15e` |
  | `/private/tmp/loopex-m7-current-callback-static-current-v1.log` | PASS, compilation, formatting, bootstrap/status, docs, dependency direction and versions | `f8bfde7561d513c3954cb28a6b66ec369865417df06a7666a18d71bd86922d90` |

  Final metadata bootstrap, compiled documentation, formatting, checklist
  reporter and whitespace checks pass. Complete immutable output is
  `/private/tmp/loopex-m7-current-callback-final-metadata-v1.log`, SHA-256
  `cfdd5db0125ed44cc1c54cc88c93aca4361ba7da196af81d88a41120c147a52c`. This identity is recorded after collecting the terminal result.

  Two original T08 rows close, leaving T08 original 7 done / 4 todo. The added
  T15 callback migration closes, leaving T15 added 7 done / 2 todo. A separate
  added T16 integration proof is open, leaving T16 added 38 done / 2 todo.
  T01–T19 originals are 56 done / 117 todo / 6 retired; added is 212 done /
  10 todo. Every milestone outcome remains Open; no other original row closes.

- Failed: the single full current-pair fast check of clean, pushed
  `3aa219605d46748dbf8d3e6b777cf44321ad90bf` ended with exit 1 after 925
  measured shell seconds. Ten application suites passed. Composition executed
  all 489 cases successfully with one expected exclusion, but Mix's
  warnings-as-errors rejected the new `test/support/delegation_genesis_fixture.exs`
  because it matched neither the configured test-load nor test-ignore filters.
  Aggregate assertions are 3,696 passed / 39 excluded; the required integration
  verdict is FAIL, not PASS. Complete output is retained read-only at
  `/private/tmp/loopex-m7-3aa21960-fast-check.log`, SHA-256
  `1029e090dd41e41c665679fc6fb2f4b7580a6ee6fc97aa7e3e48332a34e693a2`.
  Execution handle `62407` is terminal and collected. Do not poll or rerun this
  failed candidate into green.

  The support-only module is now listed alongside the two existing supporting
  modules in composition's explicit `test_ignore_filters`. It defines fixture
  construction and contains no test cases; the codec test explicitly requires
  it. No `_test.exs` file is ignored, no assertion or check is removed and
  warnings remain errors. The same three focused files still execute all 28
  cases with `--warnings-as-errors` on both pairs, in 2.7 and 2.8 seconds.
  This focused result does not establish a full automatic-discovery integration
  pass; a new clean candidate must run once after the repair.

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-helper-fixture-discovery-focused-current-v1.log` | PASS, 28 cases, 2.7 seconds, warnings-as-errors | `da016e21e11301f555926839b1a4c87f008764914b986482121937aa29bda237` |
  | `/private/tmp/loopex-m7-helper-fixture-discovery-focused-floor-v1.log` | PASS, 28 cases, 2.8 seconds, warnings-as-errors | `daf4371998bd72ea342b8d28dbbc8d9a553112a9e077a443613644e34a3ba3a8` |

  Warning-free compilation, formatting, bootstrap/status, documentation,
  dependency direction and version checks pass. Complete read-only output:
  `/private/tmp/loopex-m7-helper-fixture-discovery-static-current-v1.log`, SHA-256
  `a1a19310d07d01925d0e62c1bd81761c9563efc2b9615f52f267bcba6334170b`.
  One added T16 discovery repair subtask closes, leaving T16 added 38 done /
  1 todo. The newly identified T15 callback migration is open. T01–T19 originals
  remain 54 done / 119 todo / 6 retired; added is now 211 done / 10 todo.
  No original row closes, and the failed full check remains failed.

- Done: T11's accepted private retained-genesis codec is implemented for
  parent creation objects and child reservation objects. It writes exactly
  `encoding`, padded base64 `bytes` and lowercase `sha256`, using the normalized
  current v3 plain map rather than protocol Canonical's tagged tree. Readers
  enforce the 65,536-byte decoded core limit and canonical base64 before
  existing-atom-only, complete-consumption ETF decoding, then invoke the shared
  core genesis validator. Compressed ETF, unsafe terms, forged settings,
  trailing bytes and superseded genesis refuse. No ledger IO, new facade,
  session creation, defaults lookup or launch authority is introduced.

  Both supported pairs pass all 28 cases in the new codec, fixed helper
  declaration and session-admission files without warnings: current 2.7 seconds,
  floor 2.8 seconds. The first current run also passed assertions but emitted
  a test-syntax warning; it is not warning-free evidence. Direct binary-part
  access replaces that syntax without changing the pad-bit refusal assertion.
  Tests prove opaque non-UTF-8 values, exact core create-transaction identity,
  both retained writer fixtures, valid alternate ETF bytes without re-encoding
  equality, atom noncreation, encoded representation checks and exact
  65,535/65,536/65,537-byte boundaries. Complete JSON counts base64 expansion.
  The framing/credit, writer fencing, bindings/catalogs, router, allowance,
  classification and actual helper execution remain open; no original T11
  item closes from this codec slice.

  Actual current and floor writers each produced a 1,463-byte payload and
  2,088-byte complete JSON object. Their payload SHA-256 is
  `eda2b1dd1e4263aa3b974bf12adaf0c47d71fb27c47c3c02d4bb4b40da1c8a35`.
  The independently written
  [current fixture](../../apps/loopex_composition/test/fixtures/delegation/genesis-current-v1.json)
  and [floor fixture](../../apps/loopex_composition/test/fixtures/delegation/genesis-floor-v1.json)
  have identical complete-file SHA-256
  `80e5beb24bee2e8bbd94df1edf7f9c1e0535b9a78fd3a927b1cdb70b69f22f81`.
  Each pair reads both fixtures. Their equality is observed evidence, not a
  cross-major writer-stability requirement; the alternate-encoding positive
  control proves acceptance does not depend on re-encoding equality.

  Complete retained outputs and the writer source are read-only:

  | Retained reference | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-genesis-vector-writer.exs` | Actual-pair fixture writer source | `f39c32bf2ea07a894bac677d69fc0f8f2a89f6f87f55d4a00df89633d18f78d3` |
  | `/private/tmp/loopex-m7-genesis-vector-writer-current-v1.log` | PASS, actual current writer and immediate read | `6d8bda8d66c3bd90642b4f13b40ff8d6d37693a9d6cacea35b4f8ded8dcafeca` |
  | `/private/tmp/loopex-m7-genesis-vector-writer-floor-v1.log` | PASS, actual floor writer and immediate read | `5e370b5c7ccb45388c36dbe6cd2535cee4bdfc7c9772dfe4b9d406f7f70a4f49` |
  | `/private/tmp/loopex-m7-helper-genesis-codec-focused-current-v1.log` | 28 assertions passed, 2.7 seconds; test warning, not warning-free proof | `5245f0ede490454165c256e2b883b473fa5ad63914f330dd8ff3b6ee3a81e8ad` |
  | `/private/tmp/loopex-m7-helper-genesis-codec-focused-current-v2.log` | PASS, 28 cases, 2.7 seconds, warning-free | `d389ef5098c60c84daa57bb0fb5420d1d603a80cc947043e03f5a9dad509e0eb` |
  | `/private/tmp/loopex-m7-helper-genesis-codec-focused-floor-v1.log` | PASS, 28 cases, 2.8 seconds, warning-free | `b0565659dcf036de5b5dc850e827f23ca26c8656b8960d6a92320e296086402f` |
  | `/private/tmp/loopex-m7-helper-genesis-codec-static-current-v1.log` | FAIL, new production file not yet tracked in the Git index; earlier compile/format/bootstrap/docs passed | `813f768854007114c28076476430a782e62c17cfab7bf94e5c0dad8e4ce823c4` |

  The existing dependency gate requires compile sources to be tracked ordinary
  100644 blobs. Staging the new files satisfies that admission condition; the
  gate is unchanged. After staging, warning-free compilation, formatting,
  bootstrap/status, compiled documentation, dependency direction and version
  checks all pass. Complete output is retained read-only at
  `/private/tmp/loopex-m7-helper-genesis-codec-static-current-v2.log`, SHA-256
  `a1a19310d07d01925d0e62c1bd81761c9563efc2b9615f52f267bcba6334170b`.
  One added T11 codec subtask closes: T11 added becomes 6 done / 0 todo.
  T01–T19 originals remain 54 done / 119 todo / 6 retired; added becomes
  210 done / 9 todo. No original row closes. Final metadata checks and the
  new committed candidate's integration proof remain separate from these
  both-pair focused and static results. Final metadata bootstrap/status,
  compiled-documentation, exact-denominator reporter and diff checks also pass.
  Complete output is retained read-only at
  `/private/tmp/loopex-m7-helper-genesis-codec-docs-current-v1.log`, SHA-256
  `ff78515843c09c85bf861dcf272548514cb61945e39caf65e1c7e1064dd3a7de`.

- Done: the full current-pair fast check ran once from clean, pushed
  `6635cb490c978030b9b163fe40f347dbf9db19d4` and passed all eleven application
  suites: 3,686 tests passed and 39 expected exclusions. The check reports
  924 seconds; its separately captured shell stopwatch reports 923 seconds.
  The exact artifact-abort fixture that failed on the parent is included in
  Core's 1,217 passing cases. Complete output is retained read-only at
  `/private/tmp/loopex-m7-6635cb49-fast-check.log`, SHA-256
  `e04a78fc6ec036b14fb837cbd67ed656463626cff115357a7c9ed741e73a4498`.
  Execution handle `43022` is terminal and collected; do not poll or rerun it.
  The failed `14a54d1f` run below remains failed. This current-pair integration
  proof claims no floor full check, release matrix or milestone closure.
  T01–T19 originals remain 54 done / 119 todo / 6 retired; added subtasks
  become 209 done / 9 todo, including T16's 37 done / 1 todo. No original
  item closes from this intermediate integration candidate.

  The evidence-only update passes bootstrap/status and compiled-documentation
  checks. Complete output is retained read-only at
  `/private/tmp/loopex-m7-6635cb49-integration-evidence-docs-v1.log`, SHA-256
  `46edfa3986660cc1f792a183e0967d9a1c524233ec1b5e1a22022b21fad05da8`.

- Failed: the full current-pair fast check ran once from clean, pushed
  `14a54d1f6cd18994bdbdf5f4a6fbbd495b5a94f6`. Ten application suites passed;
  Core passed 1,216 of 1,217 with eight exclusions. The aggregate is 3,685
  passed, one failed and 39 excluded, not PASS. The artifact-abort test at
  `test/artifact_runtime_test.exs:184` did not receive its retention-worker
  notification within the existing 1,000-ms allowance. Core finished after
  238 seconds; the retained log's creation-to-final-write span is 926.020
  seconds, not a separately captured command stopwatch. Complete failed output
  is retained read-only at `/private/tmp/loopex-m7-14a54d1f-fast-check.log`,
  SHA-256 `16f207a8d36d2b652488397092779e32a8c2e8ee674700f8c7dd315e4c7fcd07`.
  This failed candidate will not be rerun into green.

- Done: the artifact-retention live fixture now establishes its original
  executor callback before beginning retention/commit waits. The existing
  executor progress gate has its already-declared 5,000-ms prerequisite
  allowance. Before releasing that exact worker, the fixture proves no executor
  receipt or artifact IO exists. Its original 1,000-ms retention/commit waits,
  exact retention-worker DOWN checks, 60,000-ms preparation cutoff and actual
  1,000-ms run deadline stay unchanged. This separates prerequisite scheduling
  from the cancellation/retention phase; no production contract or required
  assertion is relaxed.

  A bounded diagnostic comparison deliberately holds the permitted predecessor.
  The original receive fails after 1,000 ms, while the explicit-release branch
  reaches retention and proves the exact killed worker, cancelled terminal,
  zero retained objects and no second model dispatch under the original waits.
  The two-case probe ends nonzero: one expected diagnostic failure, one passing
  comparison and eighteen filtered base-file cases. It is not an aggregate pass
  or a replacement for the required file. The probe and complete output are
  retained read-only:

  | Retained reference | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-artifact-abort-prerequisite-probe_test.exs` | Controlled prerequisite diagnostic source | `bca2973f4194208de929cb9fd1572e9ff9420dbe4db64bff9c1c0fd7d7a6a196` |
  | `/private/tmp/loopex-m7-artifact-abort-prerequisite-probe-current-v1.log` | FAIL as designed, 1/2 passed, eighteen excluded, 2.3 seconds; old receive fails under a held predecessor | `495b5aa3077a96ad1c45b2708dcc40831eaf89223e58015aa04d9495b38e5df4` |

  The repaired complete artifact file and four surrounding capability,
  admission, excerpt and reference files pass 50 cases with one existing
  long-bound exclusion on both supported pairs, in 3.2 and 3.3 seconds.
  Warning-free compilation, formatting, bootstrap/status, compiled documentation,
  dependency direction and version checks pass. This closes one added T16 fixture
  repair subtask. T01–T19 originals remain 54 done / 119 todo / 6 retired;
  added subtasks become 208 done / 9 todo, including T16's 36 done / 1 todo.
  The failed integration evidence remains failed and a new committed candidate
  needs its own full check. No original item closes here.

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-artifact-retention-barrier-focused-current-v1.log` | PASS, 50 cases, one excluded, 3.2 seconds | `7d339774d599636225e0f4d1b8e4fed87c9211e9f50f8e1c0d2937d470332ae2` |
  | `/private/tmp/loopex-m7-artifact-retention-barrier-focused-floor-v1.log` | PASS, 50 cases, one excluded, 3.3 seconds | `baee44d88f8a66946d8b629a4c46bca700519665eb20f168ab51c49f2af1ef42` |

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-artifact-retention-barrier-static-current-v1.log` | PASS, compilation/format/bootstrap/docs/dependencies/version | `1a54d3c437d1b19203b3d1a198b4382f8afb6533981cdd8a5154c427884dd627` |

  The final metadata bootstrap and compiled-documentation checks also pass;
  this retained-output identity is appended after collecting that result.

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-artifact-retention-barrier-docs-current-v1.log` | PASS, final metadata bootstrap/docs | `46edfa3986660cc1f792a183e0967d9a1c524233ec1b5e1a22022b21fad05da8` |

- Done: live standalone source preparation, provider dispatch and failed
  completion now follow the actual compact command through the shared maintenance
  worker, Control permit, provider guard and settlement path. The tagged command
  key is transient; durable requests retain the actual episode/summary identity.
  No synthetic run, ordinary stream, run deadline or run accounting is created.
  The same captured cutoff covers source work, attempts and settled pending
  checkpoints. Exact source-worker DOWN and unchanged journal head precede
  adoption. Irreducible excerpts retain the accepted named nil-scope refusal;
  frozen summarizer system overflow retains its exact maintenance measurement.
  Both end before provider intent with zero usage and confirmed cleanup.

  Invalid or non-progressing natural summaries end once with their exact reported
  usage. One not-dispatched retry reuses the same retained request and accounts
  for both physical attempts. Abort and expiry collect late usage and join the
  actual provider callback/tree. A useful settled summary stays pending under
  its original cutoff; expiry ends it without another settlement or call. The
  derived attempt owner epoch comes from the authenticated open-record journal
  stamp, adding no persistent field. A successor reports inherited cleanup as
  unknown even when a new abort or deadline wins over owner loss. An expired
  inherited attempt changes no journal fact while prepared pause is active;
  activation admits the winning ending without redispatch.

  Twenty new live cases include exact source-worker loss/abort/deadline joins,
  all three Store uncertainty phases at request/open and failed settlement,
  immutable capture, duplicate/restart results, once-only usage, unchanged raw
  facts and conservative inherited-attempt spending. The ten-file selection
  passes 302 cases with two existing exclusions on both supported toolchains.
  The complete current Core suite passes 1,217 cases with eight existing
  exclusions in 216.2 seconds. Warning-free compilation, formatting, bootstrap,
  compiled documentation, dependency direction and version checks pass.
  This closes one added live source/provider failure-path subtask. T01–T19
  originals remain 54 done / 119 todo / 6 retired; added subtasks are now
  207 done / 9 todo, including T07's 40 done / 1 todo. These are development
  proofs, not a full fast check of these bytes, provider lanes or closure matrix.
  Successful checkpoint emission, continuation/results, snapshots, complete
  cleanup integration and real-provider proofs remain open; the checkpoint-owner
  decision is still unanswered. No original T07 outcome closes here.

  Development failures remain failed. The malformed new expected cause, sampling
  lookup, estimator namespace and run-budget fixture were repaired. Two commands
  ran Core-relative selections from the umbrella root; their other application
  paths were unmatched, so neither whole command is counted as a pass. The new
  map fixture's keyword ordering was repaired after formatting refused it.
  The first floor run passed its assertions but warned on literal membership
  comparisons in the generated recovery cases. A direct case branch preserves
  the activation/abort assertions and removes those warnings on both pairs.
  No production limit, receive timeout, required assertion or check was weakened.
  Complete outputs are retained read-only:

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-live-standalone-provider-current-v1.log` | FAIL, Core 125/126 passed, 4.4 seconds; umbrella selection paths unmatched and wrong new expected cause | `fe8434b99884f401ae3040956b97a4071352dd9764259e47e586c3a6bfdca227` |
  | `/private/tmp/loopex-m7-live-standalone-provider-current-v2.log` | FAIL, 125/126 passed, 4.5 seconds; new fixture read absent request.reasoning | `107a2339d02bcc35a5a8d078d6017f94ae7a8c136e17f4178ddc383171ac2f46` |
  | `/private/tmp/loopex-m7-live-standalone-provider-current-v3.log` | PASS, 128 cases, 4.5 seconds | `173014ea0439d07c96d6ec8f856938abb349360e49519738879deeb03e432f67` |
  | `/private/tmp/loopex-m7-live-standalone-provider-current-v4.log` | PASS, 129 cases, 5.4 seconds | `770d20d8128fade890d70bb8c68bc49873f6308f5354b24176582f6a445b4cb7` |
  | `/private/tmp/loopex-m7-live-standalone-provider-current-v5.log` | PASS, 135 cases, 6.6 seconds | `234f71dae296431a71bd54a88113139d21577abbde74d7e240a98b46d61a9f52` |
  | `/private/tmp/loopex-m7-live-standalone-provider-current-v6.log` | FAIL, 134/136 passed, 6.6 seconds; new fixture used wrong estimator namespace and incoherent run configuration | `33d3137fcf9411895a27195a6c438447e23cf19155c0e421cb34e0c38055d3b5` |
  | `/private/tmp/loopex-m7-live-standalone-provider-current-v7.log` | FAIL, umbrella selection paths unmatched; Core selection alone passed 136 cases in 6.6 seconds | `0d33ba15a956a17f260a33f75571b88b39c94b64e0924920867382a88e5ee7f8` |
  | `/private/tmp/loopex-m7-live-standalone-provider-focused-current-v1.log` | PASS, 298 cases, two excluded, 18.5 seconds | `44406ae3a40b8833d98e5e3a3084d4858ece8b4c7d9716acbff29166c3b871b8` |
  | `/private/tmp/loopex-m7-live-standalone-provider-focused-current-v2.log` | PASS, 301 cases, two excluded, 18.6 seconds | `f70bd1bbc30c2628e09c52b2e5bc8c50e13e2f8a0597455fe8ace5c7deafa57d` |
  | `/private/tmp/loopex-m7-live-standalone-provider-focused-current-v3.log` | PASS, 302 cases, two excluded, 19.8 seconds | `f9ae593287df54e19ed2f0ce5a3161ce6d28fa3f7be43f836ea4f228e0711515` |
  | `/private/tmp/loopex-m7-live-standalone-provider-focused-floor-v1.log` | Assertions pass, 302 cases, two excluded, 18.9 seconds; four compiler type warnings, not a warning-free checkpoint | `68804efe87eacabe8119a5ba56a0b569a3981e607f0ec5f02e22e07907b83996` |
  | `/private/tmp/loopex-m7-live-standalone-provider-focused-current-v4.log` | PASS, 302 cases, two excluded, 19.5 seconds; repaired test branch | `d2f96c5cb8a368896d99b973793f1877a388a6fd0c42fe2d74ec3f48f5933ddf` |
  | `/private/tmp/loopex-m7-live-standalone-provider-focused-floor-v2.log` | PASS, 302 cases, two excluded, 19.0 seconds; repaired test branch, no compiler warnings | `2a1472f2e191fd8998d98f1400e12490b5c2c2dd6ea39aa1b2e1f64755ce2519` |

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-live-standalone-provider-core-current-v1.log` | PASS, 1,217 cases, eight excluded, 216.2 seconds | `e8d8c1c7b0c6389f24b8d675a11bc2706072243b1de7842079f4840c4382cd4e` |
  | `/private/tmp/loopex-m7-live-standalone-provider-static-current-v1.log` | PASS, compilation/format/bootstrap/docs/dependencies/version | `ebb9516142f74ed63e4d323121aba71b0ec4062106a6992a297a75fbe0bbfd82` |

  The final metadata bootstrap and compiled-documentation checks also pass;
  this retained-output identity is appended after collecting that result.

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-live-standalone-provider-docs-current-v1.log` | PASS, final metadata bootstrap/docs | `46edfa3986660cc1f792a183e0967d9a1c524233ec1b5e1a22022b21fad05da8` |

- Done: standalone pending checkpoints now reuse exact whole-record substitution
  under the actual compact command and captured cutoff. Pure probes authenticate
  original whole-unit coverage, prior checkpoint, source omission and settled
  summary provenance without changing history or charging another attempt.
  Explicit/size triggers require strict record-byte and token reduction; rendering
  repair advances contiguous raw coverage and must fit every ordinary hard limit,
  allowing byte/token growth. Non-progress completes through the existing leading
  episode terminal and compact completion with retained usage, no checkpoint and
  no second settlement. Useful substitutions cannot claim a non-progress ending.
  Abort, absolute expiry, invalid clocks, changed ranges and every cancellable
  traversal stop refuse before adoption. Six new pure-projection tests, one new
  actual-tool-history hard-overflow test and the extended actual rendering-growth
  case pass with existing coverage. The ten-file current/floor selections pass
  282 cases with two existing exclusions in 15.3 and 14.8 seconds. Checkpoint
  emission, public owner encoding and the live standalone workflow remain open.

  Development failures remain failed. New fixtures were corrected to declare
  coherent system/context ceilings, an explicit custom-budget origin and a valid
  summary body. No production bound, required assertion or check was weakened.
  The v4 run followed a failed edit script against unchanged source and supplies
  no additional boundary proof. Complete outputs are retained read-only:

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-current-v1.log` | FAIL, 121/122 passed, two excluded; new fixture system ceiling exceeded its context ceiling | `768a4dc9f1377de06910d3bb41ea9f6dc6dc9d82cf36d6a7d3480bfea823adbe` |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-current-v2.log` | FAIL, 121/122 passed, two excluded; new fixture still retained the default system ceiling | `f2f0e506fb0b31c40e8a8e10dcdf3d9b853d1ae28c32827e4a1a04176f2b56db` |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-current-v3.log` | PASS, 122 cases, two excluded, 7.4 seconds | `69852fa3eb7e8a4ed04b2744971dc937443f9e58cb9ca93ba9cba2ccd72af270` |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-current-v4.log` | PASS, 122 cases, two excluded, 7.3 seconds; unchanged focused rerun after an edit script failed, no additional proof | `d19685c90124945547f79edfc7898f7cf312fff30b1ecc26f392d315eb4c6b14` |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-current-v5.log` | FAIL, 122/123 passed, two excluded; new custom-budget fixture lacked an explicit origin | `b1ee8de059f901a299323d7622825ceae21c7441470960f07f8629bec063ea3b` |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-current-v6.log` | FAIL, 122/123 passed, two excluded; new summary fixture exceeded the existing 4,094-byte body ceiling | `662209d44dcc17056323d4726244441ae72a863d3a76c28f87616736c8309323` |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-current-v7.log` | PASS, 123 cases, two excluded, 7.6 seconds | `af545c5f50c72af7247506d5144bc795e44858f6eaae47d9c59c485301570706` |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-focused-current-v1.log` | PASS, 282 cases, two excluded, 15.3 seconds | `60105b7b293a9362d397239daba02409aded7c675d5f640d5ad4a755fd99ec70` |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-focused-floor-v1.log` | PASS, 282 cases, two excluded, 14.8 seconds | `2ec2de9120be576d777403b64c38d4ddc91cb24e3577562cdd2c958ee1e6db54` |

  This closes one added pure checkpoint-measurement/non-progress subtask only.
  T01–T19 originals remain 54 done / 119 todo / 6 retired; added subtasks are
  206 done / 9 todo, including T07's 39 done / 1 todo. The complete current
  Core suite passes 1,197 cases with eight existing exclusions in 217.2 seconds.
  Warning-free compilation, formatting, bootstrap/status, compiled documentation,
  dependency direction and version checks pass. These are development proofs,
  not the full integration fast check, provider lanes or closure matrix.

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-static-current-v1.log` | PASS, compilation/format/bootstrap/docs/dependencies/version | `035a294b6c953811856e60b09690672f2d39c0d19f9161478842a148486fb816` |

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-core-current-v1.log` | PASS, 1,197 cases, eight excluded | `c4169419cfcd289d6b6e440b1c19c53f6f926bfea595b97e19059a113c9638e4` |

  The final metadata bootstrap and compiled-documentation checks also pass;
  this retained-output identity is appended after collecting that result.

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-checkpoint-probe-docs-current-v1.log` | PASS, final metadata bootstrap/docs | `46edfa3986660cc1f792a183e0967d9a1c524233ec1b5e1a22022b21fad05da8` |

- Historical proposal, now resolved by the
  [explicit-owner decision](../developer/agent-context-map.md#disposition-m7-standalone-checkpoint-owner-2026-10-03): standalone checkpoint ownership. A compact
  command owns its episode without a run; the existing checkpoint kind and
  context.compacted projection require run_id. Recommend a distinct closed
  private standalone_compaction_checkpoint_committed_v1 kind with command_id,
  preserving the existing run-owned kind with run_id. Public checkpoint events
  and snapshots would replace run_id with exactly owner: {kind: "run" | "compact",
  id: opaque identity}, derived from the authenticated private variant. The
  episode binds the actual owner; lineage.through_run_id remains the last actual
  original run traversed. No synthetic run, run terminal, run accounting or run
  deadline is introduced.

  The alternative keeps the shared private kind and existing public run_id,
  permitting null only for standalone ownership and authenticating its command
  indirectly through the episode. It changes fewer fields but introduces nullable
  ownership. Either selected current contract must migrate producers, replay,
  projections, fixtures and independent vectors together with no old aliases.
  Current-format restart, unknown commits and backup/restore remain required.
  This is a proposal, not an accepted ADR amendment. AGENTS.md requires a
  maintainer decision for the persistent/public schema; dependent emission is
  paused while independent preparation/integration work may proceed. The question
  has been submitted and has no answer. The complete proposal is retained at
  `/private/tmp/loopex-m7-standalone-checkpoint-owner-decision.md`, SHA-256
  `1b16d7d5fc31f5b42a6c807ac46b7ec2064f55e76683993bb5a8353f8601c9d5`.

  Two earlier decisions also remain unanswered: the stalled-stderr fixture's
  captured 1,000-ms writer-start cutoff and exact exit, and the small maintenance
  allowance failure branch for a 1,024-token reply reserve. Recommend the closed
  maintenance_reply_reserve_unavailable cause instead of adding a broad public
  reply_reserve bound. The existing failed fast-check evidence remains failed.

- Done: standalone maintenance settlement now spends the captured episode's own
  allowance, without changing run accounting, pending work or deadlines. Readable
  usage is charged exactly once, including reported overshoot; unreadable replies
  and dispatched failures conservatively charge the remaining declared allowance.
  A not-dispatched attempt consumes only attempt capacity and permits the same
  request's single retry while the episode ceiling allows it. Reaching that ceiling
  closes with the exact max-attempts bound. Successful readable summaries remain
  checkpoint-pending. Incomplete/invalid summaries close with their accepted cause;
  unreadable replies retain model-call failure and no invented reported usage.
  Failed attempt transactions lead with the episode terminal, then settlement and
  compact completion. Replay authenticates the exact retained result, winning
  cancellation/deadline/provider failure, usage and cleanup, and rejects missing
  rows, rehashed result substitutions and duplicate completion. Owner loss retains
  unknown cleanup. Post-settlement retry/checkpoint cancellation and fixed-cutoff
  expiry complete without another settlement or charge. The bounded reader accepts
  closed spent failures, rejects malformed accounting/clock/disposition, and emits
  no executor effects. Current/floor nine-file selections pass 268 cases with two
  existing exclusions in 15.6 and 15.2 seconds. These are reducer/reader development
  proofs; live standalone dispatch, checkpoint completion, snapshots and cleanup
  integration remain open. No required check or product bound changed.

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-settlement-focused-current-v1.log` | PASS, 268 cases, two excluded | `dbb91cd04310e3c284eee6f9ba9de03080607dacaf3a3316af5aff2fc80f1f06` |
  | `/private/tmp/loopex-m7-standalone-settlement-focused-floor-v1.log` | PASS, 268 cases, two excluded | `d5e21eae800a9972f2d437e50ecb7ed26d14c0f0f656c372033de4aa8da702f8` |

  Development failures stay failed. The initial duplicate-result fixture expected
  a proposal instead of the reducer's existing replayed result and also produced
  a type warning; correcting the fixture restored its exact result assertion.
  A later map pattern placed a binary key after keyword syntax and failed
  compilation; reordering the keys repaired syntax without changing behavior.
  Complete outputs are retained read-only outside the repository:

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-settlement-current-v1.log` | FAIL, 104/105 cases, two excluded; fixture expectation and type warning | `91134d352aea324fcb5dce566e4215a59917125ca272ef20bfd16616108290d3` |
  | `/private/tmp/loopex-m7-standalone-settlement-current-v2.log` | PASS, 127 cases, two excluded, 9.2 seconds | `3bf5c0940ca39cf456f27ff061f65c46e8c99d1827a5a5c2fb98eb74c719c549` |
  | `/private/tmp/loopex-m7-standalone-settlement-current-v3.log` | FAIL, compilation syntax | `d23df431c166d57425d208ad6b42f288cd18b2f9c0305326be2d8ccbcabcc644` |
  | `/private/tmp/loopex-m7-standalone-settlement-current-v4.log` | PASS, 131 cases, two excluded, 9.2 seconds | `a94559e8a1bb4877d391519dd5ba88161251d9a8204531bb994c449c06ec0376` |

  T01–T19 originals remain 54 done / 119 todo / 6 retired. Added subtasks are
  205 done / 9 todo, including T07's 38 done / 1 todo. Both earlier maintainer
  decisions remain pending. Next join standalone checkpoint continuation and
  the live dispatch/settlement workflow under the actual compact identity.

  The complete current Core suite passes 1,190 cases with eight existing
  exclusions in 215.3 seconds. Compilation without warnings, formatting,
  bootstrap/status, compiled documentation, dependency direction and version
  train also pass. Complete outputs are retained read-only:

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-settlement-core-current-v1.log` | PASS, 1,190 cases, eight excluded | `d1ae706ead8afeb4bd7a33658ee0c30c2bb697d68abe3e4810143144c9a6f1a6` |
  | `/private/tmp/loopex-m7-standalone-settlement-static-v1.log` | PASS, compile/format/bootstrap/docs/dependencies/version | `035a294b6c953811856e60b09690672f2d39c0d19f9161478842a148486fb816` |

  The static run precedes adding its own digest and this Core result to the
  evidence entry. Bootstrap/status and compiled documentation are checked after
  this metadata backfill and pass. Complete output is retained read-only at
  `/private/tmp/loopex-m7-standalone-settlement-final-docs-v1.log`, SHA-256
  `46edfa3986660cc1f792a183e0967d9a1c524233ec1b5e1a22022b21fad05da8`.
  This final reference is appended after that check. No production or test
  changes follow these runs. All check handles are terminal and collected;
  no agents are running. Next implement standalone checkpoint substitution,
  continuation and successful completion, then join actual provider dispatch
  and the retained settlement path in the live owner. The integrated workflow
  subtask remains open. The next clean integration candidate's full fast check,
  real-provider lanes and closure matrix remain required.

- Done: standalone captured source selection now reuses the maintenance source
  encoder, fixed-point Store sizing and adjacent request/open proposal. The actual
  compact command and idle session bind its whole-session selection. Its admitted
  absolute deadline and frozen maintenance selection stay unchanged through a
  later journal head; opening an attempt adds no run deadline or run accounting.
  All eligible units may be released, with a null first-kept identity. The bounded
  reader permits that null only when the covered count equals the eligible count.
  Both supported-pair focused selections pass 254 cases with two existing
  exclusions, current in 15.5 seconds and floor in 14.9 seconds. Tests cover exact
  request/open replay, the 1,024-token reserve, oversized-unit excerpts, unchanged
  raw facts, cancellation and forged or incomplete staging pairs. The provider
  dispatch, settlement, checkpoint and final completion integration remains open.
  These are development checks, not closure or real-provider evidence.

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-staging-focused-current-v2.log` | PASS, 254 cases, two excluded | `e267c703cbff443bc46ada4ddd5a51e43f47516f3e7ad3bc4b58b2c713efbd1d` |
  | `/private/tmp/loopex-m7-standalone-staging-focused-floor-v1.log` | PASS, 254 cases, two excluded | `25c678089592758d8b7b1843a21848f76aff7118a22a428aab9c35b96d961a18` |

  Intermediate complete passing outputs are retained read-only under
  `/private/tmp/loopex-m7-`: `standalone-staging-current-v1.log`, 74 cases in
  2.1 seconds, SHA-256 `946a161ba10badcc1abc4040c8856879a6c8715de22107ec78d817bbe7b42228`;
  `standalone-staging-current-v2.log`, 96 cases in 3.6 seconds, SHA-256
  `b0eb9ec47795fb64f56bc87b1cd2c3a8a23c4d96b1cd5d71296a1bb4e8da9a82`;
  `standalone-staging-current-v3.log`, 98 cases in 3.7 seconds, SHA-256
  `edfc38a253b4d4167410125984cce56e559059974fefdcaba5c6068e0c5e5430`;
  and `standalone-staging-focused-current-v1.log`, 254 cases with two exclusions
  in 15.6 seconds, SHA-256
  `617b174180b29542289f6f822cad05bc0c9833cdf9c395ca15db6bf77259e408`.
  The last intermediate run precedes the bounded reader's rejection of null
  first-kept identities on partial selections; both final selections include it.
  T01–T19 originals remain 54 done / 119 todo / 6 retired; added subtasks are
  204 done / 9 todo, including T07's 37 done / 1 todo. Both earlier maintainer
  decisions remain pending. The complete current Core suite also passes 1,176
  cases with eight existing exclusions in 215.6 seconds; its retained output and
  static results are recorded below.


  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-staging-core-current-v1.log` | PASS, 1,176 cases, eight excluded | `9c53eb0b34fa31a7458a89b7cebf5826e0ef90efcefd7048422159652cb4e622` |
  | `/private/tmp/loopex-m7-standalone-staging-static-v1.log` | PASS, warning-free compile, format, bootstrap/status, compiled documentation, dependency direction and version train | `ebb9516142f74ed63e4d323121aba71b0ec4062106a6992a297a75fbe0bbfd82` |

  The static run precedes adding its own digest and the Core digest to this
  entry. Bootstrap/status and compiled documentation are checked again after
  that metadata backfill and pass. Complete output is retained read-only at
  `/private/tmp/loopex-m7-standalone-staging-final-docs-v1.log`, SHA-256
  `46edfa3986660cc1f792a183e0967d9a1c524233ec1b5e1a22022b21fad05da8`.
  This final reference is appended after that check. Production and test bytes
  remain unchanged. All check handles are terminal and collected; no agents
  are running. Continue by joining standalone provider settlement and checkpoint
  completion to the captured source workflow; no complete standalone workflow
  or milestone closure is claimed.

- Done: standalone initial preparation now runs through the actual session owner
  and supervised pure-proposal worker. One captured clock bounds its candidate
  admission; the exact worker DOWN and unchanged journal head precede adoption.
  Prepared successors pause recovered compact identities; fresh commands after
  preparation progress independently of an ordinary model. Empty fitting history
  completes unchanged without summarizer settings. Missing model/instructions or
  unsupported reasoning complete failed before any episode or attempt. Actual
  cancellation, lost worker and cutoff expiry join the worker before zero-usage,
  confirmed-cleanup completion. Captured zero-attempt episodes commit their
  leading terminal and compact completion together; replay rejects incomplete
  prefixes, substituted identities/results/clocks and nonzero usage. The bounded
  private reader rejects unknown cleanup or a checkpoint in this undispatched
  generation. Completion returns its exact result on duplicate lookup and
  preserves the original admission-disposition fact.
  All three Store uncertainty phases prove one capture with unchanged settings
  and absolute cutoff, or one completed result/event, across exact owner exits
  and prepared successors. Held-worker owner exit is joined before successor
  cancellation. Early or stale deadline notices neither end nor renew the
  episode; a committed abort retains precedence. No provider or executor work
  is dispatched by these paths. Nonempty captured episodes remain at source
  preparation pending the next implementation step; this is not a completed
  standalone summarization workflow.
  The final nine-file selection passes 247 cases with two existing exclusions
  on the current pair in 15.2 seconds and floor pair in 14.8 seconds. The complete
  current Core suite passes 1,168 cases with eight existing exclusions in 214.4
  seconds. Production source is identical between those runs; the Core run
  loaded the test tree before the final held-worker owner-succession case was
  added, and that additional case passes in both final focused selections.
  Complete outputs are retained read-only outside the repository:

  | Retained output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-owner-focused-current-v3.log` | PASS, 247 cases, two excluded | `47b8eb58c151101d13c2da90b66189df4325ef4dc2497ed926c5386ff253cb6c` |
  | `/private/tmp/loopex-m7-standalone-owner-focused-floor-v2.log` | PASS, 247 cases, two excluded | `269c2b5debabee69e8a733c83a979f3ac6543716899a9a2ebd739a95446a0fa4` |
  | `/private/tmp/loopex-m7-standalone-owner-core-current-v1.log` | PASS, 1,168 cases, eight excluded | `5e864b0cc0cc69ca6be2762feb5d085159f5ef07e8d4cbc3da11d6a9019b6399` |

  Compilation without warnings, formatting, bootstrap/status, compiled
  documentation, dependency direction and version-train checks pass. Complete
  output `/private/tmp/loopex-m7-standalone-owner-static-v1.log`, SHA-256
  `40729f11a63668337ce279617e036e279bf2cb3642b463f310b9f959105a34a4`. This development log was produced before
  adding its own result/digest to this evidence entry; no source or test changes
  followed that run. Bootstrap/status and compiled documentation also pass
  after that backfill, complete output
  `/private/tmp/loopex-m7-standalone-owner-final-docs-v1.log`, SHA-256
  `46edfa3986660cc1f792a183e0967d9a1c524233ec1b5e1a22022b21fad05da8`.

  Development failures remain failures. Initial admission fixtures assumed the
  empty command stayed pending; an explicit scheduling hold now preserves their
  original unknown-commit, exact owner-exit and paused-successor proof, and adds
  cancellation/completed-result restart. A syntax error was repaired. A local
  TCP sandbox refusal supplied no test evidence; the authorized test run used
  escalation. New live fixtures initially used a mismatched context declaration,
  omitted runtime identity and attempted to resume a task from a process that
  did not own its suspension. Correcting those fixtures changed no product
  bound. A subsequent observation raced separate record/event reads; one atomic
  Store snapshot now supplies both. The initial joined selection also named two
  nonexistent files and exposed a real bounded-reader gap for unknown cleanup;
  the existing closed zero-attempt row now requires confirmed cleanup and null
  checkpoint. No required assertion, limit or check was dropped.

  | Failed output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-owner-current-v1.log` | FAIL, 71/74 cases | `20547ca74cd1d4f5dd91b95b4e4bf435224a6423c7130dd2fb00121e9b1f0b2b` |
  | `/private/tmp/loopex-m7-standalone-owner-current-v2.log` | FAIL, fixture syntax | `ce8524eddecd2fdbce6204a7c064c1ae36fd8f50d66d2d448f0c69a8afd05216` |
  | `/private/tmp/loopex-m7-standalone-owner-current-v3.log` | UNAVAILABLE, local TCP sandbox refusal | `e10cbee50e01b07ab2cf163c0fede103c5bb7cfbb8a51f2ee434856106979efb` |
  | `/private/tmp/loopex-m7-standalone-owner-live-v1.log` | FAIL, 0/11 cases, fixture construction/hold errors | `6e4c5367f83661ab4f281c23623804a52e53f14802e6de78c475e143b2a1b207` |
  | `/private/tmp/loopex-m7-standalone-owner-live-v2.log` | FAIL, 10/11 cases, observation race | `5badf912322d0ae4474400786843b0f43ab971ceca4b15c47388b92f84a08a34` |
  | `/private/tmp/loopex-m7-standalone-owner-focused-current-v1.log` | FAIL, 225/226 cases and two invalid paths | `da4e8b883a45abc4abed740b967abfb956be657b7241b281b0839c86d4c09f34` |

  Intermediate passing outputs are retained read-only as well:
  `standalone-owner-current-v4.log`, SHA-256
  `44e0db895fdff964fa40f466d27e98f43f6d19b1d8241ec7e15e02c48d4ce20b`,
  and `standalone-owner-current-v5.log`, SHA-256
  `b3cea7d3b4c62b149338fb9fc66012938d4eb1c92c5c2c7243c58b5561ff0341`,
  pass 74 and 79 cases respectively in 7.8 and 8.0 seconds;
  `standalone-owner-live-v3.log`, SHA-256
  `1a4fe971acef44113880af5b510d35740b1e1f6b85e71d27cdb8478b49a4780d`,
  and `standalone-owner-live-v4.log`, SHA-256
  `f393661e1a6a1a49de503a20d4b19ac6cdbc7ec9067244ad8d1388478edaaada`,
  pass 12 and 43 cases in 2.0 and 2.2 seconds;
  `standalone-owner-focused-current-v2.log`, SHA-256
  `50e76e9dc1925c897d6181d2c3b6df6366115ff7b0d676d6d01f3c9d254c82d8`,
  and `standalone-owner-focused-floor-v1.log`, SHA-256
  `1607529e0c4077b0a939204c558f2cdf4d06367f5834c78585fbe4c9bf86ef76`,
  pass 246 cases with two exclusions in 15.5 and 14.7 seconds. Each basename in
  this paragraph is under `/private/tmp/loopex-m7-`.
  These development checks do not replace the next clean integration candidate's
  full fast check, real-provider lanes or closure matrix. T01–T19 originals stay
  54 done / 119 todo / 6 retired; added counts are 203 done / 9 todo, including
  T07's 36 done / 1 todo. One added initial-owner subtask closes and one explicit
  integrated standalone source/dispatch/checkpoint workflow subtask is retained
  open. Both earlier maintainer decisions remain pending. Next join that live
  workflow using the retained compact identity, without inventing a run.

- Done: empty fitting standalone compact now has a replay-checked unchanged
  completion proposal. Its closed private `compact_command_completed_v1` row
  binds the actual command/episode identity, observed clock and ADR 0043's exact
  five-member result. Zero usage, null checkpoint/failure and confirmed cleanup
  commit with exactly one `context.compaction_finished` event; no episode,
  attempt, run, deadline or checkpoint is created. Completion clears the pending
  slot and retains the result beside the original command admission. Duplicate
  lookup returns that exact completed result before current-state checks, while
  the admission-disposition query retains the accepted admission fact. Replay
  remeasures the unchanged selection and rejects substituted/missing fields,
  identities, results, duplicate completion, nonempty raw history and missing
  public completion. Abort, an admitted episode, invalid clocks and every
  cancellable measurement/final proposal check prevent unchanged completion.
  The bounded private reader validates the native closed result and zero usage,
  advances one-record coverage without effects and rejects malformed rows.
  This implements the accepted completed-result path as a pure owner proposal;
  live owner scheduling/Store uncertainty, completion snapshots, no-episode
  failed/cancelled results and admitted-episode endings remain open.
  Seven-file focused checks pass 179 cases with two existing exclusions on the
  current pair in 8.8 seconds and floor pair in 8.2 seconds. Complete outputs:
  `/private/tmp/loopex-m7-standalone-completion-current-v2.log`, SHA-256
  `7e2ab671f1026bf545d1740fd32425650b7a2a2dc3860a59a0285c54ffe5c7eb`;
  `/private/tmp/loopex-m7-standalone-completion-floor-v1.log`, SHA-256
  `86674818d102bfded2ee81335b381522d4cfc0ab60570b486c21e0dadd0ac429`.
  The complete current Core suite passes 1,144 cases with eight existing
  exclusions in 211.4 seconds; complete output
  `/private/tmp/loopex-m7-standalone-completion-core-current.log`, SHA-256
  `194944e12bbdc807349372c946c74c40e8c4ca5c346d5cb9c3045d1b03829e7c`.
  Initial static checks pass, complete output
  `/private/tmp/loopex-m7-standalone-completion-static.log`, SHA-256
  `9fe651f497624d3b5dd8be22a0dfdba23087c02d768c3af9faab12535a65c0f4`.
  Review then aligned the two delegating facade specifications and public
  command documentation with the accepted completed-result return; their
  function bodies stayed unchanged. Compilation, formatting, bootstrap,
  documentation, dependency direction and version-train checks pass on that
  final metadata, complete output
  `/private/tmp/loopex-m7-standalone-completion-static-v2.log`, SHA-256
  `9a45103e4233946631333c57280e628af5b601d7aa333e6368b8bba164cbc9a0`.
  The plan's stale fixed-core-instruction progress statement now describes its
  existing captured-host implementation and remaining helper/fallback work.
  These development checks do not replace the exact-candidate fast check or
  closure matrix.
  The initial two-file selection failed one new fixture that attempted to create
  an already-invalid instruction/system-ceiling configuration, 28/29 passed;
  `/private/tmp/loopex-m7-standalone-completion-current-v1.log`, SHA-256
  `0ae47099ad8a93516d5d3ceeb4bb5c11547890eccc149749bc9b133bbb4ad03c`.
  The fixture now asserts the existing configuration rejection instead of
  constructing unreachable durable state; no configuration limit or product
  assertion was weakened. That failed output remains failed.
  One added T07 result/replay subtask closes: T01–T19 originals stay
  54 done / 119 todo / 6 retired; added counts become 202 done / 8 todo, T07
  added 35 done / 0 todo. Both maintainer decisions remain pending. No original
  complete-workflow item closes from this preparatory result path.

- Done: the standalone episode admission constructor now freezes the accepted
  compact command's explicit bounds, current ordinary configuration version,
  normalized summarizer/instruction capture, measured trigger and last original
  rendering offender. Its private `standalone_maintenance_episode_admitted_v1`
  row has command/episode identity, explicit origin, null targets, admission time,
  one absolute deadline, zero attempts/usage, initial summary ordinal and null
  checkpoint. It has no run, staging-turn or preparation-deadline fields. The
  owning journal stamp supplies the captured session version. This implements
  ADR 0043's accepted standalone capture in the existing journal/episode state;
  it creates no new public contract or authority path. Full replay reproduces
  the exact row from the preceding command/configuration/history and validates
  the captured settings against that parent. A retained episode returns before
  any changed host setting, clock or measurement callback is consulted.
  Both declared bound endpoints, including a one-token spending declaration,
  remain valid captures; the separately pending reply-reserve failure decision
  is not implemented here. Empty fitting history returns an unchanged plan with
  no capture or summarizer lookup. Invalid/overflowed admission clocks return
  the accepted preparation cause before any traversal. Cancellation stops new
  admission before commitment. Command result, invalid-clock completion and
  automatic owner execution of this constructor remain open.
  Bounded private-history coverage validates the closed row locally, advances
  one-record pages without effect rows, and refuses malformed captures. Real
  terminal tool-history provenance proves the canonical-rendering capture;
  ordinary hard overflow captures its higher-priority trigger. Current-format
  replay, owner succession and rehashed parent-limit substitutions are covered.
  The final seven-file selection passes 174 cases with two existing exclusions
  on the current pair in 8.9 seconds and on the floor pair in 8.2 seconds.
  Complete outputs `/private/tmp/loopex-m7-standalone-capture-current-v3.log`,
  SHA-256 `f5a38a4380bd3473db96fb895bdef83151199e1e8dfcdecd7b310e026181eb3c`;
  `/private/tmp/loopex-m7-standalone-capture-floor-v1.log`, SHA-256
  `0b18ef6c0bc94f6ce413696bc4ff80b745a02ed9a9df68a9eb11e342b6c357ae`.
  The complete current Core suite passes 1,139 cases with eight existing
  exclusions in 212.3 seconds; complete output
  `/private/tmp/loopex-m7-standalone-capture-core-current.log`, SHA-256
  `863929dcbb5fb181cac03b8376ca89581f6919cf2aa3f64e67952376cf4d7f1b`.
  Warning-free compilation, formatting, bootstrap, documentation, dependency
  direction and version-train checks pass; complete output
  `/private/tmp/loopex-m7-standalone-capture-static.log`, SHA-256
  `e190bea4e3070e25a9c2299cf47d6c13d1fad89dba4a750032784506edcc0cf7`.
  These development checks do not replace the exact-candidate fast check or
  closure matrix. The initial admission selection passed 31 tests in 0.7 seconds,
  `/private/tmp/loopex-m7-standalone-capture-current-v1.log`, SHA-256
  `79fa6a4e3d01c87a0c8c8fe7793da1321cf77c633281e641ce70cda0e1b68249`.
  The next selection failed one new query fixture which omitted required prompt
  bounds, 66/67 passed, `/private/tmp/loopex-m7-standalone-capture-current-v2.log`,
  SHA-256 `2cbab21b96b97ec5941e49e1a1e515ef92d10bb4704864f70751313796002ef6`.
  Supplying that fixture's existing explicit run bounds repaired its construction;
  no product bound or assertion was softened. The failed output remains failed.
  Original T01–T19 counts stay 54 done / 119 todo / 6 retired. One added T07
  admission/replay subtask closes, making added counts 201 done / 8 todo and T07
  added 34 done / 0 todo. Both maintainer decisions remain pending. Live owner
  admission with Store uncertainty, source dispatch/spending, checkpoint/result/
  snapshot and abort/quiescence cleanup still require standalone integration;
  no original complete-workflow item closes.

- Done: standalone compact now measures its exact whole-session canonical
  context and selects all eligible terminal units through the shared hard-limit
  preflight. The transient seven-member Store sizing view binds the accepted
  command, derived episode and current configuration to the actual request,
  receipt and lineage projection; it has no invented run/turn/operation identity
  and is rejected by journal recovery. Its byte cost is the exact deterministic
  ETF fixed point. Numeric refusals retain the existing closed v2 schema and
  precedence; structurally inadmissible candidates keep unresolved byte cost
  zero rather than inventing a size. No thinking headroom, continuation or
  fresh optional intake enters this standalone probe. Tail selection preserves
  the prior checkpoint, releases fitting terminal history for explicit origin,
  distinguishes hard overflow from rendering-only repair, and pins the last
  original offending assistant source. Whole-tail and minimum-tail interruption
  checks precede any selection result. Source records, usage, clocks and episodes
  remain unchanged; this is preflight, not live capture or execution.
  The final seven-file selection passes 174 cases on the current pair in
  8.7 seconds and on the floor pair in 8.6 seconds. Retained complete outputs:
  `/private/tmp/loopex-m7-standalone-preflight-current-v5.log`, SHA-256
  `4508cacba56c080d4ed26d3409dec9bf9f3c6300ee9cc5b14dea2c6d26e0b244`;
  `/private/tmp/loopex-m7-standalone-preflight-floor-v3.log`, SHA-256
  `4d35f4c18cb107eac6c5aca49f1348023b2116898319cdc52158acb5f3763580`.
  The complete current Core suite passes 1,133 tests with eight existing
  exclusions in 213.2 seconds, complete output
  `/private/tmp/loopex-m7-standalone-preflight-core-current.log`, SHA-256
  `2f80f992b3314be97328a684c72a733914aa862398e4f913801f00b8ccd67864`. Warning-free compilation, formatting,
  bootstrap/status, documentation ordering and dependency/version gates pass,
  complete output `/private/tmp/loopex-m7-standalone-preflight-static.log`, SHA-256
  `bfaa3e3722037de06da9b856b3e0a3c786be5336678b3ab8d80361411546ab87`.
  These focused results do not replace the exact-candidate fast check or closure
  matrix. Earlier development outputs remain separately retained below.
  Original T01–T19 counts stay 54 done / 119 todo / 6 retired. This closes one
  added T07 preflight subtask, making added counts 200 done / 8 todo and T07
  added 33 done / 0 todo. Both maintainer decisions remain pending. Durable
  standalone capture, source work, dispatch/spending, completion/snapshot and
  cleanup remain open; no original complete-workflow item closes.

  | Development output | Result | SHA-256 |
  | --- | --- | --- |
  | `/private/tmp/loopex-m7-standalone-preflight-current-v1.log` | Failed four new fixture assumptions; 74/78 passed | `52c77e17ab7db78c117f6e15817bd8f81d22b5c7e1ad700a07b523790d1cffc9` |
  | `/private/tmp/loopex-m7-standalone-preflight-current-v2.log` | Corrected focused probe selection; 78 passed, 3.2 seconds | `e36fafc9deee65099146534cddbe588e30f539c6daa5ccdde8aabb34b1569d6a` |
  | `/private/tmp/loopex-m7-standalone-preflight-current-v3.log` | Expanded probe selection; 139 passed, 8.9 seconds | `1691f80606303522da354044cf990add2b3f7c372293f3aae2438130e894133e` |
  | `/private/tmp/loopex-m7-standalone-preflight-floor-v1.log` | Same probe selection; 139 passed, 8.5 seconds | `0a0d82c65333e9d777ee98ac8055fb43c0773ae373f5ad8d0f0cf654818214f0` |
  | `/private/tmp/loopex-m7-standalone-preflight-current-v4.log` | Failed two new source-key expectations; 172/174 passed | `8ba30c8ae9e33c4d2a83a7ef9e0595819e462fdd701de61e5bc83e95e380aee5` |
  | `/private/tmp/loopex-m7-standalone-preflight-floor-v2.log` | Same two expectation failures; 172/174 passed | `9768165c4bf70437b64295af8e8ee144180e9f0aacbe378d0dd4679717a270c0` |

  The first fixtures underestimated the byte-overflow input, used invalid
  system/input ceiling combinations, and crossed the Model message ceiling
  before the intended Store-cardinality boundary. They now exercise actual
  oversized bytes, valid configuration and 1,024 messages plus a required tool
  descriptor yielding 1,025 receipt blocks. Later source expectations now name
  the existing `turn` member rather than `turn_number`. Production bounds and
  guarantees were unchanged by those fixture repairs. Failed outputs remain
  failed, separate from the final verification.

- Done: standalone compaction can read the whole committed session through the
  existing lineage, unit-selection and projection paths using a transient
  `:session` scope. No new run, prompt or source identity is created. Selection
  preserves original run order, complete tool/result groups, terminal input-only
  units and protected unfinished/native work. Projection substitutes the retained
  checkpoint while all original records, source bindings and raw facts remain
  readable. The shared canonical request/receipt builder now accepts a settled
  session probe with current committed configuration and a supplied absolute
  cutoff; it rejects a run identity, steer, fresh optional intake or unfinished
  work. Its receipt remains an unsized candidate until whole-record preflight;
  this does not claim exact record-byte admission or provider dispatch. Existing
  live tests prove native-prefix equality and changed current configuration
  across restart; real journal recovery proves complete original provenance.
  The six-file current selection passes 148 cases in 7.9 seconds, output
  `/private/tmp/loopex-m7-standalone-scope-current-v4.log`, SHA-256
  `0142cad80a0687cc25686830c69a67eb9e5ed0c81358f9338f7f69ae67ee89ad`.
  The final floor selection adds the current-configuration probe assertions and
  passes the same 148 cases in 8.1 seconds, output
  `/private/tmp/loopex-m7-standalone-scope-floor-v3.log`, SHA-256
  `dd1d8f239395f9e97e0efcd57b43959bdde99a9ea03bad0fa959c167777573ac`.
  The complete current Core suite includes those final assertions and passes
  1,121 tests with eight existing exclusions in 215.2 seconds, output
  `/private/tmp/loopex-m7-standalone-scope-core-current.log`, SHA-256
  `ddb86ddce2d6e1cb21a2f4e1fb8c7826947fe6ca747f7ebda15a05e4c892f7a4`.
  Warning-free compilation, formatting, bootstrap/status, documentation ordering
  and dependency/version gates pass, output
  `/private/tmp/loopex-m7-standalone-scope-static.log`, SHA-256
  `a7be3c4c1e8e2a264c44fe4d0ce761e0d7ff836b272c386187369dea2c366ae9`.
  These development checks are not an exact-candidate full fast check or closure
  matrix; the last complete fast check remains the preceding `9ab1ede3` source.
  Its `mix cmd --app` wrapper printed CLI deprecation warnings; these are not
  compilation warnings or a static-gate result. The earlier current selection
  failed one new receipt assertion by treating required tool-definition
  descriptors as session-history descriptors, output
  `/private/tmp/loopex-m7-standalone-scope-current-v3.log`, SHA-256
  `0e699f22511e089d7d25b0a2ec4954fea1040d1dd74fe6c639e9f4a61357d9aa`.
  The corrected assertion separately proves the ordered session sources and
  the required definition count; the failed output remains failed. Original
  T01–T19 counts stay 54 done / 119 todo / 6 retired. Added counts become
  199 done / 8 todo; T07 added is 32 done / 0 todo. Both pending decisions
  remain unanswered. Standalone capture, whole-record measurement, execution,
  completion/snapshot and cleanup remain next; no original workflow row closes.

- Done: the clean integration commit
  `9ab1ede347484cc65f9f7a62678533eb66e43d1b` passes its one full current-pair
  fast check: all eleven application suites, 3,586 tests passed, 39 expected
  exclusions, 912 seconds. This includes the complete Core suite after the
  premature-expiry repair: 1,117 passed, eight excluded, 230 seconds. Complete
  immutable output `/private/tmp/loopex-m7-9ab1ede3-fast-check.log`, SHA-256
  `28c8d840f2d43d6348f0ae5ae2d098c7db1fd60ad3deea857ed329009a60f219`.
  Compilation, formatting, bootstrap/status, documentation, repository-command
  fixtures and dependency/version gates also pass. No full check will repeat
  for those bytes. This is integration evidence, not the floor/fresh-source/
  provider closure matrix. Original T01–T19 counts stay 54 done / 119 todo /
  6 retired; added counts stay 198 done / 8 todo. Both pending maintainer
  decisions remain unanswered. Standalone episode capture and execution are
  next; no whole standalone workflow row is closed by this integration check.
  The clean managed `m7-trace-check` worktree has been prepared at this tested
  commit for the next source phase. Its previous detached `07bfc363` commit is
  retained under `refs/loopex/checkpoints/m7-trace-check-07bfc363`; no prior
  committed work was discarded. There is no live check or agent remaining.

- Done: standalone compact command admission and replay now retain the closed
  explicit attempt/deadline/token declaration and command-derived episode ID
  without a clock, prompt, run, episode capture or provider dispatch. The owner
  bypasses ordinary run-bound resolution and command-clock sampling. Duplicate
  lookup precedes the fresh-input maintenance fence; abort binds to the pending
  compact identity and preserves the first cancellation. Replay rejects altered
  declarations, digests, identities, extra fields and ordinary accepted commands
  across the pending fence. The bounded private reader advances these neutral
  records without reporting an effect or completion. Live paused-owner cases
  resolve all three Store uncertainty phases exactly once, join predecessors,
  and preserve bounds/cancellation through public prepared succession. The
  seven-file selection passes 172 tests with two existing long-bound exclusions
  on both supported pairs after the separately recorded expiry repair below:
  current `/private/tmp/loopex-m7-compact-admission-current-v3.log`, 61.9 seconds,
  SHA-256 `33a0cd0ea334c2447dec3d33e5f4319b9b8129a5419f30e3d5e3b129edcaa84e`;
  floor `/private/tmp/loopex-m7-compact-admission-floor-v2.log`, 61.7 seconds,
  SHA-256 `e58e1978f2707ee99bd025d51a79b63af183314a0a30e4d6f51c60c45ace84ef`.
  The current command additionally named a nonexistent interaction-test path;
  Mix reported that unmatched path in other applications. Its actual Core
  selection and result are the seven files above, not policy-interaction proof.
  That separate complete suite is retained below. Episode configuration/clock
  capture, source work, dispatch, spending, checkpoint/completion, `last_compact`,
  abort cleanup and runtime quiescence remain required standalone integration.
  This closes one added T07 admission subtask, not an original whole-workflow row.
  Warning-free compilation, formatting, bootstrap/status, documentation ordering
  and dependency direction pass; complete output
  `/private/tmp/loopex-m7-compact-admission-static.log`, SHA-256
  `3d5ab936a878b4988863d393aa9b7ace855c778a1f4a77699046a9947f3d0c0f`.
  Next, retain one full fast check of the clean committed integration candidate;
  the preceding `1022eea7` result does not cover these new source bytes.

- Done: investigating a floor question-deadline failure exposed a reproducible
  premature-expiry defect. An early timer notification killed the owner with
  `interaction_resolution_failed / invalid_model_question_transition`. The
  handler now compares wall time to the retained cutoff and re-arms against that
  same instant when early. The existing live deadline test sends an early
  notification, proves the owner keeps the question pending, then requires its
  original real two-second expiry, exactly one settlement/ending, no second
  dispatch and current replay. No bound, observation timeout or assertion was
  weakened. Its red run is `/private/tmp/loopex-m7-question-early-timer-red.log`,
  SHA-256 `a92f04f469c16f8a7bbd863ac279197872ba37d97cea1c98dcbad95f930a7c5f`.
  The original floor selection remains failed evidence: 171 passed, one failed,
  two excluded, 64.2 seconds; `/private/tmp/loopex-m7-compact-admission-floor-final.log`,
  SHA-256 `a2af52ed7b16cab6de74c84db141a543435139737d3d037ab272bdde574ce758`.
  Its redacted log does not establish that exact original exit cause. Ten
  separate runtime-traced, owner-monitored diagnostic executions did not
  reproduce it and do not replace the failure:
  `/private/tmp/loopex-m7-question-deadline-diagnostic-floor.log`, SHA-256
  `76a87169aa9103c478ab08a05f48fbc033f189709d51952690a54a87f1918452`.
  The corrected-source focused selections above pass. Before this repair, the
  complete Core suite passed 1,117 tests, eight existing exclusions, in
  210.4 seconds: `/private/tmp/loopex-m7-compact-admission-core.log`, SHA-256
  `6ee323ee28364b88c3559be9753c5c3c495d72122b049ee970c5de2518d5006a`.
  That earlier run is not a whole-Core proof of the later expiry repair.
  The complete policy-interaction suite additionally passes 19 tests on each
  pair in 9.0 seconds: `/private/tmp/loopex-m7-compact-interactions-current.log`,
  SHA-256 `3e606e991476d6d3fa4eb6e6950d2aed12df72f58b63cb86c2ad66ce26d7ada7`;
  `/private/tmp/loopex-m7-compact-interactions-floor.log`, SHA-256
  `ece23343a54d264e5c5bfd8dc1748b99ce1825a6add8faf9473893f3eb9cb60f`.
  Original T01–T19 counts remain 54 done / 119 todo / 6 retired. After these
  added T07 and T16 subtasks, added counts are 198 done / 8 todo. T07 is
  original 2 done / 9 todo and added 31 done / 0 todo. The pending stalled-stderr
  scheduling cutoff and small maintenance reply-reserve decisions stay open.

- Done: retain the full fast check of clean implementation commit
  `1022eea77a626b27f6e4c2b3461f3fbe29d11bf0`. It passes every gate and all
  eleven application suites: 3,573 tests passed, 39 expected exclusions,
  925 seconds. Complete command output:
  `/private/tmp/loopex-m7-1022eea7-fast-check.log`, SHA-256
  `665149b7c20cfbd43cbe9b6184033c59ca3a46e3e707debc14276db1e0aead94`.
  This is one current-pair integration run, not the floor/fresh-source/provider
  closure matrix. The previous failed candidate remains failed. A pass here
  does not resolve the separately pending stalled-stderr fixture cutoff or
  small maintenance reply-reserve decisions.

- Done: audit and close original T07's open-exchange/native-prefix protection
  item. Conversation selection protects the complete unit when any source is
  frozen, including earlier terminal runs; unfinished/current units and open
  interactions also block release. Lineage projection returns each frozen
  message and source range unchanged even with zero remaining excerpt allowance.
  Maintenance admission rejects an open continuation exchange. Live configured
  cases retain exact source-bound native envelopes, tool excerpts, project and
  resource inputs across rounds, queued steer and owner restart. The new live
  headroom case spends the reserve under hard ceilings without changing its
  prefix or opening maintenance. The exact implementation's full fast check
  above covers the current-pair unit/projection/live cases. The final 207-case
  floor selection covers the live/replay cases; the additional complete
  Conversation/Lineage selection passes 43 tests on the floor in 0.2 seconds.
  Complete output `/private/tmp/loopex-m7-native-prefix-protection-floor.log`,
  SHA-256 `abeb8a705800124812136a2d631ac671cbc092292f49a9b21d383fbd1ccff13d`.
  No source change or weaker test was needed for this audit. Original T01–T19
  counts become 54 done / 119 todo / 6 retired; added counts stay 196 done /
  8 todo. T07 is original 2 done / 9 todo, added 30 done / 0 todo. Standalone
  compact, rendering-trigger capture, remaining preparation errors and real
  long-conversation proof remain open. No agent or test process remains active.

- Done: enforce the accepted `loopex.thinking_headroom.v1` targets throughout
  new ordinary-exchange staging, required/excerpt allocation, optional intake,
  ordinary tail measurement and checkpoint completion. Hard limits retain their
  first-failure precedence. Episodes capture the exact trigger and targets;
  replay derives them from retained run configuration and rejects missing or
  forged current fields. Ordinary hard-limit refusals keep null targets;
  headroom failures retain their target and hard ceiling. Open native exchanges
  use hard ceilings and keep their complete frozen prefix. Summarizer input
  and its 1,024-token reply reserve remain separate.
  Live tests prove initial headroom refusal without dispatch, target-aware
  optional project withholding, an open exchange spending above its initial
  target without compaction or re-rendering, and two summaries when the first
  checkpoint fits hard limits but still misses headroom. Request replay now
  independently repeats admission and verifies the exact receipt byte fixed
  point for both ordinary and resource-bearing records. Bounded private pages
  require the current episode target field and reject malformed generations.
  All 207 focused cases pass on each supported pair, with two existing
  long-bound cases excluded: current output
  `/private/tmp/loopex-m7-headroom-current-final-v3.log`, SHA-256
  `006d0df5032f3deebc301636ce03b950bd218e24f17afdc694a5c8d63b2db476`,
  14.7 seconds; floor output
  `/private/tmp/loopex-m7-headroom-floor-final-v3.log`, SHA-256
  `2d58d26f97b7b8bd28c1064834d612ce0205cacd90743c6dadf35f2a719d77c4`,
  14.1 seconds. A broader Core run before adding the last open-exchange witness
  passes 1,103 tests with eight long-bound exclusions; the final focused run
  includes that additional witness. Complete broader output
  `/private/tmp/loopex-m7-headroom-core-v2.log`, SHA-256
  `b5459e9403044eed282c29a5a2427d3bae7493ef44b3e0efb689c761ccaefd48`,
  212.4 seconds. Compilation, formatting, module documentation, status and whitespace
  checks pass. Earlier failed headroom logs remain diagnostic records, not
  passing evidence: the private reader had the previous key list, a matching
  receipt control needed its byte cost recomputed, and new fixture setups first
  used invalid mapping/system captures or exceeded the hard byte ceiling.
  This closes one added T07 subtask. Original T01–T19 counts remain 53 done /
  120 todo / 6 retired; added counts become 196 done / 8 todo. Rendering-trigger
  capture, remaining preparation errors, standalone compact, native-prefix
  protection audit and real long-conversation proof remain open. No full
  integration or closure matrix is claimed for this batch. The stderr fixture
  cutoff and small maintenance reply-reserve decision remain pending.

- Done: prove the captured live source cutoffs with held workers, without clock
  replacement or a shorter production deadline. Initial preparation waits its
  original 60,000-ms cutoff, joins the worker and commits the named preparation
  failure without inventing a run bound. Later preparation waits the committed
  run deadline and keeps its existing `deadline` bound outcome. Each preserves
  the exact checkpoint, raw facts and usage, commits one episode ending and
  performs no new provider or executor work. The two cases are tagged
  `long_bound` and selected by the existing release runner. Complete passing
  outputs: `/private/tmp/loopex-m7-source-worker-live-cutoff-current-v2.log`,
  SHA-256 `3c9944396526bbfff4b39628823af9915a0cc24938e97ddf864c3692e9399267`,
  125.8 seconds; `/private/tmp/loopex-m7-source-worker-live-cutoff-floor-v2.log`,
  SHA-256 `9d12d4de438e3ee028bb69ed11b012452dded4e9d8b8631ff823a12376e993a9`,
  125.3 seconds. The initial current/floor outputs without `-v2` remain failed
  records: the new assertion incorrectly used `deadline_ms` for the existing
  run terminal's `deadline` value. No production bound or check was weakened.

- Done: audit original T07's complete eligible-group selection item. Existing
  grouping, tail release, bounded source and original-record tests cover
  preceding same-run inputs, complete assistant/result groups in call order,
  terminal input-only runs, protected current/unfinished/frozen units,
  contiguous prefix selection, whole-unit excerpts and retained source binding.
  The owner derives eligibility from durable session state; malformed lineage
  refuses before source intent. Four focused files pass 97 tests on each pair.
  Complete outputs: `/private/tmp/loopex-m7-eligible-units-current.log`, SHA-256
  `6668670864d49bf75a72c86bb2861aada35a73449d125bbc203550891ad7a5ce`;
  `/private/tmp/loopex-m7-eligible-units-floor.log`, SHA-256
  `e488918d4cb58e7813381f3e06eae664cf65e07e03a5d38cb336b3e84dffdafd`.
  This closes one original T07 item and the live-cutoff work closes one added
  subtask. Original T01–T19 counts become 53 done / 120 todo / 6 retired;
  added counts become 195 done / 8 todo. The separate native-prefix protection
  obligation, thinking/rendering triggers, remaining preparation errors,
  standalone compact and real long-conversation proof remain open.

- Done: prove durable owner succession while an exact maintenance source worker
  is held before preparation. Both initial and post-checkpoint source phases
  join the worker and predecessor, leave only the new owner claim while paused,
  preserve the complete episode capture, checkpoints and charge, then dispatch
  one summary and ordinary continuation after activation. The summary carries
  the original prior checkpoint and selected model; changed startup model
  settings do not replace that capture. Each episode checkpoints once, retains
  original conversation facts and charges only its settled summary work.
  All 119 tests in the three focused maintenance files pass on both supported
  pairs. Complete outputs:
  `/private/tmp/loopex-m7-source-worker-succession-current-v2.log`, SHA-256
  `a9562def51bef13bde9ece5ed27850ce99ba2c196363885a2258e6d2385b6fb7`;
  `/private/tmp/loopex-m7-source-worker-succession-floor.log`, SHA-256
  `9f22bf0b0676772c3ea68ef3a359320d9a552dcb94e73054eac73791add3d90e`.
  This closes one added T07 subtask. Original T01–T19 counts remain
  52 done / 121 todo / 6 retired; added counts become 194 done / 8 todo.
  Live preparation cutoff and standalone compact remain open.

- Done: end a lost maintenance source worker through the existing unavailable
  `context_projection_invalid` refusal after its exact DOWN. The generic
  ordinary-history refusal constructor previously rejected this observation
  when retained history was valid, stopping the owner without an episode or
  parent ending. The owner now binds that observation to the eligible source
  phase and retained clock; replay rejects omitted, early and expired clocks
  and a stripped episode prefix. Both initial and post-checkpoint source phases
  pass all three Store uncertainty cases, once-only terminal recovery and held
  worker cancellation, preserving checkpoints, raw facts and usage without
  new provider or executor work. No record schema or public cause changes.
  The deterministic failing reproduction is retained at
  `/private/tmp/loopex-m7-maintenance-source-worker-red.log`, SHA-256
  `f827a2c9355600f801d493633dde0eb5dee2950a7e0431b2b9c6499735db9126`.
  The three focused files pass 117 tests on each supported pair. Complete
  outputs: `/private/tmp/loopex-m7-maintenance-source-fault-current-final.log`,
  SHA-256 `ab2208b10edf327cff44073708546a2137693aef0ca330e35ea4d7b6006f7e18`;
  `/private/tmp/loopex-m7-maintenance-source-fault-floor-final.log`, SHA-256
  `9ea04cf4e09e3bbb8bdc49d9eceae0266f6c9433540ce7e0b7f0caf1771df86b`.
  This closes one added T07 subtask. Original T01–T19 counts remain
  52 done / 121 todo / 6 retired; added counts become 193 done / 8 todo.
  Live preparation cutoff, supersession and standalone compact remain open.

- Done: close the CLI signal fixture's process-lifetime gap. Every normal and
  interrupted case now checks the exact launcher and child-VM PIDs after the
  wrapper's observed exit; a failing startup case checks the same joins. If an
  assertion stops before that observation, fixture teardown targets both
  captured PIDs and requires their exit, rather than relying on a later manual
  process sweep. All nine cases pass on both supported pairs, and the post-run
  task-owned process scan is empty. Complete outputs:
  `/private/tmp/loopex-m7-ask-os-signal-joins-current-final.log`, SHA-256
  `ff2f361ef8bb58aa6894b2a4a1c68dd82ae1dcf137124cc057bd3577dfef5c67`;
  `/private/tmp/loopex-m7-ask-os-signal-joins-floor-final.log`, SHA-256
  `85ec1794d24a4f8c68209612db591e57090bf81ec6c8cc9775a34052c9f65da1`.
  This closes one added T16 subtask; the original integration check remains
  open until the current candidate is verified.

- Done: pin the exact runtime `model_tool` question-event payload shape in a
  standalone, explicitly unserved schema. Live text, choice and decline paths
  assert pending and terminal fields, conditional choice identity, admitted
  answer, sequence and private-field absence; an expiry path asserts its null
  response fields. Three focused tests pass on both supported pairs. Complete
  outputs: `/private/tmp/loopex-m7-question-event-current-v3.log`, SHA-256
  `accb0ae67fea6d18ddfe0385107fdccd98ccc1ebfafbbd3ad0f6fed6098711f1`;
  `/private/tmp/loopex-m7-question-event-floor.log`, SHA-256
  `a7565c5dcc3967f5b42382bb2b7756036a72caa3d576a8cbc29c254b60d03602`.
  This closes one added T09 subtask. It does not prove the coordinated /3-/4
  wire codec, independent Node vectors or private pending/response decoders.

- Done: audit and close original T03's instruction-test obligation. Core's
  capture, refusal, source/receipt and replay tests pass 70 cases on both
  supported pairs; the CLI's exact file/environment byte limits, long workspace
  path, changed-file capture, admitted/declined resources, live chat staging and
  retained restart tests pass 59 on each pair. Complete outputs and SHA-256:
  `/private/tmp/loopex-m7-t03-core-current.log`
  `8a9e8b3de1181b3ae21598cca4e3da8d805015c7134376cae108678fc314b3ff`,
  `/private/tmp/loopex-m7-t03-core-floor.log`
  `75c89ffaed25cdf84029da9546a543534e9114d3b75f63d3d2a53ae59dd57515`,
  `/private/tmp/loopex-m7-t03-cli-current.log`
  `d618222fce3d95c676bbee8015ccf7c4961b670620d9667acb2bfdbde8c2b8ab`,
  `/private/tmp/loopex-m7-t03-cli-floor.log`
  `320934c1fe44f9f7624f255ecd974ae4956c1a8a95f9fc295b1b4e3633718c32`.
  Original T01–T19 count becomes 52 done / 121 todo / 6 retired. Separate
  helper-adapter authority and the pre-1.0 legacy instruction fallback cleanup
  remain open.

- Done: keep the provider-launcher interrupted-wait OS fault and terminal-Port
  observation concurrent under the original captured 2,100-ms cutoff. The
  previous sequential five-signal injector spent the same window doing `ps`,
  `kill` and short sleeps before the observer could receive Port exit/DOWN;
  the failed `e5f03ff8` run retained an already empty OS group with both Port
  facts absent. The corrected test still requires all five successful TERM
  attempts, an empty group, no false cleanup acknowledgement, nonzero exit and
  Port DOWN inside that same cutoff. All eight provider-launcher tests pass on
  both supported pairs. Complete outputs:
  `/private/tmp/loopex-m7-provider-launcher-observer-current.log`, SHA-256
  `2e5b193213541880eccb2d134f67bfc480737d550a6d121d404e2dbf2f3a7ec0`;
  `/private/tmp/loopex-m7-provider-launcher-observer-floor.log`, SHA-256
  `88250c97b911080488ef5d4d8418eb06f854fb51e6ab58e207297639117eaafe`.
  This closes one added T16 subtask without extending its proof bound.
  The next committed integration candidate still needs the fast check.

- Check result: the clean `1611006366e04e14c9b3cbd7204707d1e104c383`
  integration candidate ran `bash scripts/check.sh` once and failed only the
  CLI stalled-stderr trace fixture (`555/556` CLI tests; other application
  suites green). Complete output:
  `/private/tmp/loopex-m7-16110063-fast-check.log`, SHA-256
  `96ae3020a6fc086caa87a6ace8e4f8f4ace34ffeaa5bd299af6547a66b16f532`.
  The fixture's trace hook uses ExUnit's implicit 100-ms message wait for an
  asynchronous diagnostic writer, which turned a delayed writer under the
  parallel suite into `trace_start_failed`. A maintainer decision on a bounded
  fixture wait is pending; this failed run is not a pass or a retry.

- Done: remove the retired `model_question_response_admitted_v1` and
  `model_question_settled_v1` replay/effect-index readers. Current v2 answer,
  expiry and cancellation paths remain; the historical-record fixtures now
  assert refusal against otherwise current histories and events. Four question,
  interaction, configured-session and compaction-source files pass 65 tests on
  each supported pair. Complete outputs:
  `/private/tmp/loopex-m7-question-current-only-current.log`, SHA-256
  `ab059202b66b1e549a28b60ae4a9a272037eb7c1e7887f6a60994a7d22c89717`;
  `/private/tmp/loopex-m7-question-current-only-floor.log`, SHA-256
  `2e205c81240ae13bd6ada52caf196d0b6d50e815bc75d4008bab8fc15f08062c`.
  This closes one added T09 current-contract cleanup subtask. T01–T19
  originals stay 51 done / 122 todo / 6 retired; added subtasks become
  189 done / 9 todo. Including T00: originals 51 / 128 / 7 and added
  193 / 10. Pending/response decoder vectors, public question event schemas
  and complete public answer-path integration remain open.

- Done: turn the captured summarizer system-limit refusal into the accepted
  measured v2 `maintenance` scope before source traversal. Its single exact
  system descriptor supplies the count, estimate and ordered digest; replay
  recomputes those values from the frozen instruction capture. A live automatic
  overflow commits the episode/refusal/parent ending without source request,
  model dispatch or executor job. All 92 maintenance staging and recovery
  tests pass on both supported pairs. Complete outputs:
  `/private/tmp/loopex-m7-maintenance-system-current.log`, SHA-256
  `4ee442351711a60f512b5b7772459bc0792f717543699263a4c9575779aa37b7`;
  `/private/tmp/loopex-m7-maintenance-system-floor.log`, SHA-256
  `ac9dc607849a7685128d296127fc44cbfb9e14e7b1b95114087e65c97d3e3165`.
  This closes one added T07 subtask. T01–T19 originals stay 51 done /
  122 todo / 6 retired; added subtasks become 188 done / 9 todo. Including
  T00: originals 51 / 128 / 7 and added 192 / 10. Other source failures,
  worker-fault joins, thinking triggers and standalone compact remain open.

- Done: retain a measured numeric v2 refusal when a protected ordinary tail
  remains too large after a useful checkpoint or at an already-admitted first
  source boundary. The worker remeasures the exact protected candidate with
  frozen project/resource inputs and the derived first-request deadline;
  replay rederives its dimension, counts, digest, observation, episode and
  clock. Current/floor tests cover token and record-byte overflow, prior
  checkpoint retention, forged measurements and a live resumed owner that
  commits only the episode/refusal/parent ending. All 91 maintenance staging
  and recovery tests pass on each pair. Complete outputs:
  `/private/tmp/loopex-m7-source-numeric-live-current.log`, SHA-256
  `c0d96e4c0f688cab98e5fab9f457a640009413b7a6cc5af5719f8893433ce0da`;
  `/private/tmp/loopex-m7-source-numeric-live-floor.log`, SHA-256
  `b33030763509c14ed211bc1c7b7d0cd7468be9c63fcf0ac66228cfed78647b6e`.
  This closes one added T07 subtask. T01–T19 originals remain 51 done /
  122 todo / 6 retired; added subtasks become 187 done / 9 todo. Including
  T00: originals 51 / 128 / 7 and added 191 / 10. Other source-preparation
  errors, worker faults, thinking triggers and standalone compact remain open.

- Done: make a source selector's irreducible excerpt failure a durable
  `compaction_excerpt_budget_too_small` ending. The pure worker proposes the
  episode terminal, unavailable v2 refusal and failed parent terminal together;
  replay reselects the frozen source at the retained clock and rejects a
  different cause, episode identity or expired observation. A live automatic
  overflow proves no request, provider call or executor job was opened. Both
  supported pairs pass all 87 tests in the maintenance staging and recovery
  files. Complete outputs: `/private/tmp/loopex-m7-source-refusal-current.log`,
  SHA-256 `6beabc47c3735fdee6d0c4c7fef48b1e62ab1f94998a2426e568b2305516ff7f`;
  `/private/tmp/loopex-m7-source-refusal-floor.log`, SHA-256
  `49c070d7778f1aa9aeecc42e3a925b2fe292e0305e68c8be7998d1073dca06f2`.
  Initial unprivileged combined runs could not start Mix because its local TCP
  lock returned `:eperm`; the retained passing runs used the permitted test
  sandbox. Worker-fault joins and the other T07 outcomes remain open. This
  closes one added T07 subtask; T01–T19 originals
  stay 51 done / 122 todo / 6 retired and added subtasks become 186 done /
  9 todo. Including T00: originals 51 / 128 / 7 and added 190 / 10.

- Done: join measured ordinary token/record-byte overflow to live automatic
  episode admission. The owner checks whether the captured q=0 ordinary tail
  can release a complete older unit, then commits the frozen summarizer,
  instructions, parent spending and fixed preparation cutoff before its source
  worker. One recovered long-history run now stages a real summary, commits a
  checkpoint and continues the original prompt once. A missing summarizer
  commits a named v2 refusal and failed run without an episode or provider call;
  an irreducible current prompt keeps its measured numeric refusal. Current
  recovery verifies the three endings and no executor work. Missing host
  settings and admission-clock causes use the accepted closed v2 refusal union.

  This closes one added T07 automatic-trigger subtask. T01–T19 originals remain
  51 done / 122 todo / 6 retired; added subtasks become 185 done / 9 todo.
  Including T00: originals 51 / 128 / 7, added 189 / 10. Original T07 remains
  0 / 11 / 0. Thinking-headroom/rendering triggers, explicit and standalone
  compact, source-worker fault joins, all irreducible post-admission endings,
  public progress and real Store/provider proof remain open. The case where
  fewer than 1,024 run tokens remain has a concrete maintainer decision packet
  at `/private/tmp/loopex-m7-maintenance-reserve-decision.md`; the dependent
  public-contract amendment has not been implemented.

  The preceding `911f26c76216b082b4d0b5bd5d3c7494835b4aa7` candidate
  passed its exact-source full current-pair fast check in 1,417 reported seconds:
  complete `/private/tmp/loopex-m7-live-source-fast-check.log`, SHA-256
  `5257a6bf95cffd2a66b8eb39c2253ee6a2a4517fd6dc503c860ef06cb9392e5e`.
  The newer automatic-trigger bytes pass the 20-file focused selection on the
  current pair in 15.8 measured seconds, complete
  `/private/tmp/loopex-m7-live-source-current-v5.log`, SHA-256
  `eafc08ba4a32c1b2d0c71ad829f5f2bc4a6f8a803f81709b3bba07dd2dc5dd60`,
  and the floor pair in 17.7 measured seconds, complete
  `/private/tmp/loopex-m7-live-source-floor-v5.log`, SHA-256
  `2a5fd41371fb9bd59c4f9ee7ddb4b5d4ee3f570abbe21ae3dba6f34df44d84dc`.
  One later irreducible-trigger case brings the focused recovery file to 46
  passes on each pair; it does not change production bytes. Formatting,
  warning-free compile, dependency direction, bootstrap, docs and diff gates
  passed in 23.9 measured seconds before that final test/doc edit, complete
  `/private/tmp/loopex-m7-automatic-gates-v1.log`, SHA-256
  `8b158fbb342ae954e37263026fc475613b5cb7576b9b2a64df729fed1f943aac`.
  The same gates passed after the final test and plan update in 21.2 measured
  seconds: complete `/private/tmp/loopex-m7-automatic-gates-v2.log`, SHA-256
  `e77a01df077d3b20d3926e9fde2bccb49ad3aea258e711306595f3460a22fb1f`.
  The sandbox blocked two attempted 20-file runners before Mix started; their
  `:eperm` outputs are retained as `current-v4`, `floor-v4`, and `current-dev4`
  logs, and the successful v5 runs used local Mix TCP permission. No full fast
  check is claimed on the newer bytes.

- Done: join retained run-owned ordinary-limit source preparation and further
  prefixes to the live serial owner. A supervised worker selects the q=0 tail
  through the captured ordinary request/receipt constructor, streams bounded
  source-v2 candidates and returns a pure request/open proposal. The owner waits
  for that worker's exact DOWN, checks its cutoff and captured journal version,
  and commits the pair before adopting the new attempt. Intervening mutation
  discards prepared evidence for reselection; cancellation joins the effect-free
  worker. First preparation uses the retained preparation/run cutoff and later
  prefixes retain the committed run deadline.

  Provider dispatch now uses the exact retained maintenance request and its
  closed episode/ordinal/operation/attempt/digest binding through existing
  Control authority and provider cleanup. Captured thinking-off selection,
  instructions, 1,024-token output reserve, absent tools/continuation and prior
  checkpoint provenance survive changed launch defaults. Raw summary deltas
  create no ordinary answer stream. Inherited opens still settle owner loss;
  only newly adopted opens dispatch, and the existing exact not-dispatched
  retry uses the maintenance attempt reducer.

  Eight live cases cover first source preparation and a further raw prefix,
  each without a fault and through all three staging uncertainty phases. Known
  commits dispatch one summary then one ordinary continuation only after the
  prior provider callback exits, retaining one or two checkpoints and exact
  58/114 reported token charges. Prepared recovery remains paused. An unresolved
  commit joins the exact fenced owner, dispatches nothing, then a successor
  settles the inherited attempt conservatively without another call; useful
  prior checkpoints and raw facts remain. No executor job appears. Empty
  in-flight work/streams and owner-worker children plus coordinator/control
  joins complete every case. These tests use the fault Store fixture; real
  persistent Store/provider witnesses remain open.

  This closes one added T07 live-integration subtask. T01–T19 originals remain
  51 done / 122 todo / 6 retired; added totals become 184 done / 9 todo.
  Including T00: originals 51 / 128 / 7, added 188 / 10. Automatic trigger
  admission, explicit/standalone compact, irreducible source/refusal endings,
  source-worker cutoff/cancellation/owner-loss fault proof, public compaction
  progress and real-provider workflows remain open. Unsupported preparation
  results currently stop the owner without inventing a retained ending; they
  require the accepted measured or named refusal paths before T07 closes.

  Final twenty-file selection: 293 Core tests and seven composition tests pass
  on each pair; one existing Core long-bound exclusion remains. Current:
  16.7 measured seconds, `/private/tmp/loopex-m7-live-source-current-dev3.log`,
  SHA-256 `9bfb20b83570bfb5fcbbadcabe9c50969e0559fa2edf9670d363d934a2d9a7cc`.
  Floor: 16.1 measured seconds, `/private/tmp/loopex-m7-live-source-floor-v3.log`,
  SHA-256 `0037134860f60f01cde72c976f6430428f96d3495d37f7c640e8a9f8d9d8bf3b`.
  Failed development outputs remain: current
  `/private/tmp/loopex-m7-live-source-current-dev1.log`, SHA-256
  `2c055211fd45b917aeb186f7857b6a75cd16876a7b36881dc986ba2f0f8b6d47`;
  floor `/private/tmp/loopex-m7-live-source-floor-v1.log`, SHA-256
  `27f2fc1622369a859cf8b8174a7b3ba43cac097dc72caa0f6f4169638309791a`.
  Fixtures now assert the actual source-v2 version and use the captured ordinary
  ceiling for each old prompt; production validation and bounds were unchanged.
  The two successful live paths then passed before additional uncertainty cases:
  current `/private/tmp/loopex-m7-live-source-current-dev2.log`, SHA-256
  `5e04d4b159b3b5f3c8176de1fc19a49a18f5477a4bc0c8b7488739a8ccfe13f7`;
  floor `/private/tmp/loopex-m7-live-source-floor-v2.log`, SHA-256
  `51a100f2dd009c5d4db31d9833a53820f2d37729fef98aa41fb29f90568419d4`.
  Final focused handles 46693 and 57827 are terminal and collected. No decision
  or agent is pending. The next integration candidate needs its full fast check;
  no full check has run on this source yet.

  Formatting, warning-free compilation, dependency direction, bootstrap/status,
  documentation and diff gates passed in 24.6 measured seconds:
  `/private/tmp/loopex-m7-live-source-gates-v1.log`, SHA-256
  `ec2b0449911426bf2e039c02e85b53b1a74bc5203e41404475eef41bef8c73b7`.
  Gate handle 54876 is terminal and collected. The full integration check of
  this committed candidate will run once in the clean attached verification
  checkout, retaining exact SHA and streamed output in
  `/private/tmp/loopex-m7-live-source-fast-check.log`; that file's terminal result
  and digest, rather than this launch intention, determine its evidence status.

- Done: prove live exhausted-episode recovery through before-linearization,
  after-linearization-before-result and recovery-representation Store faults.
  The fixture uses public exact genesis, stops the initial owner and commits
  four physical attempts (including one exact not-dispatched retry), three
  useful checkpoints and 168 reported tokens through the Store boundary.
  Prepared resume appends only owner succession and remains paused. Activation
  commits one adjacent episode/refusal/parent ending; unresolved uncertainty
  joins the exact fenced owner before a new owner resolves it. No summary,
  ordinary request, executor job or further checkpoint is dispatched. Replay
  retains all original facts, all three checkpoints, the active checkpoint and
  once-only usage. Coordinator/control joins complete every case. The shared
  live-ending fixture also preserves all prior non-progress fault assertions.
  This extends the completed T07 exhaustion subtask; no tally changes. New
  source preparation/summary dispatch, automatic and explicit workflows, and
  real persistent Store/provider checkpoint faults remain open.

  Final twenty-file selection: 285 Core tests and seven composition tests pass
  on each supported pair; one existing Core long-bound exclusion remains.
  Current: 14.9 measured seconds,
  `/private/tmp/loopex-m7-exhaustion-current-dev4.log`, SHA-256
  `596621a00f8b0da46fdaee043535a53a00f9b0aa8f87b64d2507be4bf6541829`.
  Floor: 14.2 measured seconds,
  `/private/tmp/loopex-m7-exhaustion-floor-v3.log`, SHA-256
  `087b67cf3638a680867999516dc8a563d01a9fcf6c2ed1b6061f53b89fedb988`.
  Intermediate case-level runs passed before fixture consolidation: current
  `/private/tmp/loopex-m7-exhaustion-current-dev3.log`, SHA-256
  `e949518d54f835cd9500ae9ecfe274de7daae94266c982be64ba81e4ef7889a1`;
  floor `/private/tmp/loopex-m7-exhaustion-floor-v2.log`, SHA-256
  `27bb3b1211f54baede7837731d0bac75ea8951226e9e9353cc294a0c6823b8b6`.
  Final focused handles 18232 and 28609 are terminal and collected; no agent
  or maintainer decision is pending. T01–T19 remain original 51 done / 122 todo /
  6 retired, added 183 done / 9 todo. Including T00: original 51 / 128 / 7 and
  added 187 / 10. These fault-injection fixtures do not replace real persistent
  Store or provider release witnesses.

  Formatting, warning-free compilation, dependency direction, bootstrap/status,
  documentation and diff gates passed in 21.0 measured seconds:
  `/private/tmp/loopex-m7-exhaustion-live-gates-v1.log`, SHA-256
  `5c4fb58929f9252c44d815fc8be156679ae979813b0ee7f80ac2ec757689f3d1`.
  Gate handle 15415 is terminal and collected. Next join source selection and
  request preparation in a supervised worker that returns evidence to the
  serial owner, then commit the exact request/open pair before a newly adopted
  maintenance attempt uses the existing Control permit and provider cleanup.
  Current provider dispatch still reads ordinary work request/binding/progress
  fields; it needs the retained maintenance request and operation identity.
  Inherited open attempts continue to settle owner loss without redispatch.
  Worker cancellation must join before abort/deadline/owner-loss disposition;
  stale prepared evidence must not replace current journal truth.

- Done: add the run-owned exhausted-episode reducer for four physical
  maintenance attempts whose current partial checkpoint still fails ordinary
  limits. It recomputes the last minimum ordinary candidate and retains the
  exact numeric refusal between episode and failed parent terminals in one
  proposal, preserving the useful checkpoint, original facts and once-only
  168-token charge. Four attempts remain episode evidence rather than an
  invented parent attempt bound. Abort and deadline win before measurement.
  Replay rejects altered estimates, descriptor counts, digests and clocks. It
  also rejects removal of the episode identity: ordinary numeric refusals now
  require no active maintenance, so they cannot bypass episode recomputation.
  The coordinator joins the existing fenced ending path; live exhaustion fault
  injection, further summary dispatch and automatic/explicit workflows remain
  open. This closes one added reducer subtask only. T01–T19 originals remain
  51 done / 122 todo / 6 retired; added totals become 183 done / 9 todo.
  Including T00, originals remain 51 / 128 / 7 and added totals are 187 / 10.

  Twenty-file focused selection: 282 Core tests and seven composition tests
  pass on each supported pair; one existing Core long-bound exclusion remains.
  Current: 17.4 measured seconds,
  `/private/tmp/loopex-m7-exhaustion-current-dev2.log`, SHA-256
  `c6c78abfc3a2f1a41517d29aac1a924548cf0111c9571868f994a4e4910f5886`.
  Floor: 18.3 measured seconds,
  `/private/tmp/loopex-m7-exhaustion-floor-v1.log`, SHA-256
  `a0e23cd8735a8712a4a00fe0186bbdc082aff98d626617c44226aaf0a54746e9`.
  The failed current development output is retained:
  `/private/tmp/loopex-m7-exhaustion-current-dev1.log`, SHA-256
  `7229236f33aa29985a4c66224f8e87415cb7b71ac984aa6eb5b88625b74dfc7f`.
  Its episode-identity mutation exposed the bypass above; the validator was
  strengthened without weakening the test. Focused handles 6896 and 57970 are
  terminal and collected. No question, decision or agent is pending.

  Formatting, warning-free compilation, dependency direction, bootstrap/status,
  documentation and diff gates passed in 23.9 measured seconds:
  `/private/tmp/loopex-m7-exhaustion-gates-v1.log`, SHA-256
  `81a48edc0ffa2bfba65ccd46a571e5a024a0b309ae3668d0a97505e4da00741f`.
  Gate handle 33318 is terminal and collected. Next verify the live exhausted
  successor across all three Store uncertainty phases, then join bounded source
  preparation and new summary dispatch/cleanup to the serial owner.

- Done: extend the run-owned ordinary-limit reducer and private history reader
  across further raw prefixes. Each next request includes the exact prior
  checkpoint, derives a new summary ordinal and operation identity, retains the
  captured configuration and committed deadline, and opens only after the current
  substitution still fails ordinary fit. Full coverage is recomputed from original
  journal records; the prior first-kept identity begins the new contiguous raw
  cut. The checkpoint retains separate cumulative and consumed ranges, one
  rendered summary, inherited excerpt flags and every remaining raw fact.
  Natural settlements charge once. A later growing summary ends non-progress
  while retaining the useful prior checkpoint. Physical retries count toward the
  four-attempt episode ceiling; cancellation, deadline and parent capacity remain
  ahead of preparation. Fitted checkpoints cannot start summary-only cycles.

  Private pages traverse two checkpoints without owner activation or effects,
  rejecting self-cycles and enlarged/newly empty consumed cuts. This closes one
  added T07 subtask. Originals remain 51 / 128 / 7 including T00; added totals
  become 186 done / 10 todo, or 182 / 9 for T01–T19. Live next-prefix dispatch,
  durable exhausted-episode endings, thinking/rendering triggers, explicit and
  standalone compact, and real-Store/provider checkpoint proof remain open.

  Final twenty-file selection: 282 Core tests and seven composition tests pass
  on each pair; one existing Core long-bound exclusion remains. Current:
  17.8 measured seconds,
  `/private/tmp/loopex-m7-next-prefix-current-dev5.log`, SHA-256
  `b9963eb4a37c1c0bad40dd9dc08f585b106ced37a6e49f6dbcc94c10bc6bb6a9`.
  Floor: 18.2 measured seconds,
  `/private/tmp/loopex-m7-next-prefix-floor-v3.log`, SHA-256
  `6ad702b0ae69acfca745025369cdb54bfaa8c6676ae147b788e4002a22f65acb`.
  Failed development outputs remain: current dev1
  `/private/tmp/loopex-m7-next-prefix-current-dev1.log`, SHA-256
  `469ac88c9ea294dc23e2dae91e8f6172a7b4905a11c700e9b0abe9cc70ab8daf`;
  current dev3 `/private/tmp/loopex-m7-next-prefix-current-dev3.log`, SHA-256
  `a475dc731193d3e1e3595138fff20454c77aae3b9da9ea624237ad5aa16eac5e`;
  floor v1 `/private/tmp/loopex-m7-next-prefix-floor-v1.log`, SHA-256
  `07a20a8f04b56ee560839d8520156dc2495fda90dc1ec0ff582e45f28e1af35b`.
  Fixtures now capture a valid system/input ceiling and an actually refusing
  ordinary candidate, and use the existing private-history cursor API. No
  validator, deadline, retry or required proof was relaxed.

  Formatting, warning-free compilation, dependency direction, bootstrap/status,
  documentation and diff checks passed in 23.7 measured seconds:
  `/private/tmp/loopex-m7-next-prefix-gates-v1.log`, SHA-256
  `a3158afe9fa19310d66896dd0916e4c6a009dbbd7e997572db3011de60ae2d0f`.

  The full fast check failed on exact
  `e161bd57e118839744308e898c69355d819fb118` in 1,421.0 measured seconds.
  All preliminary gates and ten application suites passed, including 1,058 Core
  tests. Composition passed 476 of 479 tests, with one exclusion; three cases
  failed because two fixture assertions still read the removed cutover cache.
  Those missed callers now assert actual closed projection records from the
  first request onward. All seven artifact-range session cases pass on both
  pairs above, including real local Store restart and empty-registry recovery.
  This extends T15's existing cleanup subtask without changing its tally.
  Complete full-check output:
  `/private/tmp/loopex-m7-e161bd57-fast-check.log`, SHA-256
  `7ec0a29a02e367724acecd268e8cc8124a81bfba314adf7418c142246aac00a8`.
  Execution handle 81549 is terminal and collected; never poll it or rerun this
  failed candidate as a pass. No decision is pending.

  Next integration work is a durable measured ending when four physical
  maintenance attempts leave ordinary limits unmet, retaining partial checkpoints
  and parent precedence. Then join bounded source preparation and new summary
  dispatch/cleanup to the live serial owner. The current coordinator still stops
  on a partial checkpoint requiring another prefix; pure proposal/reader proof
  is not a live automatic or explicit workflow claim.

- Done: remove the superseded lineage-projection cutover cache and historical
  inline staging fallback. Replay now asks the captured current lineage
  constructor whether a projection is required. Artifact-capable sessions retain
  exact provenance from their first request; sessions without that capability
  retain their current null projection. The formerly failing fixture proves
  unchanged current replay and refuses null, missing first, missing later and
  wholly removed projection metadata after exact record-cost repair. This applies
  the accepted pre-1.0 current-contract disposition; it removes no current restart,
  source-binding, accounting or cleanup obligation.

  Nineteen-file current artifact, projection, maintenance and accounting
  selection: 277 passed and one existing long-bound exclusion on each pair.
  Current: 14.6 measured seconds,
  `/private/tmp/loopex-m7-projection-current-current-dev1.log`, SHA-256
  `6755c67f1d02d7b0e2ea696bef5f6bdcdc73fb30918a6b5c718aaa541a03707f`.
  Floor: 15.3 measured seconds,
  `/private/tmp/loopex-m7-projection-current-floor-v1.log`, SHA-256
  `f1fb6341d7ec7017ccf3eb6b84baa509e84a8849c35da5d87c5be7db4724f36c`.
  One added T15 subtask closes. Originals remain 51 / 128 / 7 including T00;
  added totals become 185 done / 10 todo, or 181 / 9 for T01–T19. Superseded
  genesis/API/protocol/host fallback cleanup and current backup/restore remain
  open. The failed full check of 4e4778a2 remains failed evidence; these are
  focused proofs on the changed source, not a rerun of that candidate.

  Formatting, warning-free compilation, dependency direction, bootstrap/status,
  documentation and diff checks passed in 26.4 measured seconds:
  `/private/tmp/loopex-m7-projection-current-gates-v1.log`, SHA-256
  `c85b7734b796b31193a39ad27004bedb0cde9c28ba56bac2aa7f8c653f683080`.

- Done: commit and recover a measured `compaction_no_progress` ending for a
  valid settled summary that fails strict byte/token progress. The last minimum
  ordinary candidate supplies exact descriptor counts, token estimate and digest;
  the nonnumeric refusal has null record cost and no invented budget observation.
  One transaction retains episode terminal, refusal and failed parent terminal.
  Replay recomputes the failed substitution, rejects altered measurements and
  missing/reordered rows, and preserves raw facts and the single 56-token charge.
  Abort, elapsed deadline and spent parent bounds win before measurement. Live
  prepared recovery remains paused until activation; all three Store uncertainty
  phases settle once without another summary, ordinary call, checkpoint or
  compaction event. The private reader traverses every row without owning the
  session. This closes one added T07 subtask; originals remain 51 / 128 / 7
  including T00. Added totals are 184 done / 10 todo, or 180 / 9 for T01–T19.

  Final sixteen-file selection: 245 tests on each supported pair. Current:
  11.0 measured seconds,
  `/private/tmp/loopex-m7-nonprogress-current-dev3.log`, SHA-256
  `f9f8a32bc2c74ccfbab0a62f53f2ab942dffe3d0abc145e25ff5f8e1e7378449`.
  Floor: 10.7 measured seconds,
  `/private/tmp/loopex-m7-nonprogress-floor-v2.log`, SHA-256
  `947f03e4273355fcb9d2384ae5c74bfc24d2cd57e0174dcdce4a4fd688d20c6a`.
  Development failures are retained: current dev1
  `/private/tmp/loopex-m7-nonprogress-current-dev1.log`, SHA-256
  `013f71471af6738a41bbd2d888623a6d9b4ba13fc3ef08f839678812f7733d2e`;
  current dev2 `/private/tmp/loopex-m7-nonprogress-current-dev2.log`, SHA-256
  `15ae5c26e6062ab7da65f6988255cc63131e0f848502e18f3cc1c8a4b6f62e4e`;
  floor v1 `/private/tmp/loopex-m7-nonprogress-floor-v1.log`, SHA-256
  `33153f8e8374236031eb4091e0681d11614c8c4fc41acf5c956b30619eb30713`.
  Fixture expectations now include the existing session-settled event and exact
  owner-succession rows while proving terminal adjacency and uniqueness. No
  production validator, deadline, retry or required proof was weakened.

  Formatting, warning-free compilation, dependency direction, bootstrap/status,
  documentation and diff gates passed in 24.5 measured seconds:
  `/private/tmp/loopex-m7-nonprogress-gates-v1.log`, SHA-256
  `97cf9982658b529e580a35afb3c887ffeb52c661d5cca9218ab3940d52a972b6`.

- Integration check failed on exact
  `4e4778a2e7b35e1e9f7f37c36f5060cb5fafd09c`. All preliminary gates and ten
  application suites passed; Core passed 1,050 of 1,051 tests, with six exclusions.
  The remaining artifact-history fixture expects a removed first-request
  projection to remain readable under a historical cutover. Current projection
  reconstruction refuses it. The pre-1.0 disposition removes this compatibility
  obligation; preserve positive current replay and malformed/missing provenance
  refusal, then remove the superseded cutover state under T15. This check is
  failed evidence and will not be repeated on the same bytes.
  Complete output, 1,401.0 measured seconds:
  `/private/tmp/loopex-m7-4e4778a2-fast-check.log`, SHA-256
  `08349011c80e59b57ec35db8ae100e564b797f45e8a3ea3171bc58af3f55bc96`.
  Execution handle 72292 is terminal and collected; do not poll it.

- Done: join the live successor to settled first-checkpoint commitment and
  fitted episode completion through the existing owner fence and uncertainty
  resolver. Prepared resume remains paused until activation. Six Store-fault
  cases cover pending/committed checkpoints across all three uncertainty phases;
  an unresolved owner is joined before succession, and no ordinary request is
  dispatched while it remains fenced. Recovery retains one summary attempt,
  settlement, checkpoint and event, then dispatches one ordinary request using
  captured configuration and exact summary provenance. Usage charges 56 summary
  tokens once and 2 ordinary tokens once. Abort, deadline and spent token/turn
  bounds prevent new checkpoints or dispatch; previously committed checkpoints
  survive cancellation and expiry. Exact coordinator/control joins finish each
  live case. The private reader now admits the existing run-owned parent turn
  result, while standalone compact keeps its separate attempt-bound vocabulary.
  Later-prefix continuation, measured non-progress endings, automatic triggering,
  new summary dispatch and standalone compact remain open. This extends the
  completed T07 checkpoint subtask without changing either tally.

  Final sixteen-file selection: 238 tests on each supported pair. Current:
  10.7 measured runner seconds,
  `/private/tmp/loopex-m7-checkpoint-recovery-current-dev5.log`, SHA-256
  `4824ef812b786e006b2a7cd24c42b1248b1c1168bf83f9d3a1d3173211914e3b`.
  Floor: 10.3 measured runner seconds,
  `/private/tmp/loopex-m7-checkpoint-recovery-floor-v2.log`, SHA-256
  `aae77faa465cb7b94afb710716df8b702739c4eb1316f13b7bf7b7af49898b82`.
  Failed development output remains at
  `/private/tmp/loopex-m7-checkpoint-recovery-current-dev1.log`, SHA-256
  `2267a5ae7556b702d32b40a7786b438e0bd91eb5f4f15259d2d5b55ff39b619d`.
  It exposed the missing authenticated parent-bound terminal gate and a wrong
  fixture decoder arity. Floor v1 passed its assertions but failed warnings as
  errors: `/private/tmp/loopex-m7-checkpoint-recovery-floor-v1.log`, SHA-256
  `7f7362870393e2ff540b493b65564b0cdfd16d73f66e2ddf0abe0dfb820b6baf`.
  Generated-case expectations now evaluate at definition time and assert exact
  retained checkpoint identities. No warning, timeout, validator, cleanup proof
  or required check was suppressed or weakened.

  Formatting, warning-free compilation, dependency direction, bootstrap/status,
  documentation and diff checks passed in 23.7 measured seconds. Complete output:
  `/private/tmp/loopex-m7-checkpoint-recovery-gates-v1.log`, SHA-256
  `25bb9e70669048ae0b04357f6fe7327dbe034c9ddd47955ad6c356098da71845`.

- Done: commit a validated first ordinary-limit checkpoint and its
  `context.compacted` event in one owner proposal. Replay recomputes original
  coverage, settled summary, metadata and exact progress before accepting it.
  Derived projection excludes exact covered source identities, prepends the
  canonical summary and preserves every unsummarized element; original run and
  lineage reads remain unchanged. Fitted checkpoint completion releases the
  parent staging identity without ending its run, opening another summary
  attempt or charging again. The next ordinary request and receipt replay from
  committed projection. A partial checkpoint cannot claim completion and
  survives cancellation. Private effect-history pages validate and traverse
  both checkpoint and completed episode without owner activation or dispatch.
  This is a reducer/reader proof; live checkpoint transaction uncertainty,
  multi-prefix continuation, automatic dispatch and standalone compact remain
  open. One added T07 subtask closes; original totals remain 51 done / 128 todo /
  7 retired including T00. Added totals become 183 done / 10 todo, or
  179 done / 9 todo for T01–T19.

  The sixteen-file selection passed 225 tests on both supported pairs. Current:
  12.5 measured runner seconds,
  `/private/tmp/loopex-m7-checkpoint-commit-current-dev3.log`, SHA-256
  `06032c8a8c01b9a6f234cd14453e587b2270f778ac6cbcf21ec4fdc5d72128ff`.
  Floor: 13.2 measured runner seconds,
  `/private/tmp/loopex-m7-checkpoint-commit-floor-v1.log`, SHA-256
  `a3c19500c6f65ec91601bb4b317be0aa5cd248ac44fa1fc4dbc9fa53e57bddad`.
  Development failures remain retained at
  `/private/tmp/loopex-m7-checkpoint-commit-current-dev1.log`, SHA-256
  `9d4049d60b0122a3a8e71de65869c9025668e4ff49a3a602eb761b391e3da0d4`,
  and `...-current-dev2.log`, SHA-256
  `54adefe0e1a704122e7ad120be2a09cdb57bbbe66bd1a298237a68f04b73a8d1`.
  The joined ordinary request exposed raw-lineage receipt reconstruction after
  substitution; this was corrected. Its probe-only project receipt also needed
  the actual current `no_manifest` shape for durable ordinary staging. No
  production validator, bound, cleanup proof or check was weakened.

  Formatting, warning-free compilation, dependency direction, bootstrap/status,
  documentation and diff checks passed in 23.6 measured seconds. Complete output:
  `/private/tmp/loopex-m7-checkpoint-commit-gates-v1.log`, SHA-256
  `84a5f1a3e9cda7ac55b3819b688cabec0b271081cab2d92105570f505eb796f6`.

- Done: a settled first summary now has an exact pending-substitution probe.
  It validates the unprotected whole-unit cut against complete original-record
  coverage, renders owner-authenticated summary provenance and measures before
  and after ordinary q=0 requests through their complete record fixed points.
  Both record bytes and estimated tokens must strictly decrease. Progress may
  remain above an ordinary hard limit; a larger summary refuses. Captured steer
  stays fixed across later steer admission and owner succession. Cancellation,
  abort, elapsed deadline and spent parent bounds prevent admission; observed
  usage remains charged once. Actual unknown-usage settlement and the last
  parent turn prove spent-bound refusal before projection begins. This constructs candidate data only: no checkpoint
  record, publication, projection substitution or ordinary intent is committed.
  Prior-checkpoint continuation, successful commitment, live recovery, captured
  rendering triggers, thinking targets and standalone compact remain open.
  This extends T07's completed summary-provenance subtask without changing totals.

  The sixteen-file selection passed 219 tests on each supported pair. Current:
  12.7 measured runner seconds,
  `/private/tmp/loopex-m7-checkpoint-progress-current-dev4.log`, SHA-256
  `d0492a538887b94e833bfbfbd246c53e7914d2abce0a8a899c6a60755edcf9f0`.
  Floor: 13.1 measured runner seconds,
  `/private/tmp/loopex-m7-checkpoint-progress-floor-v2.log`, SHA-256
  `8062e54ac36aecc617d7a905db23ac572163828247477829add8deae9954cb9b`.
  Formatting, warning-free compilation, dependency direction, structure/status,
  documentation and diff gates passed in 23.6 measured seconds:
  `/private/tmp/loopex-m7-checkpoint-progress-gates-v2.log`, SHA-256
  `626e4df3235a9089086f18e837feffe880c2a6215735a1d7389ba6a34a2b6be3`.
  The added successor test initially named a nonexistent owner_row helper;
  using the existing exact owner_advance fixture fixes its construction without
  changing production behavior or proof. That failed output remains in
  `/private/tmp/loopex-m7-checkpoint-progress-current-dev2.log`, SHA-256
  `1e84b5650d3e17aaa30b4d5b02b78fec27506ebaea74eb25eafd7fd5c1e71b5b`.
  All focused handles are terminal and collected; no agent or decision is pending.

- Done: full fast check on clean integration candidate
  `d0dd8ec6aa139332d4225f4b72436f1f60bd4ba0`, once, with complete output and
  exact revision retained. All eleven application suites pass, including 1,026
  Core tests and 556 CLI tests, in 1,381.2 measured runner seconds. Output:
  `/private/tmp/loopex-m7-d0dd8ec6-fast-check.log`, SHA-256
  `5a5d627df88022cb8a4b0ed8d9ee2bc565b6d1659e805d8a34233de6a3d43ac3`.
  The clean attached verification checkout stays at that tested candidate.
  This covers the terminal-v2 codec, complete maintenance effect-history reader
  and shared ordinary staging/tail measurement. Later pending-substitution
  source changes are outside that full check and have their focused proof above.
  It is not the floor closure run or release matrix, and unfinished M7 outcomes
  remain open. The full check handle is terminal and collected; do not repeat
  that candidate as a pass. The goal remains active on m7. Next join the retained
  successful summary to checkpoint commitment/projection and exact owner/store
  recovery before enabling new automatic summary dispatch.

- Done: ordinary and maintenance staging share the reference receipt builder,
  using replay's canonical descriptors, tool projection, estimator and ordered
  digest. Configured live ordinary staging and the compaction-tail probe also
  share the request builder. The ordinary-limit probe selects real replay-derived
  complete units at q=0, includes fixed instructions, tools, steer, continuation,
  metadata and complete record sizing, preserves frozen context and checks both
  legal empty resource headers. It uses the 2,048-token preference only for raw
  tail descriptors. Current-run protection, oversized mandatory tails, fixed
  input overflow, complete-record byte refusal and cancellation before/after
  measurement are proved without opening an attempt or bypassing the ordinary
  staging fence. Thinking targets, prior-checkpoint substitution, captured
  rendering offenders and the live automatic trigger remain open. This extends
  T07's completed tail-selection subtask; all checkbox totals stay unchanged.

  The sixteen-file selection passed 213 tests on each supported pair, including
  real configured-owner, optional-resource and maintenance staging cases.
  Current: 12.8 measured runner seconds,
  `/private/tmp/loopex-m7-ordinary-tail-current-dev4.log`, SHA-256
  `eb08139c4866fe79185fc2da666b414a03961feda01a4d3a1fe4c1506ea287c1`.
  Floor: 13.6 measured runner seconds,
  `/private/tmp/loopex-m7-ordinary-tail-floor-v1.log`, SHA-256
  `761d4ae9f9ea700ec17af6f5d3b5e63af586a7ce780f5f146c1794b933e211b2`.
  Formatting, warning-free compilation, dependency direction, structure/status,
  documentation and diff gates passed in 23.8 measured seconds:
  `/private/tmp/loopex-m7-ordinary-tail-gates-v1.log`, SHA-256
  `c63da64aa1af250dd652c2aec134621531e715839401d46c6fb082e235f1694d`.
  Initial fixture failures are retained. The real estimator charges one token
  per three canonical bytes; explicit budget overrides require matching origin
  and run-admission values; captured instructions must be rendered rather than
  read from a nonexistent ordinary rendered_bytes member. Correcting these
  fixture assumptions changes no production bound or assertion purpose.
  `/private/tmp/loopex-m7-ordinary-tail-current-dev1.log`, SHA-256
  `f7d7d663106c8b16dcd72312abf3dffdd24306ea19113595e627133cde3f789b`,
  and `/private/tmp/loopex-m7-ordinary-tail-current-dev2.log`, SHA-256
  `b32231e53a8fbbd98dd6947a2b96bb0f3c9366320ea3ff3d4fb9a1769ff492bb`.
  All handles are terminal and collected; no agent or decision is pending.
  The active goal continues on m7. This focused proof does not cover successful
  checkpoint commitment, automatic dispatch or the full integration candidate.

- Done: chat terminal outcomes preserve ADR 0043's approved v2 numeric and
  preparation failures. Outcome and CompactResult share the closed current
  failure validator; the independent Node consumers share their corresponding
  decoder. No cause, quantity bound, cleanup meaning or outer result changes.
  The regression first rejected a valid configured preparation failure. Real
  chat staging now retains a configured byte refusal through both the explicit
  wait and quit-drain barrier, then closing, without transport failure or model
  dispatch. The original 64 vectors remain byte-identical; a separate bounded
  fixture adds 93 positive/negative v2 vectors. Both consumers check all 157.
  This extends T10's completed terminal-codec subtask; all checkbox totals remain
  unchanged and the remaining chat workflow outcomes stay open.

  The four-file selection, explicitly including the Node client tests, passed
  57 tests on each supported pair. Current: 9.5 measured runner seconds,
  `/private/tmp/loopex-m7-terminal-v2-current-dev4.log`, SHA-256
  `a6751a536d7597a4f36564fae0b8c8113f4d249a88b134ac923b601179602f84`.
  Floor: 10.1 measured runner seconds,
  `/private/tmp/loopex-m7-terminal-v2-floor-v1.log`, SHA-256
  `4ef096a42b10d58e1ffd1a581f0e9a01cac1a209af47d23f036c48c7551fccac`.
  Formatting, warning-free compilation, dependency direction, structure/status,
  documentation and diff gates passed in 21.0 measured seconds:
  `/private/tmp/loopex-m7-terminal-v2-gates-v2.log`, SHA-256
  `410087965b10563a030c600339f318850d895f43a8048d4b0463a668163f8f06`.
  The failing-before regression remains in
  `/private/tmp/loopex-m7-terminal-v2-red-current-v1.log`, SHA-256
  `f1e7581811c330195a5dae8c4d5c045c1de9d1178e5dc97e2caee28f0ff4f3d3`.
  Fixture corrections split vectors under the unchanged 65,536-byte decoder cap,
  assert successful transport's actual nil value, and assert both barrier records
  with their exact input sequences and identical outcomes. Failed selections are
  retained as `/private/tmp/loopex-m7-terminal-v2-current-dev2.log`, SHA-256
  `45e7f4a50ff9c825b1965fd77fe6b402c1bbb71d44c2c0622482dc3f5bcf56e4`,
  and `/private/tmp/loopex-m7-terminal-v2-current-dev3.log`, SHA-256
  `3dd6d22b998f2686c08c4d1d424616ef6bd14fd153e8f263f1a770910ec0c261`.
  The initial dependency gate refused an unstaged new source; staging its ordinary
  blob corrected the repository precondition. That output remains in
  `/private/tmp/loopex-m7-terminal-v2-gates-v1.log`, SHA-256
  `ae23bfd702d5b3a9ff99109f627bb44e70ae103539a36445bc397dc6d591b719`.
  All handles are terminal and collected. No decision or agent is pending.
  Successful live compaction remains open; the goal continues on m7.

- Done: private effect-history coverage now traverses current maintenance
  admission, request and terminal records as neutral rows. It validates closed
  shapes, captured configuration, canonical request/source bindings, spending
  metadata and the existing compact-result codec without projecting executor
  effects. Full SessionState replay remains responsible for cross-record
  ordering, range ownership and original parent limits. Configured terminal
  failures remain readable; optional project/resource refusal counts must travel
  together. A complete reducer-produced current-format journal replays and
  traverses every one-record page, including boundary-token resume, without
  acquiring an owner or calling mutation/event callbacks. Malformed captures,
  substituted request bytes, wrong range counts and terminal usage/causes refuse.
  This extends T07's retained boundary work; all checkbox totals stay unchanged.
  Question decoder/public-event vectors and the coordinated transports remain
  open under T09.

  The thirteen-file selection passed 176 tests on both supported pairs. Current:
  4.8 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-history-current-dev2.log`, SHA-256
  `a81c733bab76f5c6300207981cc03ff9e8ae702db7698b0b022b75719ce5a424`.
  Floor: 6.1 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-history-floor-v1.log`, SHA-256
  `f2412b68c67b7a6b50975f827e26d7aab962b0ce7fe92843efd4395fbf01aa3a`.
  Formatting, warning-free compilation, dependency, structure/status,
  documentation and diff gates passed in 21.5 measured seconds:
  `/private/tmp/loopex-m7-maintenance-history-gates-v1.log`, SHA-256
  `a49f0aa317a432b7164c2998674b72e77762096e294d3527271d8d947be80349`.
  The first selection failed three fixture constructions because their canonical
  reply used `{:ok, reply}` instead of the reducer's `{:reply, reply}` tag.
  Correcting that input preserves all assertions and production settlement
  behavior. Its failed output remains:
  `/private/tmp/loopex-m7-maintenance-history-current-dev1.log`, SHA-256
  `ab26a122b278cf8fc361c9e46796cb6b69785fd5048531edd0148eb5ab534677`.
  All test/gate handles are terminal and collected. No agent or decision is
  pending. The active goal continues on m7; successful live compaction remains
  required.

- Done: select the retained compaction tail through whole-candidate fit probes.
  Validated units remain contiguous; terminal units release oldest-first and
  cannot grow back in the same selection. Explicit origin releases every
  unprotected terminal unit. Automatic origin grows an unreleased tail backward
  only while whole-request admission/rendering fits and tail cost stays at or
  below 2,048 tokens. A mandatory tail above that preference remains valid when
  hard limits fit. Protected/frozen units never release; empty history still
  probes fixed required inputs. Callback interruption and projection failures
  remain failures. These pure selection tests use controlled fit observations;
  the exact owner measurement, captured rendering offender, prior-checkpoint
  substitution and live automatic trigger remain open. No original T07 row is
  closed. One added selection subtask is complete.

  The twelve-file selection passed 163 tests on each supported pair. Current:
  4.3 measured runner seconds,
  `/private/tmp/loopex-m7-compaction-tail-current-dev1.log`, SHA-256
  `108e6b403e3d10ad2240ce54037864c04a218caa8cde6e187736223dbb529255`.
  Floor: 4.9 measured runner seconds,
  `/private/tmp/loopex-m7-compaction-tail-floor-v1.log`, SHA-256
  `738f710d2ec0b6535421609e9b330702ae57eb0a31255d10c73c87466b1bb282`.
  Formatting, warning-free compilation, dependency direction, structure/status,
  compiled documentation and diff gates passed in 21.6 measured seconds:
  `/private/tmp/loopex-m7-compaction-tail-gates-v1.log`, SHA-256
  `15ef7ffcc9f7aaa1f085c1fba5cc19ace633dbd84efa673ba9759b1943b43866`.
  All handles are terminal and collected. No decision or agent is pending;
  implementation continues on m7 with the goal active.

- Done: the full fast check ran once on clean integration candidate
  `e80116c1a69ad11f714d73585429f80d16a0b17f` and passed all eleven application
  suites in 1,383.5 measured runner seconds. Core passed 1,010 tests; the other
  suites retained their required cases and existing exclusions. Complete output:
  `/private/tmp/loopex-m7-e80116c1-fast-check.log`, SHA-256
  `aeb493b2b85b8bd4bec753a35e9b273f6ca15f698247271b69e70ef87c7faa65`.
  This proves that integrated revision, including maintenance settlement and
  owner recovery. It does not prove unfinished M7 outcomes, later source edits,
  the floor closure check or the release matrix. The check handle is terminal
  and collected; do not repeat this candidate as a pass.

- Done: join retained maintenance endings to the live serial session owner.
  Successors settle inherited open summary attempts conservatively without
  redispatch, finish retained invalid/incomplete summaries through the required
  v2 refusal, and preserve abort/deadline precedence, exact usage and unchanged
  conversation. The existing provider settlement, deadline admission and
  cleanup path now selects the owning episode's record family. Seven live
  recovery cases cover open/lost attempts, late abort, expired deadline,
  invalid/incomplete replies and termination after a known reply. Lost-attempt
  and known-summary endings additionally exercise all three Store uncertainty
  phases, exact owner exit/succession, one settlement/ending/public finish and
  no provider/executor dispatch. This extends the completed reducer subtask;
  no original or added checkbox totals change. Successful checkpoint recovery,
  new summary dispatch, selection and automatic triggering remain open.

  The eleven-file current selection passed 132 tests in 3.7 measured seconds:
  `/private/tmp/loopex-m7-maintenance-owner-current-dev5.log`, SHA-256
  `94f70d7e6d95e3692d7e2de2e76bdf4d3852008bbbb315b0a1c95b67ae86f448`.
  Floor: 132 tests in 3.4 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-owner-floor-v2.log`, SHA-256
  `93abdb7194d65d6268ff365616d1464959b6d2ff36a48c505eff012bc7e5605b`.
  Formatting, warning-free compilation, dependency direction, bootstrap
  structure/status, compiled documentation and diff gates passed in 21.2
  measured seconds:
  `/private/tmp/loopex-m7-maintenance-owner-gates-v1.log`, SHA-256
  `db6f829eeedc57495d00474403dfa0979c93aa705e11d3ceb458d01e295c63dc`.
  The first floor run passed assertions but correctly refused compiler warnings
  from generated tests comparing a literal mode against several distinct atoms.
  Small parameter helpers preserve the same case matrix without those warnings.
  An exploratory effect-query witness first used the wrong facade, then the
  correct Runtime API reported history_unavailable because this fixture Store
  lacks creation provenance. That optional read is outside the live ending
  proof and its exploratory witness was removed. Required ending assertions,
  faults, joins and bounds remain. T09's private maintenance coverage is still
  open and no query-completeness claim is made here. Every development failure
  is retained separately. All focused/gate handles are terminal and collected.
  The next integrated candidate will run the full fast check once. No agent or
  maintainer decision is pending; the goal remains active.


- Done: correct invalid/incomplete summary endings to retain ADR 0043's private
  v2 refusal. The prior reducer derived the failure from the settlement but
  omitted its required refusal record. Canonical summary replies now settle
  accounting once into checkpoint-pending state, retaining either bounded
  summary output or its independently recomputed failure. A failed summary then
  commits the episode terminal, v2 refusal and parent terminal together, without
  a second provider settlement. Recovery can finish that refusal from the
  retained reply without another call. Abort or deadline after settlement wins
  before checkpoint/refusal completion; usage remains charged once. Provider
  errors, owner loss and admitted terminations keep their adjacent settlement
  and parent-terminal transaction.

  The final eleven-file selection passed 119 tests on both supported pairs.
  Current: 3.8 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-settlement-current-v2.log`, SHA-256
  `2b5d2c61eb9ba0069899f7ffa107d00dff28abb5bd89b4808fb7323328b4a674`.
  Floor: 7.1 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-settlement-floor-v3.log`, SHA-256
  `8a661fb096a2e2b951408e6b56d1e8140138769dbfa9b24cc8c10d479191b6e7`.
  Formatting, warning-free compilation, dependency, structure/status,
  documentation and diff gates passed in 24.3 measured seconds:
  `/private/tmp/loopex-m7-maintenance-summary-refusal-gates-v2.log`, SHA-256
  `e79c35b8b3ecf6555674c5c8cccd97ca801d4ebf9c6cdac113f800bfa9c2fa69`.
  Development current-dev5 failed compilation because an assert directly wrapped
  an Elixir if/do expression; assigning before asserting fixed that fixture.
  The first gate found a formatting layout difference; applying its required
  layout exposed a pre-existing fixture race in current-v1. Prepared resume
  pauses recovered work, so the fixture's newly admitted prompt could dispatch
  before shutdown and refuse episode admission as non-quiescent. The fixture
  now stops its runtime before retaining the prompt through the real Store,
  just as it retains the episode. Successor prepared activation, uncertainty
  injection, zero provider/executor calls and exact joins stay required. No
  bounds, retries or acceptance checks were weakened. Every output is retained
  separately; no unchanged failed run was retried as a pass. All handles are
  terminal and collected. This correction changes no checklist totals.
  Live dispatch/cleanup, selection and checkpoint transactions remain open.
  No agents or decisions are pending and the goal remains active.

- Done: join maintenance settlement to the durable episode reducer. Successful
  natural summaries retain bounded output pending checkpoint admission, charge
  reported or remaining-allowance usage once, and leave ordinary conversation,
  pending work and public events untouched. Invalid/incomplete summaries and
  lost or unreadable attempts settle with a leading episode terminal and exact
  consecutive parent ending. Replay refuses incomplete or interrupted endings,
  changed identities, usage or failures, and duplicate settlement. A proven
  not-dispatched first attempt permits one exact-request retry; each opened
  attempt consumes the captured parent call allowance. The first admitted
  abort/deadline wins, including a later abort and late reported evidence.
  Validated replies exceeding settlement depth retain actual reported usage
  through the existing bounded compaction provenance. Successor replay retains
  the request and settles owner loss without retry or a checkpoint.

  The eleven-file selection passed 118 tests on both supported pairs.
  Current: 3.7 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-settlement-current-dev3.log`, SHA-256
  `be4417ac2f7cd384ac3ab2cf86af4980a71fb2cf7e2d9bf229c2da23e0ac1ec0`.
  Floor: 6.4 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-settlement-floor-v1.log`, SHA-256
  `0c6fc176cc1f25ebc2d45e1446812a446d9792d48f61f54f63109eda453c6dc5`.
  The first development run retained two fixture failures: the accounting row
  has input/output fields rather than total_tokens, and changing current bounds
  cannot replace the episode's captured limits. Corrected fixtures use the
  existing schema and capture a one-call parent before episode admission.
  No production change was needed for those failures; the corrected selection
  passed 115 tests before adding depth, interruption and successor witnesses.
  Formatting, warning-free compilation, dependency direction, bootstrap
  structure/status, compiled documentation and diff gates passed in 23.3
  measured seconds. Complete output:
  `/private/tmp/loopex-m7-maintenance-settlement-gates-v1.log`, SHA-256
  `59c3c0aee24493ff5d7d0229ea93cc1d5e01f6130fb10c758222d5b66f70d041`.
  All test handles are terminal and collected. This closes one added reducer
  subtask; live provider dispatch/cleanup, minimum-tail selection, checkpoints,
  automatic triggering and standalone compact remain open. No original T07
  checkbox closes, and no full fast, provider, release or closure proof is
  claimed. No agents or maintainer decisions are pending; the goal stays active.
  T01–T19 counts are original 51 done / 122 todo / 6 retired and added
  177 done / 9 todo. T00–T19 counts are original 51 / 128 / 7 and added 181 / 10.


- Done: correct maintenance request capacity to read the existing run-accounting
  `{tokens, source}` shape through `SessionState.accounting/2`. The preceding
  staging change used `total_tokens`, so an already-charged parent could raise
  instead of checking its remaining 1,024-token reservation. Its direct fixture
  had repeated that incorrect shape. The witness now uses the retained shape,
  proves a charged parent with remaining capacity fits and a depleted parent
  refuses, and preserves the existing ordinary accounting lifecycle selection.
  No original or added checkbox changes from this correction.

  The same ten-file selection passed 98 tests on both supported pairs.
  Current: 5.9 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-staging-current-v2.log`, SHA-256
  `a6d8a4ed53a9aeffb11fdc07f00ef4983b6bba986dd1392fb06bfc83350049f1`.
  Floor: 6.2 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-staging-floor-v2.log`, SHA-256
  `9b2b31d0d8d8e06eeccfc27da6cc4a1086173df7d0e604f14c4ebdf09738ee1c`.
  Formatting, warning-free compilation, dependency direction, bootstrap
  structure/status, compiled documentation and diff gates passed in 23.2
  measured seconds. Complete output:
  `/private/tmp/loopex-m7-maintenance-staging-gates-v2.log`, SHA-256
  `29cbfba9d1b114240279dcb0da57d4d125cd7f0a2c5e726b88882554f8443d13`.
  All handles are terminal and collected. No full fast, paid provider, release
  or closure evidence is claimed. Next work remains the live T07 selection,
  maintenance settlement/accounting, checkpoint and dispatch joins described
  below. No agents or maintainer decisions are pending; the goal stays active.
  T01–T19 counts remain original 51 done / 122 todo / 6 retired and added
  176 done / 9 todo. T00–T19 counts remain original 51 / 128 / 7 and added
  180 / 10.

- Done: stage the owner-selected maintenance source as an exact receipt-bearing
  request with a consecutive, distinct maintenance attempt-open row. Bind the
  captured session version to the episode's actual journal position. Coverage
  deduplicates complete originals by journal position and hashes their measured
  cost and full-record digest in that order; source JSON keeps its separate
  digest. A real provider settlement's private response-ID change leaves source
  bytes unchanged and changes coverage integrity. Multiple terminal-derived
  results count their shared original once.

  Whole units now project lazily under the existing artifact/question rules at
  `q=0`. Prefix and excerpt preflight receives the actual covered-unit count and
  measures the entire request, including range identities, exact descriptors,
  receipt fixed point and captured resource headers. Strict system equality
  refuses before source traversal. The current input and every protected unit
  remain ineligible. Later queued input changes no captured source. Captured
  parent capacity, preparation/run clocks and cancellation checks refuse before
  intent. Partial, interleaved, duplicate and consistently substituted pairs
  refuse recovery. Attempt-open commits the first request deadline and increments
  its episode counter without ordinary conversation or accounting mutation. An
  unsettled maintenance attempt fences bare run endings.

  Ten-file focused verification passed 98 tests on each supported toolchain.
  Current: 3.5 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-staging-current-v1.log`, SHA-256
  `2a656828eb7a4b280f9f02740459eaddb0e25a0657d23b74fda3df4b9d78086d`.
  Floor: 6.3 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-staging-floor-v1.log`, SHA-256
  `1e0d183dcd1864be0755b7d18e15e246b34bdcbf602e583f73fde8c49755a48a`.
  Complete outputs retain exact source/test digests. Development failures caught
  a misplaced test pin, wrong commit helper/result handling, an invalid empty
  budget probe and a fixture parent ceiling that could not admit genesis.
  These were corrected before the final selection; no failure was hidden by an
  unchanged retry. The budget probe now uses the admitted episode and the strict
  equality witness uses a valid parent with larger maintenance instructions.
  The expanded development selection then passed 66 tests. Formatting,
  warning-free compilation, dependency direction, bootstrap structure/status,
  compiled documentation and diff checks passed in 23.2 measured seconds.
  Complete output: `/private/tmp/loopex-m7-maintenance-staging-gates-v1.log`,
  SHA-256 `02a085a57b8d1b340b781b57ff3a3305a2b2fb15e056477ceb77948e6249c810`.
  No provider payment, full fast check, release check or milestone closure is
  claimed. All execution handles are terminal and collected.

  This completes one added T07 boundary subtask. T00–T19 originals remain
  51 done / 128 todo / 7 retired; added subtasks are 180 done / 10 todo.
  T01–T19 alone remain original 51 / 122 / 6 and added 176 / 9.
  Original T07 remains 0 done / 11 todo; its added subtasks are 15 done.
  The eligible cut still comes from the future ordinary-request selector.
  Minimum-tail release/growth, automatic triggering, live provider dispatch and
  cleanup, episode settlement/accounting, checkpoint commit/recovery and
  standalone compact remain open. Private effect-history episode/request/terminal
  readers and coordinated wire consumers still need their existing T09 decoder
  work. The goal remains active on `m7`; no agents or decisions are pending.

- Done: add distinct `maintenance_attempt_settled_v3` and
  `maintenance_termination_admitted_v1` vocabulary with the closed episode,
  summary ordinal and compaction purpose identity. Reuse the existing v3 reply,
  transport, termination, retry and accounting validators. A canonical summary
  reply ends its summary operation even if it attempted tools; it cannot select
  ordinary executor continuation. Natural completion, output schema, sizes and
  progress still require owner validation before checkpoint publication. Late
  replies remain evidence only; exact not-dispatched attempt one alone permits
  the one retry. Dispatched/unknown owner loss charges the remaining allowance;
  validated oversized reply evidence retains exact reported usage. Maintenance
  rejects a required continuation mapping. Ordinary and maintenance settlements
  now also refuse a reply digest differing from the outer staged-request digest.

  Control retires an exactly matching spent maintenance permit from its
  validated settlement, without requiring an invented ordinary run terminal.
  The existing boundary fixture joins its worker before acknowledging the
  actual Store settlement receipt, observes retirement, then proves the old
  position remains stale. It invokes no provider and proves no checkpoint.
  Effect-history reads validate the new deadline/settlement rows and advance
  coverage without inventing executor effects; malformed rows refuse.

  The six-file focused selection passed 97 tests on each supported pair.
  Current: 26.9 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-outcomes-current-v1.log`, SHA-256
  `cdc0732138c76cc064e30da7610040144e5d64eb2d4158643c3dd2a2115f2b12`.
  Floor: 28.9 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-outcomes-floor-v1.log`, SHA-256
  `bd9f3571fb237d2452fe9c664ead997ec2290b644f14536ec8ac813bbc92ed2e`.
  Complete outputs retain exact source/test digests. The five-case boundary
  selection passed before the added history/accounting/digest witnesses; the expanded
  two-file development selection then passed 15. No paid provider calls were
  made. Formatting, warning-free compilation, dependency direction, repository
  structure/status, compiled documentation and diff checks passed in 22.2
  measured seconds. Complete output:
  `/private/tmp/loopex-m7-maintenance-outcomes-gates-v1.log`, SHA-256
  `f76e9fc9e1082bc573898613d0c428e8966d795cc3fc3105f6299d21763a566a`.

  The goal remains active on `m7`. T00–T19 original rows remain 51 done / 128
  todo / 7 retired; added subtasks now have 179 done / 10 todo. T01–T19 alone
  retain original 51 / 122 / 6 and added 175 / 9. No agents or decisions are
  pending. Original T07 rows remain open: request/source ownership and complete
  receipt preflight, episode spending/recovery, live triggering/dispatch,
  checkpoints and standalone results still need integration. The latest full
  fast pass remains `ff21bed9`; no full check of these newer bytes is claimed.

- Done: retain complete normalized original-record provenance beside each
  committed conversation source. The index contains only digest, byte cost and
  original journal position; it stores no original-record or message copies.
  Prompt, queued steer and promoted follow-up sources keep their original
  admission. Deferred terminal replies retain their settlement's provenance
  through the existing indivisible pair. Executor results bind their full
  receipts, question answers bind the actual response admission, and unstarted
  cancelled results bind the terminal that derived them. Projection and replay
  use the same existing source identities. Multi-row proposals supply each
  source's actual prospective journal position without advancing the proposed
  state's committed version.

  The nine-file focused selection passed 138 tests on each supported pair.
  Current: 28.2 measured runner seconds,
  `/private/tmp/loopex-m7-compaction-originals-current-v1.log`, SHA-256
  `4b9c18af22bee712b9224615253e7ff45284136d871bbdb7978cdb121b93ffc4`.
  Floor: 29.0 measured runner seconds,
  `/private/tmp/loopex-m7-compaction-originals-floor-v1.log`, SHA-256
  `c6b5271e22341d6023f17b1dba97bf29c2729c7276436db232ed8193bb1a92ea`.
  Complete outputs retain exact source/test digests. The new witnesses compare
  actual live owner state with complete replay, verify queued/promoted inputs,
  real executor receipts, terminal-derived cancellation and question responses,
  and alter a retained provider response ID without changing canonical messages:
  the complete-original digest changes. Development runs first found wrong
  fixture API/question spelling and synchronous use of the nonblocking event
  queue. The corrected fixture then caught deferred assistant provenance being
  attributed to the terminal rather than its original settlement; production
  attribution was fixed before the final selection. No failed run was retried
  unchanged as passing evidence.

  Formatting, warning-free compilation, dependency direction, repository
  structure/status, compiled documentation and diff checks passed in 23.0
  measured seconds. Complete output:
  `/private/tmp/loopex-m7-compaction-originals-gates-v1.log`, SHA-256
  `d04e41798aa83cf807f1eb23439ad76180816fee9327aebc9516c1af7856a0b1`.

  The goal remains active on `m7`; no agents or
  maintainer decisions are pending. T00–T19 originals remain 51 done / 128 todo /
  7 retired, with 178 done / 10 todo added subtasks. T01–T19 alone have original
  51 / 122 / 6 and added 174 / 9. No original compaction row is closed by this
  provenance index: ordered range integrity, maintenance request staging,
  attempts/accounting, dispatch, checkpoints and standalone compact remain.

- Done: extend the existing ProviderAttempt vocabulary and verified Control
  permit boundary with `maintenance_attempt_opened_v1`. Its closed fields are
  episode identity, positive unsigned summary ordinal, fixed compaction purpose,
  operation identity, attempt and staged digest. No ordinary run/turn fields are
  invented. Each logical operation keeps the two-attempt domain; the episode's
  four-attempt spending gate still belongs to its forthcoming reducer. Record
  and binding validation reject mixed scopes, missing/extra keys, unsupported
  kinds, changed purpose and malformed identities. Control reconstructs the
  binding from the exact current journal row before its one-use send. Its
  retirement read recognizes the maintenance current-open identity too.
  Effect-history scans validate these rows and advance coverage without adding
  executor effects; malformed rows cannot be skipped.

  The five-file focused selection passed 90 tests on each supported pair.
  Current: 27.3 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-permit-current-v2.log`, SHA-256
  `4e5878f74220f355afb70ff4864096775ee8a5185d6961430778db9a1cc670af`.
  Floor: 28.0 measured runner seconds,
  `/private/tmp/loopex-m7-maintenance-permit-floor-v2.log`, SHA-256
  `648a08e1324e005328504e665b89a3a31c2aa05972b1616ec566a3be9c41d97a`.
  Complete outputs retain the exact source/test digests. The live boundary
  fixture writes the open row through Store and acknowledges its actual receipt;
  it supplies the private owner-call envelope and invokes no provider. It proves
  exact-position refusal, changed identity refusal, elapsed deadline, one send,
  repeated-spend refusal and process joins. It does not prove an episode/request
  reducer or live compaction dispatch. The first three-case development run
  failed two test assumptions about the existing 512-byte opaque identifier
  bound and `deadline_elapsed` refusal; fixtures were corrected without changing
  those production rules. The earlier five-file selection passed 89 per pair
  before the additional effect-history witness.

  Formatting, warning-free compilation, dependency direction, repository
  structure/status, compiled documentation and diff checks passed in 21.9
  measured seconds. Complete output:
  `/private/tmp/loopex-m7-maintenance-permit-gates-v1.log`, SHA-256
  `7e3c38e77eac27e5b3fbdb7eb03a962fceacdfed58abc627b122561cbadf832d`.

  The goal is active on `m7`. T00–T19 original rows remain 51 done / 128 todo /
  7 retired; added subtasks now have 177 done / 10 todo. T01–T19 alone retain
  51 / 122 / 6 original rows and have 173 / 9 added subtasks. No agents,
  decisions or focused check handles are pending. Next implement the bounded
  maintenance request/attempt reducer and join source selection to the owner.
  No new full fast-check pass is claimed for these permit source changes.

- Done: full current-pair fast check on exact clean integration candidate
  `ff21bed908d7213026ed55ce4c04bfdda94ad5dd`, committed and pushed on `m7`.
  It ran in `/Users/spuri/.codex/worktrees/m7-trace-check/loopex`, detached at
  that SHA, with `LOOPEX_CHECK_ALONE=loopex_llm_reqllm`. All 11 application
  suites passed, exit 0, in 1,394.2 measured runner seconds. Complete output:
  `/private/tmp/loopex-m7-ff21bed9-fast-check.log`, SHA-256
  `4220dfb2af023b1ad8ecf88ae30f59e0fb6fa32eeea8f6aa0d6ab2b5752927d2`.
  Unified execution handle `53173` is terminal and collected; do not poll or
  restart it. That run covers the ending/expiry implementation, before the
  subsequent maintenance-permit source changes above. M7 remains In progress.

- Active: T07 durable compaction. Admission, run-owned terminal ordering and
  expired-preparation/undispatched-abort recovery are implemented. Next join the
  ordinary-limit trigger to bounded source selection, maintenance-specific
  request/attempt/settlement records and checkpoint commits. The not-yet-expired
  source-preparation dispatch path and its timer/worker joins remain open, along
  with standalone compact, automatic thinking headroom, usage-once accounting,
  checkpoint uncertainty and complete live recovery. No agents or decisions are
  pending. All handles are terminal and collected. The full integration pass
  above covers the committed ending/expiry candidate. Its source bytes need no
  repeated full check; run once again after the next integration source change.

- Done: implement `maintenance_episode_terminal_v1` as the leading row of a
  run-owned ending transaction. Its closed private fields are episode identity,
  optional unsigned clock observation and the accepted five-member result.
  Applying it installs only a transient marker. The exact existing ending pair
  remains adjacent; the matching run terminal validates and applies the episode
  result with the run ending. A partial durable head, intervening command/owner
  succession, duplicate prefix, wrong identity, changed result/counters/cleanup
  or fabricated parent-bound measurement refuses. Bare run terminals still
  cannot orphan an active episode. Provider-failure and cancellation containers
  remain distinct; deadline-staging keeps its own four-key record and original
  run failure, with the episode's maintenance-deadline cause alongside it.

  Expired pre-first-request preparation retains the observed clock and validates
  it against admission + 60,000 ms on replay. It produces the episode terminal,
  unavailable v2 refusal and failed run terminal with zero usage and no numeric
  bound or run deadline fabricated. An earlier or equal committed run cutoff
  wins with the run's existing deadline bound and exact measurement. These
  parent-cutoff reducer cases use explicit retained-state fixtures, not a live
  staged maintenance request. The live owner joins expired recovery through
  its existing commit fence. A recovered abort in the quiescent zero-attempt
  source stage ends cancelled, without a fictional unknown operation. The
  ordinary settlement consumer selects its settlement by kind so a leading
  episode terminal cannot be mistaken for that verdict.

  The twelve-file focused selection passed 287 tests on each supported pair,
  in 50.7/50.2 measured runner seconds, 47.8/48.0 suite seconds. Current output:
  `/private/tmp/loopex-m7-maintenance-endings-current-v3.log`, SHA-256
  `7bd6e40703da5a98209df89d63b7bd72652fe16db90b20c8533b1777804994d2`;
  floor output `/private/tmp/loopex-m7-maintenance-endings-floor-v3.log`, SHA-256
  `b6823470db50cf70dbdbfe0ab97472474b05094f3baa122d302d58ca044fd008`.
  Live recovery tests seed the admitted boundary through public exact creation,
  a paused prompt, runtime stop and a real Store transaction using the existing
  test adapter. They cover all three uncertainty phases and no duplicate ending,
  provider dispatch or executor job. They do not replace real-Store/checkpoint
  fault evidence or prove the live automatic admission trigger.

  The first 59-case reducer selection passed both pairs; the first four live
  recovery cases also passed but did not join the owner's post-receipt handler.
  Adding that join exposed an incorrect fixture assumption that the owner stays
  alive after two uncertain Store presentations. The broader v2 selection failed
  one of 286 cases on each pair: current 48.7 seconds,
  `/private/tmp/loopex-m7-maintenance-endings-current-v2.log`, SHA-256
  `4538f78b9617f6765196b0fe90bf054f7c4b576e01168e4bb25041618e4479c0`;
  floor 48.5 seconds, `/private/tmp/loopex-m7-maintenance-endings-floor-v2.log`,
  SHA-256 `f422e5861929521bfb473b0888641e03d34426febd2019b2aa659c6b0ea21c1f`.
  An early owner monitor independently retained that same fenced exit:
  `/private/tmp/loopex-m7-maintenance-recovery-current-v2.log`, SHA-256
  `6a3913d8169821f3bb4f10c59651226f4412f46bec01b0b6727a63797aa9dabf`.
  The final witness joins exactly `maintenance_expiry_failed/commit_unknown`,
  then proves a successor reuses the already committed ending and public events.
  It adds no retry, timeout, fake replacement or weaker cleanup condition.
  Original T00–T19 counts remain 51 done / 128 todo / 7 retired. Added counts
  are 176 done / 10 todo, including the newly tracked T16 signal-fixture leak.
  T01–T19 alone: originals 51 / 122 / 6; added 172 / 9.

  Formatting, warning-free compilation, compiled documentation ordering,
  dependency direction, repository structure/status and diff checks passed in
  23.1 measured seconds. Complete output
  `/private/tmp/loopex-m7-maintenance-endings-gates-v1.log`, SHA-256
  `fab2675c8c5ad924a4794208c997a26172a4bfe093fea09c0f532b9920826718`.
  Final focused source digests and complete output inventory:
  `/private/tmp/loopex-m7-maintenance-endings-focused-evidence-v1.json`, SHA-256
  `ffbdd020e594c53067da2c94b595ca9c98ae73c6477da9e46e2ada9f49acec01`.
  The full fast check on this committed integration candidate passed as recorded
  above. The earlier `9e976839` output remains historical evidence for its own
  source bytes; the ending/expiry pass has its separate exact-SHA output.

- Done: implement the closed `maintenance_episode_admitted_v1` reducer for an
  automatic ordinary-limit episode, bound to its run and next staging identity.
  Capture the explicitly configured summarizer/instructions, parent input/system
  ceilings and origins, parent spending bounds, fixed four-attempt ceiling,
  zero initial usage/progress and admission + 60,000-ms preparation cutoff.
  Admission reads no current catalog and opens no provider attempt. Repeated
  admission and owner succession reuse the retained capture and cutoff even
  when current host settings are absent. Ordinary model staging is blocked
  while maintenance is active. A run terminal also refuses until an episode
  terminal clears that marker, preventing orphaned maintenance. Replay recomputes identities, configuration
  capture/digest and parent-bound relations, rejecting duplicate, incomplete,
  changed or consistently rehashed derived fields. This is the reducer foundation;
  it is not yet called by the live owner and proves no summary dispatch,
  checkpoint, standalone command or whole automatic-compaction workflow.

  The five-file focused selection passed 53 tests on each supported pair in
  3.0/2.6 measured runner seconds (0.4 suite seconds each). Current output:
  `/private/tmp/loopex-m7-maintenance-admission-current-v4.log`, SHA-256
  `2d49276b62afbe1cb0795a839bc09b1649ed4f03f2046144dd4e01c54dc19021`;
  floor output `/private/tmp/loopex-m7-maintenance-admission-floor-v4.log`, SHA-256
  `c020bddcae15b86ca45aa9c99d27bdbc8b93f1a999bb2c7fa7bad2b07d90fe61`.
  The earlier 51-case selection passed both pairs before the explicit succession
  proof was added. Review then found a run-terminal proposal which left an active episode orphaned.
  The new regression failed before the fence: seven of eight tests passed,
  `/private/tmp/loopex-m7-maintenance-terminal-failing-before.log`, SHA-256
  `5bcc7362ec92e955614b30930198b3c6960550eeec0a974b306fff64496df180`.
  Both proposal and replay now refuse that incomplete ordering. Complete output
  inventory and final focused source digests:
  `/private/tmp/loopex-m7-maintenance-admission-focused-evidence-v2.json`, SHA-256
  `e1b1ddfa806d5312f93506c1ef80a5e19bbef62b054d4a88055cd43b4559dd36`.
  The first gate selection stopped after formatting/compilation because the
  invocation used nonexistent `mix loopex.doc_order`; the documented task is
  `mix loopex.docs_check`. Failed invocation output:
  `/private/tmp/loopex-m7-maintenance-admission-gates-v1.log`, SHA-256
  `3ec34bfc22432018af00ced53f050f2bab3f5d03ac2f1c642f42287a292cae02`.
  No product bound or existing assertion was weakened. Original T00–T19 tally
  stays 51 done / 128 todo / 7 retired; added tally is 175 done / 9 todo.
  T01–T19 alone: originals 51 / 122 / 6; added 171 / 8.

  Final formatting, warning-free compilation, compiled documentation ordering,
  dependency direction, repository structure/status and staged diff checks
  passed in 23.5 measured seconds. Complete output:
  `/private/tmp/loopex-m7-maintenance-admission-gates-v3.log`, SHA-256
  `0a3d59746598cebf07ded8267e5f0dfef0e7aff2c68d9bc716622c8e58e5bbb0`.
  No full integration run is claimed for this reducer-only checkpoint; run a
  new clean committed integration candidate after the live owner join.


- Done: the requested restart checkpoint was committed and pushed at
  `daa31dbccfccb41f21f88ac9a56fed7a86f3ae73`. The maintainer resumed the active
  goal on 2026-10-02; the handoff above remains its historical pause snapshot.
  No agents, live checks or maintainer questions remain. Product implementation
  was `9e9768396d4d2a782e6ce87a56273f290bf289f8`; its full current-pair fast check
  passed all eleven application suites in 1,387.4 measured seconds. Complete
  terminal output `/private/tmp/loopex-m7-9e976839-fast-check.log`, SHA-256
  `9831595f0665c91833150ca5d34578a8be62c1086a6d6a84224c7524d167c9b5`.
  Handle `53188` is terminal and collected. The header binds the exact SHA and
  `LOOPEX_CHECK_ALONE=loopex_llm_reqllm`. No later documentation bytes are claimed
  as tested implementation. Original tally: 51 done / 128 todo / 7 retired;
  added tally: 174 done / 9 todo. Resume T07 durable compaction, then remaining
  chat/helper/protocol/current-only cleanup and fixture/evidence work. Do not
  repeat this exact full check or claim M7 closure from it.

- Done: the full current-pair integration check on exact clean implementation
  `5036d2d9675483025fa3ab98c4431844d5b072cb` passed all eleven application
  suites in 1,382.0 measured seconds. Complete terminal output
  `/private/tmp/loopex-m7-5036d2d9-fast-check.log`, SHA-256
  `76b42eb43beb494231317f244a1c9b68882489a9be090b8aed9ebbe798cf44cb`.
  Wrapper handle `88650` is terminal and collected. The header binds the exact
  SHA and `LOOPEX_CHECK_ALONE=loopex_llm_reqllm`. No later chat-host bytes are
  covered by this checkpoint. Original tally remains 50 done / 129 todo /
  7 retired; added tally advances to 172 done / 9 todo.

- Done: add the public `chat` main/dispatch branch, using the prepared host
  configuration, exact-genesis facade, session-directory tracking and existing
  command driver. Resume uses retained settings, verifies placement immediately
  before guarded activation and submits its redacted settings report before
  input. The shared diagnostic lifetime helper retains ask's existing certificate
  and exact-process joins. Startup refusals and installer exceptions stop input
  and attachments; composition or activation uncertainty forces unknown closing.
  Signal finish and closing occur after outer composition and placement cleanup.

  The final eight-file CLI selection passed 175 tests on both supported pairs
  in 66.8/67.5 measured suite seconds. Current output
  `/private/tmp/loopex-m7-chat-workflow-current-v11.log`, SHA-256
  `980aab8bc52b5b573aa842716f7f5ac843708a30cf291be5edc8f8c411a24f24`;
  floor output `/private/tmp/loopex-m7-chat-workflow-floor-v3.log`, SHA-256
  `b013ebadcb51e7febe29674f33968d3486d134491e924298de84d059d3f83fe2`.
  Both terminal handles are collected. The built escript embeds the actual Chat
  beam and runs startup/quit through real composition with an unused credential
  canary and no provider request. Command tests retain two scripted prompts,
  restart through the actual prepared signal holder, exact retained conversation,
  ignored schema-valid changed file aliases, redaction and startup/cleanup loss.
  This is not built two-prompt/provider, attended or complete maintenance/helper
  proof. Those original outcomes remain open.

  Development failures remain retained. Initial assertions assumed no quit
  barrier, decimal-string exit status, a pre-existing fixture state directory
  and synchronous terminal delivery. Corrections use the existing exact wire
  domains, an isolated state root and a captured event-join cutoff. The real
  signal-holder case establishes/restores the same isolated OTP manager as its
  conformance tests. A changed alias must still satisfy authored route validation;
  it does not resolve or replace the recovered model. Complete output inventory
  and final focused source digests: `/private/tmp/loopex-m7-chat-workflow-focused-evidence.json`,
  SHA-256 `c929efaa64c48c4afb4454303cc30610b22bc2798cc3a2a85e4f764d88c48763`. The first attempted test-file write used the wrong relative
  cwd and did not create the file; its 44-case run covered only existing tests,
  and is not host-workflow proof. No product bound, cleanup assertion or check
  was weakened. This closes one original T06 item and one added host subtask.
  Original tally is 51 done / 128 todo / 7 retired. Added tally is 173 done /
  10 todo, including the new public-host integration check under T16.

  Formatting, warning-free compilation, documentation ordering, dependency
  direction, repository structure/status and staged diff checks passed in 21.4
  measured seconds. Complete output
  `/private/tmp/loopex-m7-chat-workflow-gates-v2.log`, SHA-256
  `3e9e668aae72b5875898ca45087cfc426f67c3c930b3c3b7efdede65bc404e3b`.
  The first gate selection refused the newly created source files because they
  were not yet in Git's ordinary tracked inventory. Staging those files changed
  that inventory; no rule was bypassed. Failed output
  `/private/tmp/loopex-m7-chat-workflow-gates-v1.log`, SHA-256
  `4ce81918fc4404e4fb57e9f7b781ac5f56595488450dd2c326c29aa8c06b33ce`.


- Done: join prepared chat resume to the exact retained policy-question
  identity/revision and every already-admitted model's provider route. The
  checks resolve no current catalog aliases or credentials, preserve captured
  metadata and abandon every refused owner. A policy may change when there is
  no retained policy question. Real pending/answered questions prove matching
  preparation, conflicting policy/revision refusal, missing admitted-model route
  refusal, untouched environment credentials and zero provider/executor work.
  The fixture now supplies its actual physical workspace reference to the
  existing executor boundary; default fixture callers retain their prior value.
  Each zero-mutation comparison spans one prepared-owner lifetime, rather than
  confusing a subsequent ownership acquisition with mutation by an inspection.

- Done: fix premature answered-policy reevaluation during prepared recovery.
  The ordinary scheduler paused recovered work but its answered-question branch
  bypassed that check. With a matching policy, reevaluation could resolve the
  interaction or stage an effect before holder activation; added chat witnesses
  reproduced changed bindings or a vanished retained policy. The branch now
  applies the same recovered-run pause to its interaction's run. Pending and
  answered questions with matching and changed policies retain exact facts and
  an empty in-flight worker set. Matching answered recovery positively starts
  reevaluation only after activation and joins that exact worker. Prepared,
  abandoned and fenced states keep the existing pause; explicit abort retains
  its ordinary cleanup path. ADR 0049 and the active plan pair retain the same
  guarantee, with no new API or authority decision.

  Final focused checks passed with warnings as errors on both supported pairs:
  62 CLI preparation/startup/guarded-signal cases (22.3/22.6 measured suite
  seconds), plus 36 Core startup/configuration/interaction cases (9.0/9.1).
  Complete terminal outputs and SHA-256:

  | Check | Complete output | SHA-256 |
  | --- | --- | --- |
  | chat-admitted-startup-current-final | `/private/tmp/loopex-m7-chat-admitted-startup-current-final.log` | `3ff4bf8cab1d0124b63a7c8d04d1d20fc9dc0170c2183b95e1e604f58b663304` |
  | chat-admitted-startup-floor-final | `/private/tmp/loopex-m7-chat-admitted-startup-floor-final.log` | `09149d89cb44829b7f6da1fe0944012be4bba0569461741282c7ba8ff07dd782` |
  | prepared-policy-current-v1 | `/private/tmp/loopex-m7-prepared-policy-current-v1.log` | `e3701b30ce688a16d07553b781ab58deb9f5ec55c0c954a447160b0c516a78c0` |
  | prepared-policy-floor-final | `/private/tmp/loopex-m7-prepared-policy-floor-final.log` | `2dcbbee61a67e210158c0f5bc521f2eea30ee4527a476692943b3552fdb18e21` |
  | chat-admitted-startup-current-v1 | `/private/tmp/loopex-m7-chat-admitted-startup-current-v1.log` | `ea8fa5be4a94edff2ab4136f3015ed10bb514dc89cc7eef1bb0d47f9c1e59c4f` |
  | chat-admitted-startup-current-v2 | `/private/tmp/loopex-m7-chat-admitted-startup-current-v2.log` | `cd64724da2f7c06bb8b1c31db1111875cced3dfa5e5f6ecc0ae9057e722304f7` |
  | chat-admitted-startup-current-v3 | `/private/tmp/loopex-m7-chat-admitted-startup-current-v3.log` | `c99b524eaf0933e48c41b0c4f4b3b7588b47b713d12b9ad27ec9d63e5def7a64` |
  | chat-admitted-startup-current-v4 | `/private/tmp/loopex-m7-chat-admitted-startup-current-v4.log` | `7af2ce0dc98b154c3d1fa5c790ec825ce4d6735bced5ad73eb909781d2ecda39` |
  | chat-admitted-startup-current-v5 | `/private/tmp/loopex-m7-chat-admitted-startup-current-v5.log` | `b19c1b5584a667804979f44322b9ae584bbb7e0c73b31b8fefacef422830b52f` |

  Formatting, warning-free compilation, documentation ordering, repository
  structure/status and diff checks passed in 18.4 measured seconds. Complete
  output `/private/tmp/loopex-m7-chat-admitted-startup-gates-v1.log`, SHA-256
  `97f2509c769f247c3f278e51ea33e07115d78239b03e024726c9bb8cff92bf9a`.

  Initial development failures are retained. V1 also exposed a stale comparison
  across two prepared-owner acquisitions; its subsequent comparison captures
  each new owner before inspection. The answered-question failures persisted
  after correcting the executor workspace fixture and then identified actual
  pre-activation reevaluation. V5 passed after the scheduler fix; both final
  selections include startup and guarded-signal cases. No deadline, required
  path, pause or physical-workspace guard was relaxed. The earlier 10c3fd5d
  full fast check predates these bytes and the request/receipt retirement.
  One added T06 and one added T09 subtask close. Original tally remains
  50 done / 129 todo / 7 retired; added tally is 171 done / 9 todo. Public
  chat command startup, report/input/placement joining, helpers, maintenance,
  coordinated protocols and closure/release proof remain open.

- Done: remove the model-request v1 reader, receipt revision 2/3 readers,
  old per-run conversation query, estimator/key fallback and lineage-validation
  bypass. Every admitted request is current v2 with receipt revision 4,
  mandatory null/non-null continuation cost and independently derived committed
  lineage. Resource fixtures now use current requests/receipts without a legacy
  writer helper. Exact whole-record/header reservation, row counts/order,
  supporting-file byte/size limits, instruction allowance, selection/source
  identities and replay refusals remain proved. Recomputed descriptors cannot
  replace committed prompt bytes. Independent self-consistent v1/nil encoding
  and old receipt revisions refuse. ADR 0044 and both active plan files retain
  the same rule. Genesis, outer staging-record generations and nine-field
  callback admission remain separate T15 work; this does not claim all old code
  is removed.
  Focused final checks passed with warnings as errors on both supported pairs:
  118 request/context/resource/skill/configuration/conversation/lineage tests,
  8.0/7.8 measured suite seconds. Complete terminal outputs and SHA-256:

  | Check | Complete output | SHA-256 |
  | --- | --- | --- |
  | current-final | `/private/tmp/loopex-m7-current-request-current-final.log` | `f5ffdebadcc9d5e33526ee725663857bc27f7232d3755db57bfe2dcc7f19c9f1` |
  | floor-final | `/private/tmp/loopex-m7-current-request-floor-final.log` | `0fce1317cc17bb8e87ae6ff5c4664b6a1b2d229d15459e81a2a4d68a541397bd` |
  | current-v2 | `/private/tmp/loopex-m7-current-request-current-v2.log` | `60d0e929d18de7693af31222fac22c7cdc1e428708e6ce098d1b838545b815c6` |
  | current-v1 | `/private/tmp/loopex-m7-current-request-current-v1.log` | `0b37656b8435f38dd811f219a18c5c77290f4ab079a73e83fca889b26c3b6ebe` |

  Formatting, warning-free compilation, documentation ordering, repository
  structure/status and diff checks passed in 18.7 measured seconds. Complete
  output `/private/tmp/loopex-m7-current-request-gates-v1.log`, SHA-256 `a144c4865bf6bd990980f0f8aeae2e0863913408e09f707450ddf16fc74d36fb`.

  The initial run failed two fixture assumptions: the current encoding fits
  exactly 65,536 bytes rather than the old 65,535-byte nearest fit; changing
  the header adds the same exact 11 bytes and refuses at 65,547. The matching
  receipt control for a rewritten prompt now correctly refuses at committed
  lineage, while matching system/tool/project descriptors retain their positive
  controls. Limits and deadlines are unchanged; failed output is retained above.
  The second development selection passed 85 cases; the final selection includes
  removal of the unused old conversation query and its current callers.
  One added T15 subtask closes. Original tally remains 50 done / 129 todo /
  7 retired; added tally is 169 done / 9 todo. The 10c3fd5d integration proof
  predates this cleanup. A later integration candidate must include these bytes.

- Done: the full fast check passed once on exact clean combined checkpoint
  `10c3fd5def1c58491f0d44e59fd51c6f06d8e1c4` in the detached verification
  worktree `/Users/spuri/.codex/worktrees/m7-trace-check/loopex`. All eleven
  credential-free application suites passed with their prescribed exclusions.
  Complete output `/private/tmp/loopex-m7-10c3fd5d-fast-check.log`, SHA-256
  `35d67e91483ae9cf8be28ef556f3feea13ec1580750332558aa1801cb966f552`.
  The terminal handle was collected; exit 0, measured duration 913.6 seconds.
  Later request/receipt cleanup in the primary checkout is outside that proof.
  Original tally remains 50 done / 129 todo / 7 retired; added tally is
  168 done / 9 todo. No closure or release evidence is claimed.

- Done: retire provider settlement v1/v2 decoders, their legacy ambiguity-only
  accounting branches and session cutover bookkeeping. The current v3 decoder
  directly checks all retained reply members and complete accounting evidence.
  Owner replay and effect-history projection admit only the current settlement
  kind; old kinds refuse as invalid private history even at the start of a
  history. The obsolete request-agreement bypass is removed. The exclusive M3
  historical-reader interaction test, extraction/compiler/replay helpers,
  legacy request/receipt rewrites and old revision constant are deleted under
  the accepted pre-1.0 override. Current interaction, skill-context and exact
  configured-session restart cases remain. The verdict matrix now names current
  v3 error shapes and includes an independent positive compaction-evidence cell
  with reported accounting, alongside ordinary unreadable estimated accounting.
  ADR 0044 and the active plan pair record the same current-only settlement
  decision. Other request/genesis/callback/API readers remain T15 work.
  Focused checks passed with warnings as errors on both supported pairs:
  153 settlement/accounting/configured/interaction/skill tests (37.8/37.6 measured
  suite seconds), plus 8 effect-history query conformance/cleanup cases (1.7/1.7).
  Formatting, warning-free compilation, documentation ordering and structure
  gates passed. All terminal handles were collected before hashing outputs.
  The b7a8f19e full fast check predates these bytes; the combined settings-report
  and settlement retirement needs a new clean committed integration candidate.

  | Check | Complete output | SHA-256 |
  | --- | --- | --- |
  | compile-v1 | `/private/tmp/loopex-m7-current-settlement-compile-v1.log` | `2b1d790e8c0fc0769aec74fefb9e6bfd7c5dea81dd8d964a5284eb4a8c42f406` |
  | current-v1 | `/private/tmp/loopex-m7-current-settlement-current-v1.log` | `2c4e10c0c60937efc23a9ac50bf33f0626fce14ab815d8ab203d027497343516` |
  | current-v2 | `/private/tmp/loopex-m7-current-settlement-current-v2.log` | `89d61db8ca4b91aca2d9f014dc4470ef03b58d03a9d3ca311dece2d7d68b081c` |
  | current-v3 | `/private/tmp/loopex-m7-current-settlement-current-v3.log` | `3dc907660ffcdda65ca94eb14dbf65328881d74b5c1d93c58b7fd0df49def8fe` |
  | floor-v1 | `/private/tmp/loopex-m7-current-settlement-floor-v1.log` | `770f0e8f799e602e7bc55652a0b482f48239f904f66314c2c82f0a0a9542a79d` |
  | floor-v2 | `/private/tmp/loopex-m7-current-settlement-floor-v2.log` | `0e653ea3c4c572d7ccf11f4d597208d21222eb945a9b154dd9116c7e071c0b88` |
  | query-current-v1 | `/private/tmp/loopex-m7-current-settlement-query-current-v1.log` | `fd53d00f760c6d499cacb9c7356bac26f2b1510b180fc674ffe40d4cd4d95e9d` |
  | query-floor-v1 | `/private/tmp/loopex-m7-current-settlement-query-floor-v1.log` | `08cf42c66c79927a97e05394cd91b7cc2efa642903b6990cc40c0c9f5b24963c` |
  | docs-v1 | `/private/tmp/loopex-m7-current-settlement-docs-v1.log` | `239ac08e330c92ee62e817282ab07e7339a120d7b26d08e79455fafaaccde797` |
  | structure-v1 | `/private/tmp/loopex-m7-current-settlement-structure-v1.log` | `37be54b486f41ba1b4a94e64827fa6f918a73be4ada0051c7919cf120477290a` |

  Current development v1 failed three stale expectations: retired-kind replay
  now uses invalid_private_history, and the old ambiguity error/table no longer
  describes current accounting evidence. Current v2 and floor v1 passed their
  assertions but exited 1 on the leftover unused historical-reader revision
  constant; they are failures, not passes. Final v3/floor v2 remove it and retain
  all current verdict, accounting and replay obligations. The observed
  Task.Supervisor shutdown_error/noproc diagnostic remains the open T16
  investigation, including the development output here.

- Done: the one full fast check on exact clean repair checkpoint
  `b7a8f19ed47d325b2e73a3c02fc7b08509856f96` completed with exit 0 in
  917.2 measured seconds. All eleven application suites passed with their
  prescribed exclusions. Complete immutable output is
  `/private/tmp/loopex-m7-b7a8f19e-fast-check.log`, SHA-256
  `9ea984aba4e25a6d64adfc39dd4708b561fbccce8484b18cda633d0344129876`.
  The terminal handle was collected before hashing. This proves the repaired
  current-tool/trace/receipt integration, not later settings-report bytes.

- Done: implement the approved owner-only startup settings-report admission in
  the existing DiagnosticConsumer. Its one asynchronous OTP request preserves
  caller identity and abandons late replies without waiting for IO. A closed
  row/pointer/value allowlist excludes credentials and private captures. Exact
  decimal quantities and indexed rows remain complete; each physical escaped
  UTF-8 JSON row including LF fits 4,096 bytes or drops whole. Existing pending
  capacity 256, one writer, loss accounting, failure sealing and cleanup joins
  are shared. Generic trace/diagnostic redaction is unchanged. Config inspection
  and the startup row producer now reuse the existing pure projection. Natural
  numeric array ordering preserves indexes 0..15 rather than placing 10 before
  2. Actual resume preparation supplies committed settings/origins without
  re-reading changed instruction files. The accepted ADR pair records the
  already-approved schema and consumer path. Public chat startup submission is
  still outer-host integration work under T06; this is not a completed public
  chat workflow claim.
  Final focused checks passed with warnings as errors on both supported pairs:
  consumer 19 (0.8/0.8 measured suite seconds), CLI selected/resume rows 26
  (16.6/15.7). These cover ownership, abandoned replies with a suspended drain,
  exact byte limits, all sixteen array indexes, provider/credential and captured
  body canaries, complete physical row equality, ordinary/trace shared loss,
  broken/stalled IO and exact process joins. Formatting, documentation ordering
  and structure/status gates passed. All output handles were collected before
  hashing. This change still needs its own subsequent integration candidate.

  | Check | Complete output | SHA-256 |
  | --- | --- | --- |
  | settings-consumer-current-v1 | `/private/tmp/loopex-m7-settings-consumer-current-v1.log` | `369a291868131abf2e5fbe58d11082b075eb76de77efec39fe8e317dc654fb78` |
  | settings-consumer-current-v2 | `/private/tmp/loopex-m7-settings-consumer-current-v2.log` | `7ca1fe94aa4cf46dac3970b0a2985e38dfc28a911250332dc5d9e43b0de938d0` |
  | settings-consumer-current-v3 | `/private/tmp/loopex-m7-settings-consumer-current-v3.log` | `d661324b1ade86390433d77e4525aa17b46a638f258909ba97316b053a740e47` |
  | settings-consumer-current-v4 | `/private/tmp/loopex-m7-settings-consumer-current-v4.log` | `7c031169968c6586434643f51ca5976b23ed9e2979a207d054367e5d849ce057` |
  | settings-consumer-floor-v1 | `/private/tmp/loopex-m7-settings-consumer-floor-v1.log` | `214546c446ea565a10af253d2d651e0eb10871b81d87e6461b1ac6da9356eb45` |
  | settings-rows-current-v1 | `/private/tmp/loopex-m7-settings-rows-current-v1.log` | `bd7d183ca4fa6b4dd4ca6eda4cb5956d19c254f0b69bbb74ad4aedea76215174` |
  | settings-rows-current-v2 | `/private/tmp/loopex-m7-settings-rows-current-v2.log` | `91888567fb7938f0856315f4f2b07612851952d3faa54d9a7163396471718068` |
  | settings-rows-current-v3 | `/private/tmp/loopex-m7-settings-rows-current-v3.log` | `d2b988b970615df8db268343a52e83e344b288f5dc46a0160e1f730d2094a987` |
  | settings-rows-floor-v1 | `/private/tmp/loopex-m7-settings-rows-floor-v1.log` | `a089b78eafef562f683b3fbac8c937cee3e3c806585ae89499f0b9747765762a` |
  | settings-rows-floor-v2 | `/private/tmp/loopex-m7-settings-rows-floor-v2.log` | `727b64e8e231ed7e1e4300d3f28546817c3f290d490c5ae756026e51608383ab` |
  | settings-report-structure | `/private/tmp/loopex-m7-settings-report-structure.log` | `37be54b486f41ba1b4a94e64827fa6f918a73be4ada0051c7919cf120477290a` |

  Consumer development v1/v2 are failed compile evidence: ExUnit's refute_receive
  macro does not admit a guard. An ordinary zero-wait receive proves absence of
  late reference-tagged replies without changing any product or fixture bound.
  Earlier passing development slices remain scoped to their tested bytes.

- Failed: the single full fast check on exact clean checkpoint
  `d7974fe1bdc79821eaf6c1a89be6a0ea98d09962` completed with exit 1 in
  918.8 measured seconds. Complete output is
  `/private/tmp/loopex-m7-d7974fe1-fast-check.log`, SHA-256
  `8d3d212dab74351cab8218a0f1a2bd3f67e816acb16b703dafe91124ab804354`.
  The terminal handle was collected before hashing. Composition had two failures:
  retired tool expectations and a comparison of per-second trace counters as
  cumulative counters. Executor had seven retired-generation fixture failures.
  CLI had one stale full-inline model-result expectation. These results remain
  failed evidence; the repaired bytes need their own committed integration check.
  Eight other application suites passed. Repair work is tracked under T16.


- Done: repair all ten failures from the d7974fe1 integration check without
  restoring retired tool generations. Current executor fixture constructors use
  the shipped exact declaration version; legacy positive branches are removed.
  Receipt preflight, dishonest retention, complete-byte capture and shared
  settlement allowances keep their original budgets and assertions. Composition
  expects the current inventory. Its real trace test now requires a physically
  delivered Control call with a source timestamp after each prompt's cutoff,
  under one captured original 100 ms receive allowance per prompt. Rate-window
  counter semantics, trace-session identity and exact owned-process joins remain
  unchanged. The CLI receipt test creates explicit v3 genesis and uses the real
  transfer/artifact store: all 16,384 source bytes survive retention and Store
  commit, the public reference matches the receipt, and the model's complete
  escaped message is at most 2,048 bytes with an exact receipt-text prefix.
  The shared demonstration fixture accepts an optional artifact store; default
  callers and the coding-task tests retain their existing behavior.
  Focused checks passed with warnings as errors on both supported pairs:
  composition 20 (6.0/6.0 measured suite seconds), executor 65 (35.4/35.5),
  CLI receipt/coding workflow 6 plus two prescribed real-provider exclusions
  (1.2/1.2). Formatting, documentation ordering and structure/status gates passed.
  These focused passes do not replace a full fast check of the repaired commit.
  All terminal handles were collected before hashing the complete outputs.

  | Check | Complete output | SHA-256 |
  | --- | --- | --- |
  | composition-current-v1 | `/private/tmp/loopex-m7-integration-fixtures-composition-current-v1.log` | `6343c7b53504f4356b3f19a2f7a617e1f7c536c1f081ba5f490374f46ac17bef` |
  | composition-floor-v1 | `/private/tmp/loopex-m7-integration-fixtures-composition-floor-v1.log` | `98ff4e4d9a83093b0abdf679334b580dbed5c715ecb22d700ec4818549350aaf` |
  | executor_local-current-v1 | `/private/tmp/loopex-m7-integration-fixtures-executor_local-current-v1.log` | `b51b75f2e62a56ae2fd7edcd4a7f6ccad882707bc9db09087a64d972de4b0078` |
  | executor_local-floor-v1 | `/private/tmp/loopex-m7-integration-fixtures-executor_local-floor-v1.log` | `2a2179c500e077440ec9785245f03b7d32dfaf0e5075d6aa0eeb12e1e1465bfa` |
  | cli-current-v1 | `/private/tmp/loopex-m7-integration-fixtures-cli-current-v1.log` | `49442b08a0ed6eee4c1c828a84f372d2b49ffd38932bf9724e4c16407e4b852b` |
  | cli-current-v2 | `/private/tmp/loopex-m7-integration-fixtures-cli-current-v2.log` | `e852e487b9123ef093db64b8c99a6f6208850632810895cdf6b76f7946861f16` |
  | cli-current-v3 | `/private/tmp/loopex-m7-integration-fixtures-cli-current-v3.log` | `4f56d754687997539ca009ef65ea5f11cd9ce24db933bbee5f08d12afbe6d995` |
  | cli-current-v4 | `/private/tmp/loopex-m7-integration-fixtures-cli-current-v4.log` | `c3b8935666dbd2e5dbd96c995636e5058d940dd4393187d6674c16cfdb324cd0` |
  | cli-floor-v1 | `/private/tmp/loopex-m7-integration-fixtures-cli-floor-v1.log` | `8da99e93d0f58a6c05ff32268e75cae001a48fc546e9e1008db786739e3c6ff5` |
  | structure | `/private/tmp/loopex-m7-integration-fixtures-structure.log` | `37be54b486f41ba1b4a94e64827fa6f918a73be4ada0051c7919cf120477290a` |

  CLI development v1 failed on a wrong transfer-module reference; v2 failed
  because the fixture still created old v2 genesis and bypassed the current
  projection. Both failed outputs remain retained. Explicit current genesis
  fixes the fixture's meaning rather than relaxing its byte ceiling.

- Done: retire the shipped 1.0 read/grep/find/ls declarations and dispatch
  support, their canonical vectors, the nil legacy read-capability table row,
  `CodingTools.generations/0`, the composition default-version pinning shim and
  the obsolete path-only read validator. Current callers now use one exact
  declaration per shipped tool. Read/search remain 1.1.0; write/edit/bash retain
  their current 1.0.0 definitions. Removing those older read/search generations
  does not erase the valid current null-capability case when no read is selected:
  job validation now admits that absence explicitly, while owner replay still
  rejects a substituted binding. Current vectors retain their exact preimages
  and digests. Executor tests prove retired read/search versions refuse before
  effects; real current Store/executor restart proves small inline results,
  early spill and range retrieval. All 128 tool subsets and question selection
  use the current declarations. The old default-create fixture branch and its
  two old-generation inline cases are removed; current inline behavior retains
  its own positive restart proof.
  The copied Core context fixture now pins the current four declarations and
  exact separate costs: provider 2,731 bytes/911 tokens, retained components
  4,774/1,593, and canonical definition list 3,922/1,308. The unrelated
  inheritance fixture uses a small host tool while preserving its original
  700-token limit, refusal/promotion order, restart and receive deadlines.
  ADR 0017's illustrative M2 numbers are identified as historical measurements;
  its admission rules and historical evidence remain unchanged. ADR 0041's
  pair and the current embedding guide record the current-only inventory under
  the maintainer's pre-1.0 rule. Superseded record/protocol/API readers and
  default genesis/instruction compatibility paths remain T15 work; this is not
  a claim that all old code has been removed.
  Focused checks passed with warnings as errors on both supported pairs:
  Core 108 plus one prescribed exclusion (8.0/8.0 measured suite seconds),
  current context admission 24 (2.4/2.5), composition 35 (12.2/10.8), local
  executor 130 (133.0/141.1), and CLI 45 (76.7/79.2). The Linux invalid-name
  filesystem witness remains unavailable on Darwin and required separately.
  Complete outputs and SHA-256 digests, after terminal handles were collected:

  | App/check | Current output / SHA-256 | Floor output / SHA-256 |
  | --- | --- | --- |
  | Core | `/private/tmp/loopex-m7-current-tools-core-current-v2.log` / `fc4c726d3d948764204aac91479f56861f0b6bbfc795e988aaeee9b3c50c96dd` | `/private/tmp/loopex-m7-current-tools-core-floor-v2.log` / `0d83c660d9e43c0fbf4d69b76a53690abd13e55fdaee21cbeba557116d5b0fd5` |
  | Context | `/private/tmp/loopex-m7-current-tools-context-current-v3.log` / `1687626346235d652805c6b78b91b084160d5bd35fdbad55ea16fd3304092b5d` | `/private/tmp/loopex-m7-current-tools-context-floor-v3.log` / `ed3346eb6080f79abb2e1b390aed10c77f50fcf71aeebdca8a42543b30082ecc` |
  | Composition | `/private/tmp/loopex-m7-current-tools-composition-current-v2.log` / `af8f550bfd9042d2c69fd8fb962d27436de5a26894a2a51b1d6c6906edd0dd22` | `/private/tmp/loopex-m7-current-tools-composition-floor-v1.log` / `596e7b845e50fcfc53d89b6195ef4d415adda7077e75e1f744cf0ed843146d57` |
  | Executor | `/private/tmp/loopex-m7-current-tools-executor-current-v3.log` / `027cbbcba4a1f95822fb4079f78c33cf267a4245564c9421400706d0a4537286` | `/private/tmp/loopex-m7-current-tools-executor-floor-v2.log` / `2d520fadf86e47b8f8ac3ef789ac708f9cf654a1bca2139d19b11878bc91eab1` |
  | CLI | `/private/tmp/loopex-m7-current-tools-cli-current-v1.log` / `35133a3660fa0d48ec48d5b23ba802c825624ec02c599eb88b11de8a7abe74ae` | `/private/tmp/loopex-m7-current-tools-cli-floor-v1.log` / `5e3b81501ce2cd20416adba0b216cd424ecdb964672bcee04411bee6a9f91888` |

  Failed intermediate outputs remain retained, rather than counted as passing:
  Core v1 failed because nil validity depended on the removed table row;
  composition v1 used a 2,816-byte source that correctly spilled rather than
  staying inline; executor current v1 fixtures still sent retired tool versions,
  then current v2/floor v1 used an unqualified fixture digest module. Corrected
  current read/search helper controls passed before the full executor rerun.
  Context v1 retained obsolete pinned costs and exceeded its intended successor
  fit with the larger read declaration; v2 still pinned the old list cost.
  All these source/fixture repairs preserve product ceilings, authority checks,
  receive/cleanup bounds and the current-format recovery obligations.
  Failed-output identities:

  | Output | SHA-256 |
  | --- | --- |
  | `/private/tmp/loopex-m7-current-tools-core-current-v1.log` | `b3d8bdb4f46c00d2cab60ab0f3a650b4a066aa926f9b13548378ac8a2cbe58cc` |
  | `/private/tmp/loopex-m7-current-tools-core-floor-v1.log` | `5dcaa9e2bc8ffd9d41d0957b8796f99d7029089ff870237d98b2b6303aae79f8` |
  | `/private/tmp/loopex-m7-current-tools-composition-current-v1.log` | `c2991f92b1bbea7f82ea4c29621695408cb2d731582b9faddfe0228cea631f19` |
  | `/private/tmp/loopex-m7-current-tools-executor-current-v1.log` | `0c5b0f4e57d8d038fc6d842d4db3a1d3edd969a175fd1ad2bdf0ff6506fc3d3a` |
  | `/private/tmp/loopex-m7-current-tools-executor-current-v2.log` | `aa8adf36c29c8b181e51c8445029acd66579f458bbf792573ca12366d9cadd34` |
  | `/private/tmp/loopex-m7-current-tools-executor-floor-v1.log` | `f29889081d7db79c18b020c23713d3b1d8cd4c2d4c8a8d8b4b4b982d413743ec` |
  | `/private/tmp/loopex-m7-current-tools-context-current-v1.log` | `5b7ba2b475bec92d244c2669374db8e001b59016383a18e18291e3ff6709715e` |
  | `/private/tmp/loopex-m7-current-tools-context-floor-v1.log` | `ec24b9a76a023c5be85215197c29f82fbd10a7b92306ff94791137b9751b039e` |
  | `/private/tmp/loopex-m7-current-tools-context-current-v2.log` | `cb871360ddfb72082ec3543317e181c9e69bfd821213b75506f3c884ac84d8a1` |
  | `/private/tmp/loopex-m7-current-tools-context-floor-v2.log` | `c2b06bdf7fbd6d9be82ba3a8a84228a3cb37e8e06bc1777f9ec2658f12d779cf` |

- Done: new-chat preparation now retains the approved closed revision-1
  physical workspace binding in exact v3 genesis options and rechecks it after
  configuration capture. Capability-held ordinary chat resume uses the new
  public startup read to compare the selected canonical-root/device/inode
  digest with both the retained binding and every pending effect reference.
  A same-root alias agrees; a different root, retargeted symlink, replacement
  directory, missing/non-directory root, or missing/malformed binding refuses
  through confirmed abandonment without durable mutation or dispatch. Explicit
  `--workspace` never adopts an unbound session. The pending-effect case uses an
  actual linearized intent and kills its coordinator before dispatch, then
  verifies unchanged records/events and one prior model call with zero jobs.
  Configuration inspection measures the full genesis with an equal-width cost
  marker while preserving nonexistent-path inspection and excluding the marker
  from returned or printed results. ADR 0049's pair records the approved shape
  and retires its legacy model/unbound exceptions under the maintainer's rule.
  All 40 focused preparation/resume/inspection cases passed with warnings as
  errors on both supported pairs: 27.3/25.8 measured suite seconds. Complete
  current output `/private/tmp/loopex-m7-chat-workspace-current-v3.log`, SHA-256
  `d07da3ca154df64ebe0fe870aa54b56caa927ec3b3e51b0a69dbd6ae9dc812bf`;
  floor `/private/tmp/loopex-m7-chat-workspace-floor-v2.log`, SHA-256
  `36f580124dd5df18c52e14a0f6d7e89b1d2a958d113cf3b10d441478183c969c`.
  Both terminal handles were collected before hashing. The initial current
  attempt failed only because a new inspection test called a private function;
  it now exercises the public command. Failed output retained at
  `/private/tmp/loopex-m7-chat-workspace-current-v1.log`, SHA-256
  `d0d5f2766f3051e3f0633ffad9a30eb8c4b7ae97238cc22605e1462575667df8`.
  This completes the preparer binding subtask. Public chat startup, its final
  execution/resource placement recheck before activation, pending-policy/routes,
  helper bindings and the owner-only bounded settings report remain open under
  the original T06/T10 integration obligations. Older APIs/readers and tool
  generations still require the separate T15 retirement work.

- Done: implement the approved separate `prepared_session_startup/1` read.
  Replay retains exact normalized genesis options. The serial owner reads those
  options, unresolved policy identity including an answered question awaiting
  reevaluation, pending admitted/staged model identities and pending effect
  workspace identities. Arrays are sorted/unique; completed effects add no
  startup requirement. Missing/corrupt required facts refuse without supplying
  host defaults. The result contains no private continuation or authority
  handles and shares the existing capability-holder/current-owner fences.
  The full capture admits exactly 65,536 bytes and refuses one byte above;
  there is no truncation. Existing prepared configuration stays four fields.
  Restart with changed host defaults, both policy states, actual retained intent
  before dispatch, nonholder/transfer/spent/abandoned/aborted/superseded reads,
  corrupt required fields and private-continuation exclusion are proved. The
  combined startup/configuration/v3-genesis suites passed 35 cases on each pair,
  in 2.9/2.6 measured seconds including VM startup:
  - `/private/tmp/loopex-m7-prepared-startup-current-v3.log`, SHA-256
    `5f950beb73a75ed3e567bf4d2ebb2d4968bc3b4d9e3c3b1303fee37fd208fff1`.
  - `/private/tmp/loopex-m7-prepared-startup-floor-v3.log`, SHA-256
    `c37b80edd7cff35ee146520429f2ffd0d0fa07149a0b1f3d92fa15bb52f22831`.
  The first run passed assertions but failed warnings-as-errors: its contextual
  fixture omitted required decide/1. The fixture now implements that callback.
  Failed output `/private/tmp/loopex-m7-prepared-startup-current-v1.log`, SHA-256
  `6eadf9b6aafa9bf72c160bffdb9e0d4a3016ba9373e06a8bb28adfbbea8105cb`.
  The intermediate successful current v2 run also emitted an unexpected
  Task.Supervisor shutdown_error/noproc report while stopping answered policy
  reevaluation. This remains the existing open T16 task, not a repaired defect:
  `/private/tmp/loopex-m7-prepared-startup-current-v2.log`, SHA-256
  `61ed26c7484f695e2b125d2b2a482831b37ba4e7351ecc25d118747f970159ad`.
  Final fault-injection runs intentionally report killed coordinators; no
  production diagnostics are suppressed. Public chat wiring, physical binding
  and diagnostic settings admission remain open. Original tally remains
  50 done / 129 todo / 7 retired; added tally is 158 done / 11 todo.

- Done: the single full fast check on exact clean checkpoint
  `46472d586aec11ddee30e349945d427ad208830d` exited 0 after 1,368.0 measured
  seconds. All eleven application suites passed under the prescribed exclusions;
  CLI passed 531 cases and the prior chat-output setup failure is absent on
  these changed bytes. Complete output
  `/private/tmp/loopex-m7-46472d58-fast-check.log`, SHA-256
  `a1f3f4c7f5811b3a4b5de17713b70dde5ffb60d6a05eadb639dad3c08df99c32`.
  Its terminal handle was collected before hashing. This proves its checkpoint,
  not the later public-read or startup-read children. No check or agent is live.
  The next integrated chat/startup candidate requires its own single fast check;
  floor closure matrix, release proof and the remaining original outcomes stay
  open. Next work is the approved current-chat physical workspace binding and
  owner-only redacted settings path, then public command startup integration.

- Done: expose the approved `Loopex.lookup_create_result/4` and
  `Loopex.creation_provenance/2` wrappers over existing exact bounded reads.
  Their Memory and reopened Local-store tests now use the public facade and
  current v3 creation only, retiring the older-v2 positive-read loop and default
  genesis inference comparison. Exact retained creation succeeds despite changed
  runtime cleanup defaults; changed genesis conflicts and an absent command stays
  absent. Command/session/page provenance agrees with the canonical create digest,
  all Store bytes remain unchanged and no coordinator starts. Both supported
  toolchains passed the two adapter cases in 1.3/2.7 measured seconds:
  - `/private/tmp/loopex-m7-public-creation-reads-current-v1.log`, SHA-256
    `7d85bf0561fd9633d16eba1f5f49ab7835139e779b0ea259edbb3c72c0f54c9a`.
  - `/private/tmp/loopex-m7-public-creation-reads-floor-v1.log`, SHA-256
    `3413677499e67e37e91aabe71d31656a437c3ef3337c963393d07cb1c48e7b5d`.
  Original tally remains 50 done / 129 todo / 7 retired; added is 156 done /
  12 todo. The broader holder-only startup read remains open. The daemon still
  calls the old three-argument lookup, so removing that implementation joins
  its current-genesis creation migration; no removal or proof is claimed yet.
  The single full fast check on exact clean checkpoint
  `46472d586aec11ddee30e349945d427ad208830d` is live in the verification checkout,
  handle 17705, complete output `/private/tmp/loopex-m7-46472d58-fast-check.log`.
  It predates these public-wrapper bytes; retain its digest only after terminal
  completion and do not use it as proof of this later child.

- Done: remove the separate M2 accounting rollback probe and its exclusive
  foundation reader test, historical Git checkout/build, launch adaptation,
  disposable old-root construction and old-reader resource vectors. Current
  embedding/source-built CLI skill/tool/artifact workflows and current-format
  recovery with changed or missing admitted snapshots remain in the suite.
  The remaining five foundation cases passed on both supported toolchains in
  48.8/56.9 measured seconds including VM startup:
  - `/private/tmp/loopex-m7-pre1-foundation-current-v1.log`, SHA-256
    `cafdf69e843ba1de4dcf0d16adcbb312f977f27fd5436566083b2953d0bb7d39`.
  - `/private/tmp/loopex-m7-pre1-foundation-floor-v1.log`, SHA-256
    `4a83b5a6f0c9c0856ed10b5ff8d52cc0921060a85128cccbded602693cf046d2`.
  The removed old-reader case is retired proof, not a passing case. Original
  tally remains 50 done / 129 todo / 7 retired; added tally is 155 done /
  12 todo. No provider credential or paid call was used. Current product
  genesis/receipt/tool-generation/API/protocol removal remains open.

- Done: record the maintainer's pre-1.0 current-contract rule and retire the
  historical cross-version archive runner. Remove its eleven exclusive helpers,
  shell archive fixture and CLI archive-checker suite. Remove old-tag staging
  and execution from the release runner and the retired fixture from the fast
  check. The removed `rollback` selector now refuses before Node or staging.
  The runner's current fresh-source build, exact redaction/collision checks,
  failed-redactor status retention and real-provider manifest census remain.
  Current and floor runner fixtures passed in 12.5/11.5 measured seconds:
  - `/private/tmp/loopex-m7-pre1-release-runner-current-v1.log`, SHA-256
    `c4420c1aae398eb95ea6a13a4847a030c2690e5c47e3df96fb2c3436745506b4`.
  - `/private/tmp/loopex-m7-pre1-release-runner-floor-v1.log`, SHA-256
    `5ad8711b58ebf7ff6dcb18ddab87f0b9070dcf5d20450ff69ed0f76ae2b8235a`.
  Formatting/status/documentation gates passed in 10.5 measured seconds:
  `/private/tmp/loopex-m7-pre1-gates-current-v1.log`, SHA-256
  `8a66e1ddc2942ad8d9f9a4074f104ed478c9fd154d78be53c4458d1db4e4ac53`.
  The reporter now counts retired rows separately, rejects invalid states and
  retains all 186 original item texts exactly against the supplied attachment.
  The completed old-receipt decoding row is retired too; its historical proof
  stays recorded at its revision. Original tally: 50 done / 129 todo / 7 retired.
  Added tally: 154 done / 12 todo. Current product decoder/API/protocol cleanup
  remains open; removing this exclusive runner family does not close it.

- Failed integration: the one full fast check on exact committed
  `c788127fe02a57f1105ccfb8a50f5044e55e15d9` exited 1 after 1,408.7 measured
  seconds. Ten application suites passed; CLI passed 535 of 536 cases and
  failed the owner-exit chat-output fixture's pre-acquisition 100-ms writer
  receive. Complete output `/private/tmp/loopex-m7-c788127f-fast-check.log`,
  SHA-256 `62c3d089cfbf57320ef06464758a299c63be42178b12b3cf8237191c5f3b605d`.
  The fixture now acquires the writer through synchronous Agent startup before
  inducing owner loss. Exact writer-normal/IO-worker-killed DOWN assertions and
  original receive waits are unchanged; failure cleanup stops the fixture owner.
  The complete chat-output suite passed eleven cases on both supported pairs,
  in 6.6/6.1 measured seconds including VM startup:
  - `/private/tmp/loopex-m7-chat-output-setup-current-v1.log`, SHA-256
    `35a5aa7bcf4bf0d217c68183d522b3efe1209a8c2dcf4eed3e5c7aecc52310c2`.
  - `/private/tmp/loopex-m7-chat-output-setup-floor-v1.log`, SHA-256
    `afbb2cd09bcaaa9b99695d7125f78538dec1ec56bd182d3cae9fe2b8f999badd`.
  No later bytes claim that failed parent as a pass. The next integration
  candidate requires its own single fast check.

- Maintainer decisions, 2026-10-02: all three new chat-startup recommendations
  are explicitly approved against the retained packet. No startup question
  remains unanswered. The subsequent rule removes pre-1.0 legacy/backward
  compatibility and requires old code to be deleted. It supersedes the approved
  legacy-unbound resume exception before implementation. Public startup reads,
  new-chat physical binding and owner-only diagnostic reporting remain approved.
  Seven original compatibility-only rows are retired rather than marked done;
  the original denominator remains 186. Added T15 tasks track removal and
  current-format recovery/backup proof. Historical progress text below describes
  its own revisions. The full c788127f check finished with one CLI failure;
  its retained output predates this scope change and is failed evidence.
  There are no live checks or delegated agents at this checkpoint.

- Done: live v3 authority witnesses now stage exact hostile claims in all
  host instruction sections and in role-shaped instructions. A denying policy
  still denies the model's write, with no executor job or effect intent. A host
  registry containing write still stages only the retained read generation when
  genesis selects read-only tools. The admitted read dispatches as a positive
  control; write and nested task calls receive exact unknown-tool refusals and
  have no effect intents. Replay preserves the same instructions and selection.
  This is Core's authority proof with scripted adapters; it does not establish
  the not-yet-implemented helper adapter's binding or child admission.
  The complete configured-session suite passed 39 cases on both supported pairs
  in 7.6/7.2 measured seconds. Complete outputs and SHA-256:
  - `/private/tmp/loopex-m7-instruction-authority-current-v2.log`,
    `ca45064abc57aa14f94fc80eb9c448c530549af7d5f8c5ce20d0391f84ffb60f`.
  - `/private/tmp/loopex-m7-instruction-authority-floor-v2.log`,
    `52d09cb3979a776d8eecbe648649936bfb8e0806fdbe5de0e6d5077e42e87c81`.
  The initial two-case run failed its new assertion because it looked for an
  absent public tool-name field. It now names each exact retained call ID and
  checks both historical and v2 intent kinds, preventing a vacuous no-intent
  assertion. The recovered tool selection uses the actual retained field.
  Failed output `/private/tmp/loopex-m7-instruction-authority-current-v1.log`, SHA-256
  `13ad4070911cdc40045f1e47c781dfd83986aae4148782392bb615a42e56358b`.
  One added T03 subtask closes; original authority/helper integration remains
  open. Original tally remains 51 done / 135 todo; added tally is 152 done /
  10 todo. The full fast check still runs only on c788127f in its clean detached
  checkout, not on this later test/evidence child. Its handle remains 45309.

- Running integration check: exact committed implementation
  `c788127fe02a57f1105ccfb8a50f5044e55e15d9`, clean detached verification
  checkout `/Users/spuri/.codex/worktrees/m7-trace-check/loopex`, current pair.
  `bash scripts/check.sh` runs once with `LOOPEX_CHECK_ALONE=loopex_llm_reqllm`.
  Complete streaming output `/private/tmp/loopex-m7-c788127f-fast-check.log`;
  live wrapper handle `45309`. Collect that handle to its terminal result before
  hashing. This is not a completed result or a closure matrix.

- Done: `loopex config validate` and `loopex config show --effective` now run
  through the actual CLI entry before runtime/application/custody startup. They
  validate the selected authored file before overrides, read exact selected
  instructions, resolve every saved role with independent child model budgets,
  measure complete parent tool/system/genesis cost and report escaped effective
  values with origins. Credential references expose only form/validity and
  unavailable commands, never slot names or values. Exact decimal quantities,
  Unicode/control-character paths, canonical model aliases, maintenance absence
  and fixed child deadlines are retained. The positive trace control proves the
  credential/runtime/provider witness is active; actual cold-VM command entry
  proves Unicode text even when the initial IO device uses Latin-1. Inspection
  starts no session, state root, trace or provider call. Its role-catalog digest
  is an instruction-cost preview, not a retained helper binding. The fixed
  `loopex.task` definition and argument validator are shared pure metadata;
  ordinary tool registration and execution remain unchanged.
  Final CLI selection passed 158 tests on each pair, 61.0 measured seconds each:
  - `/private/tmp/loopex-m7-inspection-current-final-v2.log`, SHA-256
    `5fac4fe8658f354ef7d883e2aba8547a808487882663c3acb4cf406e68cc2d59`.
  - `/private/tmp/loopex-m7-inspection-floor-final-v2.log`, SHA-256
    `ab06446a0262fec654f739f42a97b26cbc9d6507eccb1161f5adfd9e45916680`.
  Helper boundary tests passed two cases on each pair, 1.1/0.7 measured seconds:
  - `/private/tmp/loopex-m7-inspection-tool-current-v1.log`, SHA-256
    `e261049debd001f6fef0d424224a9eb3bd1bd0d3382093b61ad63283f36eaa37`.
  - `/private/tmp/loopex-m7-inspection-tool-floor-v1.log`, SHA-256
    `66b6f3b48f4f9192a5007ce128fe3e00735dcb01fa1f7043eb76eb1099693c67`.
  Formatting, warning-free compilation, compiled docs, dependency direction,
  status and diff gates passed in 15.5 measured seconds before the usage-fixture
  and evidence-only updates. Complete output
  `/private/tmp/loopex-m7-inspection-gates-v1.log`, SHA-256
  `b6a0a407684e4d1b47865cec9751a1de79d2738f141085214fca212acb9b2578`.
  Failed predecessor runs are retained. V1 had eight reserved ExUnit `file`
  context collisions; V2 exposed incorrect fixture credential-free syntax,
  undersized fixture system budgets and expected refusal classes; V3 exposed
  Unicode corruption at binary IO, fixed by the text-output boundary. The
  first broad runs failed the exact existing usage expectation because the new
  `config` command was absent; the literal now includes it without weakening
  assertions. No production default, check, timeout or model grammar changed.
  Retained failed outputs and SHA-256:
  - `/private/tmp/loopex-m7-inspection-current-v1.log`,
    `a85d31b6d1a4ef135d2a2864283616a87026a7b6fbf454a46b803efe95a808f7`.
  - `/private/tmp/loopex-m7-inspection-current-v2.log`,
    `72a20f649017d0e75826fe211987176f99d842ce0622e95dfff4b9925246259f`.
  - `/private/tmp/loopex-m7-inspection-current-v3.log`,
    `41bc1fd1d3c483d330f3def1e4755d5e0a01794868f02dcf9743000419afe280`.
  - `/private/tmp/loopex-m7-inspection-current-final.log`,
    `9c5d9b30655ece7ed8725f06e1f2b009c565e49dfa715e863b180668f91ea782`.
  - `/private/tmp/loopex-m7-inspection-floor-final.log`,
    `29232518467097b44c4c89a05348775c20c66c2b0c54ae5b11c13315d1a1e649`.
  Two original T04 items and one added item each in T04/T11 close. Original
  tally is 51 done / 135 todo; added tally is 151 done / 10 todo. The three new
  startup decisions remain unanswered; dependent contracts remain unimplemented.
  Public chat startup, helper execution and live maintenance remain open. The
  goal remains active. A full fast check for this integration candidate has not
  run yet; the earlier 203cccee proof is not attributed to these later bytes.

- Done: the standalone compaction-result payload now has a closed descriptive
  schema, 119 literal vectors and an independent stdlib-only Node consumer.
  They cover every accepted failure cause, ordinary/maintenance numeric scope,
  system equality versus other strict thresholds, headroom/hard-limit relations,
  reserved-token refusal below the declared limit, arbitrary exact usage and
  total accounting, partial checkpoints, cleanup branches, missing/extra/private
  fields, canonical decimal refusal and opaque identity bytes. Both consumers
  prove 65,536-byte checkpoints and refuse one-byte overflow. The complete schema
  and vector bytes are SHA-256-pinned in the owning suite. Node retains quantities
  as BigInt; neither implementation invents a run result or proves completion.
  Generation-1/2 schema identities remain unchanged. The new consumer is selected
  by the existing node_client release lane without adding a runner or dependency.
  Final protocol/payload/legacy conformance passed 45 cases on each supported
  pair, including the independent Node cases, in 0.6 measured seconds each.
  Complete outputs and SHA-256 digests:
  - `/private/tmp/loopex-m7-compact-vectors-current-final-v2.log`,
    `d198f3e1d20f14bb23ad6db86ebfa5846de370155b3b601f34ee54719aca8e19`.
  - `/private/tmp/loopex-m7-compact-vectors-floor-final-v2.log`,
    `46bb050874a8e0cdd13ce1ee9976bd39768dc738f5347a24bd1bfed5ff31d7dc`.
  Formatting, warning-free compilation, documentation ordering, dependencies,
  status and diff gates passed in 15.2 measured seconds. Complete output
  `/private/tmp/loopex-m7-compact-vectors-gates-final.log`, SHA-256
  `0d2877ae5ba8afc8775c96326615ede95dc8ce9c12f5b8fb8b03defbb36f4bd8`.
  The preceding gate failed because the saved proposal's literal angle-bracket
  type placeholders were exposed as raw HTML. Their bytes are now inside a
  visible fenced text block; the validator and decision content are unchanged.
  Failed output `/private/tmp/loopex-m7-compact-vectors-gates.log`, SHA-256
  `54d26bdfbaa51dfd8c476ef6f14b07fb60023af4ea30f8f2a359b1a091020acd`.
  One added T05 subtask closes. Original tally remains 49 done / 137 todo;
  added tally is 149 done / 10 todo. The three new startup questions have been
  sent and remain unanswered. Their dependent contracts are unimplemented.
  The earlier three approvals remain recorded below and have been implemented.
  Public chat startup, coordinated generation-3/4 protocol integration and live
  compaction remain open. No check or agent remains live at this checkpoint.
  The full fast check of 203cccee predates these independent consumer artifacts;
  it is not claimed as a full run of this later checkpoint. The goal is active.


- Integration checkpoint: the full current-pair fast check passed once on
  `203ccceed42cf1a9005028e7e26e4a385776da3f`. All eleven application suites
  and repository gates passed in 1,388 reported seconds, with unchanged
  prescribed exclusions. The wrapper exited 0 after 1,387 measured seconds.
  Complete output `/private/tmp/loopex-m7-203cccee-fast-check.log`, SHA-256
  `9ada6578a957702f13ebedd7d5a944100dbe16ccf51eac3ced3b71137c7525b0`.
  Its terminal shell result was collected before hashing. The clean verification
  checkout remains detached at that implementation SHA; this documentation child
  is not the tested SHA. No check or agent remains live. Original tally is
  49 done / 137 todo; added tally is 149 done / 10 todo after recording this
  integration proof and three new startup decisions. The goal remains active.
  Floor full-check, release matrix, live maintenance, public entry/config
  inspection, helper integration and other original M7 outcomes remain open.

- Decision packet awaiting a new maintainer answer: the preceding three approvals
  remain bound to the prepared configuration read, tool-event identity and early
  spill decisions recorded below. They do not accept these startup proposals.
  Exact packet `/private/tmp/loopex-m7-chat-startup-decision.md`, SHA-256
  `d4f6a1a4db1a625854ebb67161bc4cd8593c2031375fd3c4d3c8e4cbe32d75c4`.
  Its complete proposed bytes are retained here for resume. Dependent public
  contracts, the legacy-workspace amendment and settings admission remain
  unimplemented until an explicit new decision. Independent work may continue.

  ```text
  ## Concept

  Three startup choices are needed to finish the reference chat command. They are
  separate from the three already approved decisions. The maintainer owns these
  choices under AGENTS.md's public/cross-application and persistence tiers.

  1. Recommend public local startup reads. The approved prepared configuration
     read has exactly four fields and does not expose the facts needed to check
     pending policy, admitted model routes, or workspace bindings. Public status
     intentionally omits them. Add a separate holder-only prepared startup read,
     and expose the existing read-only exact-create lookup and provenance queries
     through the facade. This keeps the host on the facade and preserves the
     approved configuration result. The alternative extends that four-field
     result and still needs facade wrappers for the existing creation queries.

  2. Recommend pinning the existing physical workspace reference in new chat's
     genesis options. No new journal kind or kernel workspace interpretation is
     needed. For existing roots without that binding, require an explicit
     --workspace on each resume, compare every retained pending-effect workspace
     reference, and clearly identify this as a legacy host-selected binding. It
     does not prove the original directory's physical identity. This is a narrow
     amendment to ADR 0049's matching-workspace requirement, because old empty
     or model-only roots did not record an identity to compare. It preserves all
     staged requests, grants, receipts and historical records. Alternatively,
     require a separate immutable host workspace-binding ledger and a governed
     legacy adoption step; that adds persistence/recovery and backup machinery.
     Neither option silently treats the selected file's path as historical proof.

  3. Recommend an owner-only settings-report path in the existing diagnostic
     consumer. The generic diagnostic renderer hashes every binary over 64 bytes
     and sensitive-key values, so it cannot display effective paths and budgets
     faithfully. A closed already-redacted settings report needs separate admission
     while retaining the same bounded queue, writer, counters and cleanup. Generic
     diagnostics retain their existing renderer. The alternative has an additional
     stderr writer and requires arbitration, separate accounting and extra joins.

  These proposals do not enable helpers, alter run bounds, extend cleanup waits,
  change provider attempts, or authorize milestone closure or publication.

  ## Technical depth

  Decision 1, exact proposed local APIs:

      Loopex.prepared_session_startup(activation)
        :: {:ok, %{
             session_options: <exact retained genesis options>,
             pending_policy_identity: nil | %{"id" => <binary>, "revision" => <binary>},
             admitted_models: [<exact retained model identity>],
             admitted_workspace_refs: [<retained pending-effect workspace identity>]
           }} | {:error, term()}

      Loopex.lookup_create_result(runtime, command_id, session_options, genesis)
      Loopex.creation_provenance(runtime, selector)

  The latter two forward the existing Runtime methods with their current exact
  result unions, refusals and sixteen-row provenance pagination. No new Store
  callback is introduced. The prepared read uses the same current-holder,
  unspent-capability and owner fence as prepared_session_configuration/1. It
  reads one serial state and does not activate, mutate, dispatch, resolve a
  credential, query a catalog or supply current defaults. Policy identity covers
  an unresolved policy-produced interaction, including an answered interaction
  awaiting policy reevaluation; model-tool questions have no policy binding.
  Models are the unique exact identities from admitted run/staged provider work,
  not current launch defaults. Workspace references come from admitted pending
  execution grants/intents, not completed historical effects. Arrays are unique
  and deterministically sorted. Unknown or corrupt required capture refuses.
  The complete plain result must fit 65,536 canonical bytes. It never truncates;
  unrepresentable results refuse prepared_startup_too_large and the host abandons
  before activation. Legacy genesis options remain unchanged. No routing handles,
  PIDs, monitors, capabilities or private thinking/continuation are added. This
  trusted-holder read is not a wire or diagnostic projection.

  Prove retained values across actual restart and different host defaults;
  policy-produced open/answered questions; admitted old/new model identities;
  pending effect workspace references; empty/legacy captures; nonholder,
  transfer, activation, abandonment, abort and supersession; exact-byte refusal;
  unchanged journals/events and zero dispatch before activation. Existing
  configuration/status result shapes and historical consumers stay unchanged.

  Decision 2, exact new reference-chat options:

      %{"surface" => "chat", "workspace_binding" => %{
          "revision" => 1,
          "workspace_ref" => <existing WorkspaceIdentity.reference(workspace)>
      }}

  The existing reference is the digest of verified canonical root, device and
  inode. Capture it before creation, compare it at startup against the selected
  workspace and the execution/resource placement, and admit the complete genesis
  under the unchanged 65,536-byte ceiling. A conflicting binding refuses before
  activation. Core stores and returns bounded host options without interpreting
  the reference as authority. Configure cannot change this binding. A failed or
  unknown creation never publishes a new session as confirmed; exact-create
  lookup/provenance remains read-only and tied to the original command/genesis.

  Legacy options are never rewritten. With an absent binding, an explicit
  --workspace is mandatory even when the file selects the same path. The host
  verifies its current physical identity and every available retained pending
  workspace reference. Conflicts still refuse. If historical identity is absent,
  the startup report says legacy_host_selected rather than verified_historical.
  This attestation applies to this invocation only; later unbound resumes require
  the explicit flag again. The existing explicit --model rule for a configuration-
  less settled legacy session, pending-policy checks, admitted-route checks and
  helper-binding requirements remain mandatory. Old staged requests and effect
  identities are not regenerated or relabeled. Implement and prove both settled
  and unresolved M6 upgrades, unknown-effect nonredispatch, symlink retargeting,
  physical-directory replacement, current-reference conflicts and exact unchanged
  historical bytes. Migration instructions and fixture argv record this explicit
  legacy choice while preserving fixed prompts, budgets, oracles and attempt counts.

  Decision 3, exact host-private report data:

      [%{"setting" => <allowlisted effective setting pointer>,
         "value" => <bounded plain already-redacted presentation value>,
         "origin" => "flag" | "env" | "file#<pointer>" | "default" | "committed"}]

  The creating owner submits one report asynchronously without awaiting IO.
  Consumer admission validates the closed row shape and selected-setting allowlist.
  Provider rows expose provider identity, reference form/validity and commands
  unavailable to a credential-free binding, never environment-reference names or
  values. Captured instruction bodies, role prompts, provider capabilities,
  provider mappings and private continuation are excluded. Values and origins
  come from the confirmed selection; omitted resume files are not read again.
  Numeric quantities use exact decimal strings. Arrays use ordered indexed rows.
  UTF-8 and control characters are encoded into one physical JSON line per row.
  The existing 4,096-byte entry ceiling includes LF. An oversized row drops whole
  and counts as diagnostic loss; it is never truncated into a false selected value.
  The existing 256-entry pending queue, one writer and diagnostic emitted/dropped/
  unconfirmed counts apply. One owner submission is best-effort and never gates
  startup. No other runtime actor obtains the trusted report path. Ordinary trace
  and diagnostic messages still use Entry.render and its redaction. Test owner
  refusal, redaction canaries, long/escaped paths, exact byte limits, array order,
  committed origins, queue loss, broken/stalled stderr and exact process joins.

  Evidence locations:
  - apps/loopex/lib/loopex.ex: prepared configuration's closed four-member result;
    facade status excludes private pending policy/model/workspace capture.
  - apps/loopex/lib/loopex/runtime.ex: existing lookup_create_result/4 and
    creation_provenance/2 read-only contracts.
  - apps/loopex/lib/loopex/runtime/session_state.ex: retained run configurations,
    pending work, effect intents and unresolved interaction records.
  - apps/loopex/lib/loopex/interaction.ex: public view omits policy identity.
  - apps/loopex_composition/lib/workspace_identity.ex: existing physical identity.
  - apps/loopex/lib/loopex/runtime/resource_snapshot.ex: runtime-local resource
    catalog does not provide an always-present retained workspace binding.
  - apps/loopex/lib/loopex/session_directory.ex: existing metadata binds runtime
    placement, not workspace.
  - apps/loopex/lib/loopex/trace/entry.ex: generic long-binary/key redaction.
  - apps/loopex_composition/lib/loopex_composition/diagnostic_consumer.ex: existing
    fixed queue/entry/writer/cleanup contract.
  - docs/adr/0049-explicit-host-configuration-technical.md: retained resume checks,
    effective values/origins, bounded startup report and legacy model selection.
  ```

- Done: ordered private-driver `/status` now acknowledges its input before
  reading public session status and runtime trace counters through the command
  worker. It reports exact committed model/version/reasoning, active bounds,
  opaque interaction identities and closed policy/trace/maintenance branches.
  Its continuation warning uses only a confirmed capture matching the complete
  public configuration view; an external configuration change refuses status
  rather than using stale metadata. The command remains responsive to signals
  while either facade read blocks. A second interrupt returns unknown cleanup,
  joins the blocked worker and preserves the first captured cutoff. No later
  input is consumed. Ordinary status derives policy identity from the existing
  explicit registry selection; the trusted wrapper can supply its closed
  inspection provenance without granting command authority.
  The shared protocol compact-result codec implements ADR 0043's complete
  standalone result/failure/usage union, exact accounting relation and opaque
  checkpoint encoding. Status can encode the distinct configured/active models
  and completed compact payload. Live maintenance episodes/checkpoints are still
  absent: the current driver truthfully has no active episode or completed
  compact result. Their later owner projection and the coordinated schemas,
  literal vectors and independent consumers remain in T05/T07. Public chat
  command startup and T06's complete integrated workflow remain open.
  Focused chat/startup/resume/installed-signal checks passed 80 cases on each
  supported pair, in 20.2 current and 19.5 floor seconds. Protocol result/outcome
  checks passed 12 cases on each pair with the existing Node case excluded.
  Final boundary review then preserved the deadline's nonnegative-u64 domain,
  including zero; the complete two control files passed 19 cases on each pair
  in 0.3 seconds. No timeout, retry, cleanup assertion or check was weakened.
  Complete outputs and SHA-256 digests:
  - `/private/tmp/loopex-m7-status-chat-current-v6.log`,
    `20df7022091f350ce92423d7b268d565e97286f667e16e6fa4789e42d01001b7`.
  - `/private/tmp/loopex-m7-status-chat-floor-final.log`,
    `8d510473ef91ab30df8f406d6dd22db9f2a576b7208b3b559b9527fd88b3ee94`.
  - `/private/tmp/loopex-m7-status-protocol-current-final.log`,
    `329643959c95072e678688ad0720e482713d823defe84f4c425592abd88dc122`.
  - `/private/tmp/loopex-m7-status-protocol-floor-final.log`,
    `f874f448cec5e9bee52be1d86a1f985800b8a71fb8b8a2ebfc314e08e5a39e9b`.
  - `/private/tmp/loopex-m7-status-boundary-current-final.log`,
    `e992c9749a072077db64aeb00b47b628bd40c3b9def7869727408f7cd447af05`.
  - `/private/tmp/loopex-m7-status-boundary-floor-final.log`,
    `c816ea6d04063c0c90cad460efbc68e23ae1a5419e8e5606e201d2c8db7d3b24`.
  Formatting, warning-free compilation, documentation ordering, dependency
  direction and status gates passed. Complete output:
  `/private/tmp/loopex-m7-status-gates-final.log`, SHA-256
  `656622f5b9f816d6ec32577c187bbafc8f3857e1a336c7473f035ee5279cc04e`.
  Failed drafts remain failed evidence: control v1 passed its encoded LF into
  the payload decoder; driver v2 called the wrong test facade method; v3's high
  reasoning fixture omitted its required output reserve. They were corrected
  without weakening admission. Hashes respectively:
  `cd6b005e57fab697888dc8a34cc5bb6e3dfc5bfd735e859df70ad65a460a4aff`,
  `6134dfd5a83d563f51d0b40545b807dc9df340cfa23e14117ae332dbcad8e0de`,
  `80ae22a1142390a1bfcb504dacc8e2c64a228fe8ac3939326ca5fe45a3f42511`.
  Current-final's 80 passing cases had a clause-grouping compile warning and
  are not warning-free proof: log SHA-256
  `495fcda8c68ef0d4eeb5732c5025fd82f69a2fdea61f4aeaf8f0d1e5c018d49d`.
  Grouped source passed explicit warning-free compilation before current v6
  and floor verification. The pre-stage dependency gate refused untracked
  source; staged ordinary blobs passed the gate. No full fast check has run
  on this status candidate yet. The earlier 15bc check predates guarded
  activation and this status integration. No shell check or agent remains live
  at focused-proof completion. The next work is public host startup/cleanup,
  with unresolved resume startup facts kept separate from the three approvals
  already recorded below. No new maintainer question is pending.

- Done: the full fast check passed once on exact current-pair integration
  candidate `15bcaf73b6877cf30581a842ae775a2482da1604` in 935 seconds. All
  eleven application suites and repository gates passed, with prescribed
  exclusions unchanged. The complete retained output and wrapper exit 0 are
  `/private/tmp/loopex-m7-15bcaf73-fast-check.log`, SHA-256
  `144ed5d4bc6c20b8751a20ea69b6c32fda5ce208f5cbd65209997ce9bdcc5f40`.
  This closes the added T16 resume/startup/signal integration row. That exact
  commit includes resume configuration, staged startup and installed signals.
  It predates guarded prepared installation at 2b1d7410, whose separate
  focused proof is retained below. No closure matrix, release check, Linux
  thirty-run process campaign or paid provider trial is claimed.
  The verification process has exited; no shell check or agent remains live.
  The detached verification checkout retains the tested commit and primary m7
  contains the later guarded handoff. The goal remains active. Continue the
  public chat host join with the recorded ownership/cleanup ordering; no
  maintainer decision is currently waiting.

- Done: prepared chat signal installation reuses the existing capability
  holder and manager-lifetime guard. The handler is installed before Core's
  acknowledged transfer. Only the exact guarded holder then activates or
  abandons; the driver remains the sole local abort submitter, and Core's
  serial owner orders activation against that abort. Refused transfers clear
  the advertised holder, unresolved transfers retain uncertainty, and local
  installation refusal releases the unacknowledged holder. Prepared duplicate
  installation preserves its exact `interrupt_already_installed` refusal and
  original holder. Losing the chat driver withdraws the advertised capability
  and releases the holder; Core confirms abandonment of still-prepared work.
  An already submitted presentation retains the existing non-retraction rule.

  Real Core cases prove exact handoff and holder-only activation, abandonment,
  interrupted activation refusal without dispatch, duplicate-holder preservation
  and abrupt driver loss with exact holder DOWN and public abandonment. The
  complete chat interrupt/OS-signal, ask interrupt and legacy prepared-recovery
  files pass 84 cases current in 33.0 seconds and 82 floor in 32.1 seconds,
  warnings as errors. The two-case difference is the existing conditional OTP
  tty-handler fixtures. Current
  `/private/tmp/loopex-m7-chat-handoff-current-v4.log`, SHA-256
  `edb749b23f3b8fb640004623e966cdcb194bec9392335e3bcbee2b449acd2351`;
  floor `/private/tmp/loopex-m7-chat-handoff-floor-v3.log`, SHA-256
  `c5e74b87d380f8a9b207e0ce68518bfa3a8fd0cf5e25b3c509e1de9f4002bc57`.
  Compilation, format, documentation, dependency and status gates pass.

  The first draft masked the prepared duplicate refusal as generic unavailable.
  It now preserves the existing precise refusal before any transfer.
  Failed output `/private/tmp/loopex-m7-chat-handoff-current-v1.log`, SHA-256
  `646d7d116bf735608adee5ff53ba8cd8bfef91c1f0172e3fb2fd2696c20b6117`.
  A subsequent malformed one-line cond failed compilation before tests on both
  pairs; the enclosing function now uses its explicit do/end block. Outputs
  `/private/tmp/loopex-m7-chat-handoff-current-v2.log` and
  `/private/tmp/loopex-m7-chat-handoff-floor-v1.log`, both SHA-256
  `e6f07fe7964d8db90b86c27a676d3cdd9522dd7a613da2faa311738d557255ac`.
  No required assertion, cutoff, public Core contract or persistence changed.
  This completes one added T10 subtask; no original aggregate closes.

  The current full check remains live on 15bcaf73, which predates this handoff
  source. Its output is `/private/tmp/loopex-m7-15bcaf73-fast-check.log`, with
  no final result/digest yet. Observe that exact run, never restart it merely
  because observation times out. Next join the public chat host using these
  stages. Keep explicit host state across composition cleanup so discarded
  callback results cannot lose the driver or signal-route identities; retain
  those identities directly rather than in global state. Confirm the startup
  checks while the capability is held, install this guarded route, activate
  through its holder and retain unknown transfer/presentation facts unchanged.
  Finish the exact route after outer cleanup and before driver close, carrying
  its final exit decision. Effective display, workspace/pending-policy and
  admitted-work routes, trace/diagnostic lifetime, status/maintenance and
  helper/legacy resume remain open.

- Running: the full current-pair fast check has started once on exact
  `15bcaf73b6877cf30581a842ae775a2482da1604` in the existing detached
  `/Users/spuri/.codex/worktrees/m7-trace-check/loopex` checkout. Complete output
  is accumulating at `/private/tmp/loopex-m7-15bcaf73-fast-check.log`; the header
  records the candidate and toolchain, and the wrapper appends its final exit
  and measured duration. No result or digest is claimed while it runs. Resume
  by observing this run and its retained final wrapper line, not launching the
  same candidate again. The T16 integration row remains pending until the run
  ends. Primary m7 contains the committed resume/startup/signal implementation
  and focused evidence; this later handoff record is not tested source proof.
  No other shell check or agent remains running, and no decision is waiting.

  Next product work is the public chat host join. Preserve capability-held
  checks and explicit abandonment on every post-preparation refusal. Join
  workspace, pending-policy and admitted-work route checks before activation;
  install the signal route without bypassing the driver's admission fence;
  serialize the prepared capability handoff/activation with cancellation.
  Keep trace and diagnostic ownership through outer cleanup. Finish the exact
  signal route after that cleanup and before driver close, carrying an
  interrupted/unavailable decision as its minimum nonzero exit. Public
  startup/effective display, status/maintenance and helper/legacy obligations
  are still open. The goal remains active, with no milestone closure, merge,
  tag, release or publication authorized by this checkpoint.

- Done: a private chat mode in the existing interrupt handler routes every
  process signal to the same driver, preserving its original admission fence
  and one cancellation cutoff. It submits no separate abort and keeps the
  process backstop from the first interrupt. The second signal lets the driver
  report unknown cleanup through its closing record. Installation shares ask's
  bounded monitored installer and atomic manager claim. Wrong references,
  foreign handlers, late queued installation, host loss, driver loss, handler
  loss and manager replacement retain their explicit refusal/cleanup results.
  Normal driver close leaves the exact host finish decision observable.
  The host finishes the signal route after outer cleanup and before final
  output, passing an interrupted/unavailable decision as a minimum nonzero
  closing exit. That minimum cannot erase an earlier failure or unknown cleanup.

  The complete chat signal, actual-OS-signal, ask interrupt, startup, driver
  and resume-configuration files pass 62 cases current in 20.7 seconds and
  60 floor in 19.9 seconds, warnings as errors. The two-case difference is
  the existing current-OTP tty-handler fixtures, conditional on that module.
  Five separate child VMs prove real TERM/HUP/QUIT and launcher INT while stdin
  is blocked, plus two actual signals during a blocked prompt admission. The
  last case proves no competing abort, no model/executor dispatch and the
  unknown-admission closing bytes. Current
  `/private/tmp/loopex-m7-chat-signals-current-v5.log`, SHA-256
  `eeba7c70543efd28b6e67d37e3ee0f12f10910283e825252514b6ead5cf234ae`;
  floor `/private/tmp/loopex-m7-chat-signals-floor-v2.log`, SHA-256
  `6bcf4e13ff4971f7d998a9a9722c717d5e88f6006064bb08c048eb81573e1398`.
  The complete legacy prepared-recovery contract additionally passes 56 cases
  current in 25.1 seconds; its floor run with the earlier chat files passes
  115 cases in 43.5 seconds. Current
  `/private/tmp/loopex-m7-chat-signals-prepared-current-v1.log`, SHA-256
  `0af492026a6189f04a5f87cd2aeb03550a3f1ad3c8890e2043e0d4278438c5be`;
  floor `/private/tmp/loopex-m7-chat-signals-floor-v1.log`, SHA-256
  `a22e53d037249e64cff1fb52df1e3650540559a0e75d3cbf66266cfcb752adc1`.
  Compile, format, documentation, dependency and status gates pass.

  Two drafts remain failed evidence. The first used an incorrect test name
  for Core's actual `resume_activation_fenced` refusal; the unchanged exact
  Core refusal is now asserted. Output
  `/private/tmp/loopex-m7-chat-signals-current-v1.log`, SHA-256
  `29ce11acb1f48d3cc583c044b95cd4796058292f0547c4def38082ae9125d170`.
  The second tried to obtain disk object code for dynamically compiled test
  fixtures; setup failed before either OS case. Child VMs now require the
  actual helper sources in their temporary homes. Output
  `/private/tmp/loopex-m7-chat-signals-current-v2.log`, SHA-256
  `32ff782f5c001c6ef99d3b01e429b1627f3eaadf739932abb28e18024a118c08`.
  No bound, assertion, signal guarantee or required check was weakened.

  This closes one added T10 subtask and no original aggregate. Public command
  composition, prepared capability handoff/activation ordering, workspace and
  pending-policy checks, available admitted-work routes, effective startup
  display, tracing/status/maintenance and helper/legacy resume remain open.
  Run the full fast check once on this clean committed integration candidate
  in the existing detached verification checkout, retaining exact SHA and
  complete output. The c7d855f7 pass predates resume/startup/signal source and
  cannot prove this candidate. Do not repeat c7d855f7 or the failed parent.

- Done: chat startup can now open both facade attachment holders and read the
  public session status without consuming stdin or granting event reads. Run
  reuses those exact holders after the host completes its checks. The creating
  caller alone may prepare or run. A validated captured cleanup grace applies
  before the first status reply and must match the retained session grace.
  Startup interruption never starts replacement actors; interruption during a
  blocked status preserves one cutoff, then uses one ordinary abort. A second
  interrupt or attachment loss preserves unknown cleanup and retained joins.
  Startup refusal remains closable only after the outer cleanup decision.

  The startup, driver and resume-configuration files pass 39 cases on both
  supported pairs: 11.4 seconds current and 11.3 floor, warnings as errors.
  This includes actual prepared recovery, no dispatch before activation, exact
  attachment reuse, unchanged input/records on refusal, caller restrictions,
  early/blocked/second interruption, peer loss and actual worker DOWN joins.
  Current output `/private/tmp/loopex-m7-chat-startup-current-v3.log`, SHA-256
  `c075eb16c334c8e70589aa00f64a9b8308121b1077056ff9cbe9c860be01af24`;
  floor `/private/tmp/loopex-m7-chat-startup-floor-v1.log`, SHA-256
  `8e70d3af47603be36b06d3e2586d6565cf6192d8577e42371c3b13d73071b822`.
  The first draft incorrectly expected immediate monitor retirement after an
  unknown return. Its test now joins exact remaining workers within its stated
  1,000-ms fixture bound, preserving production uncertainty semantics.
  `/private/tmp/loopex-m7-chat-startup-current-v1.log`, SHA-256
  `9b2298f5e55e1489b309389abe250f7356dadfa74c2be1f66ceb5f9f153904ca`.
  The second draft exposed linked startup exits for invalid cleanup grace;
  validation now refuses before starting the driver or writer.
  `/private/tmp/loopex-m7-chat-startup-current-v2.log`, SHA-256
  `dee803a39de0786e9d73b57f78b277d45709ac7a1d57009ad9146b61a7679c66`.
  No required bound, assertion or check was weakened. This closes one added T10
  subtask, no original item. Public command startup, installed signals, trace,
  status/maintenance, workspace/policy checks and helper/legacy resume remain.

- Done: the full current-pair fast check passed once on exact repair candidate
  `c7d855f778a6ef29a8787b5af4e2ef076100e05a` in 1,381 seconds. All eleven
  application suites and repository gates passed, with their prescribed
  exclusions unchanged. Complete output:
  `/private/tmp/loopex-m7-c7d855f7-fast-check.log`, SHA-256
  `1df2c7ae84f81f91e87719ec76b69524565a95b711af9c646ce2906993208334`.
  The wrapper also retained exit 0 and the measured duration. This closes the
  added integration-repair verification row. It does not include subsequent
  resume preparation source at `e1832a376f705600623179ead1b4ab8b6aa6045e`.
  The failed 41091199 parent remains failed evidence. No floor closure matrix,
  release check, old-reader witness, paid provider trial or milestone closure
  is claimed. Both primary and verification checkouts were clean after the
  run; the verification checkout remains detached at c7d855f7.

  T16's separate Task.Supervisor diagnostic remains open. A temporary probe
  enables actual SASL supervisor reporting and runs 32 completed configured
  sessions, then proves their owner groups, private supervisors and runtime
  task supervisors gone. That current-pair probe passed in 0.5 seconds but did
  not reproduce the retained diagnostic. A second case suspends a real private
  Task.Supervisor, observes its queued stop, then proves its held worker's exact
  normal DOWN before resuming and joining the supervisor. Its hypothesized
  noproc diagnostic was absent on both supported pairs, so the two-case probe
  exits 2 on each pair. This rejects that specific ordering hypothesis; it is
  not a product fix or a successful aggregate verification. No source, report
  filter, timeout or required check changed.
  Probe `/private/tmp/loopex-m7-task-supervisor-reproduction_test.exs`, SHA-256
  `4032f9d0c377aa9989a65381ad4f6d0712f9e3944cdf1f7e0771482a52f96d6d`.
  Natural completed-work output:
  `/private/tmp/loopex-m7-task-supervisor-reproduction-current-v4.log`, SHA-256
  `705c767b9f4d7b93a25479c4a28646ad66b533b8da5dd35c1bfcd734a38d40d5`.
  Rejected hypothesis outputs:
  `/private/tmp/loopex-m7-task-supervisor-reproduction-current-v5.log`, SHA-256
  `43796a3eec4ae16f5b80df0aafce6f7f0db54add4693b37e7db2c35f954d17d3`;
  `/private/tmp/loopex-m7-task-supervisor-reproduction-floor-v1.log`, SHA-256
  `383f5ef5490f95575e202e7c3c0c4f200386493cdb9ac128bb8dbce6eb726a9f`.
  Earlier probe drafts failed before this observation: a nonstandard test name
  and non-waiting event helper, a mixed-key pattern syntax error, then a wrong
  empty-event response branch. Their v1-v3 logs are retained in /private/tmp;
  none is diagnostic reproduction evidence.

  Resume handoff: the goal stays active on m7. No agent or shell check remains
  running, and no maintainer decision is waiting. Use the reporter for the
  original/added T00-T19 denominators. Continue the public chat host join from
  the existing driver and the separate new/resume configuration stages; preserve
  capability-held checks and abandonment, install signal routing before
  activation, retain output closing after outer cleanup, and finish effective
  display/workspace/pending-policy/legacy/helper obligations. A full check of a
  later clean integration candidate must include the new resume source; do not
  attribute c7d855f7's result to its child or repeat the same tested bytes.

- Done: the host configuration owner now has separate resume preflight and
  prepared-owner comparison stages. Preflight validates the authored file,
  flags, paths and credential-reference forms without reading prompt files,
  model catalogs or credentials. The capability holder then reads the approved
  four-member retained capture through the public facade. Absent model flags
  do not consult current model metadata; matching aliases do not replace saved
  capabilities. Numeric, cleanup and tool-profile conflicts refuse. Omitted
  instruction files and helper defaults are ignored; only explicit bounded
  prompt sections are compared. New-run bounds and explicitly selected future
  maintenance remain invocation settings. The returned ordinary-session
  profile exposes retained values with committed origins, and subsequent
  configure preparation uses its exact frozen definitions and latest settings.

  Every returned post-preparation refusal attempts abandonment. Failed
  abandonment retains both the original refusal and owner uncertainty. Tests
  use real Core owners, including empty-registry restart, confirmed configure,
  all seven setting-conflict routes, missing provider route, changed/missing/
  oversized prompt files, malformed preparation and holder-loss uncertainty.
  They also prove unchanged records, no model/executor dispatch, mandatory
  authored bounds, ignored edited defaults and an untouched credential canary.
  The complete resume, creation/configuration and chat driver files pass 41
  cases on each pair: 21.2 seconds current and 20.8 floor, warnings as errors.
  `/private/tmp/loopex-m7-resume-configuration-current-v3.log`, SHA-256
  `78fce6323f18f59e4f6918783b84650e6abab363df7b1717aae1d57628baeb99`;
  `/private/tmp/loopex-m7-resume-configuration-floor-v2.log`, SHA-256
  `cea35fb2005232bb4b35591319fe475ddb717eec72c5e07fe429cbb683b83efd`.
  The first test draft failed the unchanged schema because it combined enabled
  helpers with tools none. Its retained output is
  `/private/tmp/loopex-m7-resume-configuration-current-v1.log`, SHA-256
  `4093a58af04bc350dfff8fe9bd40a1bf813de12cd5d460edce76c71bf3058e76`.
  The fixture now selects a valid edited helper-enabled coding profile while
  the saved read-only generation stays unchanged. An initial guard-time
  Access.get compilation error was corrected before any case executed.
  No assertion, bound, route or schema was weakened.

  This completes configuration preparation only. Public chat startup, prepared
  capability handoff/activation, workspace and pending-policy checks, admitted
  work routes, legacy migration, helper bindings, signals and effective-value
  output remain pending; no original aggregate item closes here. The separate
  full check currently runs on repair commit
  `c7d855f778a6ef29a8787b5af4e2ef076100e05a` and does not include this child.

- Done: the full current fast check on
  `410911990c021dcd6fcfde33a635c158834bacde` exited 1. Its last progress sample
  was 1,370 seconds; no final total duration was emitted after suite failure.
  Nine application suites passed. Composition failed three stale registry
  expectations, and CLI failed one abrupt-writer-loss monitor witness. Complete
  failed output: `/private/tmp/loopex-m7-41091199-fast-check.log`, SHA-256
  `d1d4627c46389cf8633bea26fb61b48a7798cbb0078448a1ea0930ebc08d602a`.
  This candidate remains failed evidence and will not be retried as a pass.

  Composition assertions now pin all eleven exact ID/version pairs, including
  both read/search generations. All 128 tool subsets across all three durable
  constructors still require legacy read/search selection; opt-in questions
  retain their exact definition and remain absent otherwise. Both complete
  affected files pass 26 cases: 9.2 seconds current and 9.3 seconds floor.
  `/private/tmp/loopex-m7-generation-registry-current-v1.log`, SHA-256
  `0a7c7c034403ffc43830b8dc3ba468fe0623b2e6303f7e6f0bd9ec1fb240ae9e`;
  `/private/tmp/loopex-m7-generation-registry-floor-v1.log`, SHA-256
  `53f01fe2868e8fd4f99dd6f0b28996a9cbb8ee5e326b98e60f6459f429d6fe42`.

  The CLI fault witness received `noproc` because a monitor sent to the worker
  and a fault sent to its writer can arrive in either order. A same-sender
  process-info request now confirms that the target installed the monitor
  before the fault is sent elsewhere. Both abrupt writer loss and ordinary
  owner exit retain their exact termination reasons and original 100-ms DOWN
  waits. No production code, grace, retry or assertion was weakened. The whole
  output and driver files pass 29 cases on each pair: 10.8 seconds current and
  10.6 floor. `/private/tmp/loopex-m7-chat-worker-monitor-current-v1.log`, SHA-256
  `1bf24fd796efa58890578621841bc1d96257396d8a1a89503d69312310cc9a34`;
  `/private/tmp/loopex-m7-chat-worker-monitor-floor-v1.log`, SHA-256
  `491397904533acacda77affc78d05b591873ff4a1ffe6ad2b528c5d2a342e450`.
  A full check of a new clean committed repair candidate remains pending.

- Done: T02's remaining integration proof now reads a Core-prepared legacy
  inline result through the real local executor, journal and public artifact
  store after an empty-registry restart. The original bash 1.0 job has its exact
  retain-only policy and immutable full inline receipt with no artifacts. Core
  charges one source before put and commits one prepared reference before its
  next bounded excerpt. A later read uses the original object after workspace
  content changes and binds the exact prepared row's journal version/digest and
  original run/operation/attempt/call provenance. It creates no recursive artifact.
  Both toolchains pass 18 composition cases: 4.4 seconds current, 3.9 floor.
  The first attempt truthfully failed preparation because the fixture configured
  only the executor's store, not Core's public transfer store. The fixture now
  composes that explicit accepted boundary at initial startup and restart; no
  production fallback or new store is introduced.

  One new long_bound case proves the real 60,000-ms preparation cutoff on each
  supported pair, each finishing in 61.2 seconds. Its fixture blocks indefinitely
  rather than expiring the ordinary five-second fixture gate. The retained
  cutoff is exactly started_at_ms + 60,000 with origin preparation; the same
  source count and cursor survive terminal replay. The exact worker is killed
  and joined before the failed context_preparation_failed /
  artifact_preparation_deadline terminal; no object, prepared-reference row or
  further model dispatch appears. Existing test bounds remain unchanged. This
  case is excluded from the fast suite and belongs to the existing Core
  long_bound release lane; its focused run executes one case, with 17 ordinary
  cases excluded. First current/floor drafts wrongly expected the origin label
  episode and failed immediately; the assertion now pins the existing preparation
  label. These failed drafts are not sixty-second evidence.

  Ordinary preparation, admission and lineage tests pass 37 cases on each pair
  in 3.1 seconds, excluding the new long-bound case. Existing T02 evidence above
  also proves exact frozen capabilities, owner-before-policy membership/refusal,
  shared excerpt allocation, bounded job-owned transfers, legacy inline behavior,
  Unicode/escaping, forged/cross-session/digest failures, source/work/capacity
  exhaustion, cancellation and uncertain commit/recovery. With the early-spill
  proof and literal generations already committed, all nine original T02 items
  and the last combined added T02 subtask are complete. This closes checklist
  implementation work, not an M7 outcome, closure or release decision.

  The repeated-ID tracking row under T16 is also complete. A new regression
  holds an intent and receipt before linearization, injects committed-unknown
  results, observes each exact transaction re-presentation before downstream
  work and proves two actual effects reusing one raw call ID dispatch exactly
  once each with distinct jobs/operations/public IDs. All six identity tests pass in 0.6 seconds current and 0.9 seconds floor. Together with the earlier historical
  literal-ID vectors, question cancellation, recovery/fault suites and the
  full candidate check on 35519cc9, this closes the duplicate T16 tracking row.

  /private/tmp/loopex-m7-prepared-range-current-v2.log, SHA-256
  `166762a40525531bb366e49bcf5d0a0ba4fadcf88ce61063573198841bd6e723`.
  /private/tmp/loopex-m7-prepared-range-floor-v1.log, SHA-256
  `17ac2abdc44a4d8272e30005029bd9dbf19db95f30695ffbde5beed4ebb83b87`.
  /private/tmp/loopex-m7-preparation-episode-cutoff-current-v2.log, SHA-256
  `9714c594654db58661dd2f8d3323f938622f7332266a0c4e1b2a10cd8ae1e714`.
  /private/tmp/loopex-m7-preparation-episode-cutoff-floor-v2.log, SHA-256
  `36136e639e32b7b1fcfd20dd4354480d29876df6ee656b7a59ec6c2177da1295`.
  /private/tmp/loopex-m7-prepared-range-core-current-v1.log, SHA-256
  `01d25dddcc622da906878bfcbabbf00c075524f6a4e85f2c52b83ba322e2021d`.
  /private/tmp/loopex-m7-prepared-range-core-floor-v1.log, SHA-256
  `ac635773e3c8f123601ec2604cafda60cc6049c5182d87231962eba9b76edcdc`.
  /private/tmp/loopex-m7-tool-identities-unknown-current-v1.log, SHA-256
  `1f07a5dd09eee8726fe71421bed4543ff80d2cdab18083c3fe277a06ca1e659e`.
  /private/tmp/loopex-m7-tool-identities-unknown-floor-v1.log, SHA-256
  `b12e750170b684c6d37dac45e0dff181c445dd2ba80cddfc6a994144311ceeb7`.
  /private/tmp/loopex-m7-prepared-range-gates-v1.log, SHA-256
  `3ac0ecf371fb4c92cf1aad148de23f3a573f266c1fa3bbcb9d9f8de31b1ff371`.

  Retained failed fixtures:
  /private/tmp/loopex-m7-prepared-range-current-v1.log, SHA-256
  `d524c2354da60df388f780c61bd74130bac07f2320437d6868038189fe871827`.
  /private/tmp/loopex-m7-preparation-episode-cutoff-current-v1.log, SHA-256
  `ac4449fd3ecae4440034b6bb346ce58038b45c5df9030348ab108bc7e8e74f48`.
  /private/tmp/loopex-m7-preparation-episode-cutoff-floor-v1.log, SHA-256
  `8126576856261a6e476df159bf2339738ed9764bf0abd62dfd43402b25cc604d`.

  Original tally: 49 done / 137 todo. Added tally: 138 done / 7 todo.
  T01, T02 and T09 are the fully completed original top-level tasks. The full
  current check on the preceding source candidate
  410911990c021dcd6fcfde33a635c158834bacde is running separately, output
  /private/tmp/loopex-m7-41091199-fast-check.log. Do not restart that run or claim
  it includes the new test-only child. Public chat/resume entrypoint integration,
  live compaction and wire contracts remain unfinished. No maintainer decision
  is pending. No paid provider call or publication was made.

- Done: the approved T02 early-spill context is implemented inside the existing
  digest/grant-bound JobRequest artifact policy. The closed revision-1 context
  captures the exact read binding or explicit nil and the Conversation
  run/turn-number/raw-call identity. Core reconstructs it independently during
  replay; substituted binding/identity and a search-generation downgrade refuse.
  No registry is needed after restart. Legacy jobs without this member keep
  their exact policy bytes and spill behavior, including retained read 1.1 jobs.
  Fresh search 1.1 jobs require context before effects. M7 chat captures the new
  generations; previous read/search defaults remain pinned to 1.0.

  New grep/find/ls 1.1 definitions change only version and artifact allowance
  (16,384 bytes, matching their unchanged capture ceiling). Their six old/new
  literal canonical-byte and digest vectors are in
  `apps/loopex/priv/vectors/search_projection.v1.json`. New digests are grep
  `b090c9a957fc7dc1f5aa6462465a473502c714e379a4aabcbec38d08ad1aaf0b`, find
  `4084b9a750df07ac0db537ffe6d5f72b82a44d18e329e68a82eb288a1e8eb45d`, ls
  `16f673afb8b7577ab6a8f69ec50eca12f38e42d1dc09f68fc00f0466bf508ba8`.
  The read 1.1 literal remains unchanged. For a non-nil frozen binding, the hand
  measures the full escaped JSON tool message and retains all captured bytes
  above 2,048 bytes before its receipt. Exact 2,048/2,049-byte boundaries and
  escaping below the raw capture limit are proved. Null capability and legacy
  jobs keep inline results; explicit ranges keep their existing bounded path.
  Retention reuses verified Core ArtifactStore.put and the five provenance
  labels. Dishonest answers expose no reference and preserve the effect outcome.

  The first real cancellation test exposed an unaddressable spill worker:
  cancel returned unconfirmed while the store was blocked. M7 retention now
  uses the existing job-alias guardian and joins its exact worker and guardian
  within the captured cancellation episode before settling/answering. Legacy
  routing stays unchanged. The fixed run cutoff also kills and joins the blocked
  worker before the truthful completed receipt without a reference. No timeout
  or assertion was weakened. Each new search reaches its original output bound
  through real Core/local executor/Store, retains every captured byte, survives
  empty-registry restart with an unchanged receipt and projects receipt-content
  provenance. An exact 16,384-byte read is retained and projected within the
  complete-message cap. Repeated exact dispatch reuses the receipt without
  another effect or artifact write. Existing range cases forbid fallback fetch.

  Focused outputs below all use warnings as errors. Final Core: 37 current cases
  in 3.1 seconds and 37 floor cases in 3.1 seconds. Executor current: 57 retention
  and conformance cases in 13.7 seconds; floor broader selection: 91 cases in
  44.8 seconds, followed by 12 final retention/vector cases in 1.4 seconds after
  adding the fixed-cutoff witness. Real composition: 17 current cases in 3.9
  seconds and 17 floor cases in 3.7 seconds. CLI selection/driver: 31 current
  cases in 15.0 seconds and 31 floor cases in 14.5 seconds. The current broader
  filesystem selection also passed 45 cases in 27.3 seconds, while explicitly
  reporting Darwin's raw-invalid-name witness unavailable; Linux proof remains
  required and no original aggregate test item closes on that unavailable case.

  /private/tmp/loopex-m7-early-spill-core-current-v4.log, SHA-256
  `4c7ec0dbcc9050aa92cd8047437ef693135160effef1ca1709b20e3b8a5a2f65`.
  /private/tmp/loopex-m7-early-spill-core-floor-v2.log, SHA-256
  `c86e9b98c8012f3305cab024a9a1283da9deb725e3e302119995acb118f731e2`.
  /private/tmp/loopex-m7-early-spill-executor-current-v5.log, SHA-256
  `30344fb0a31ac8aae3a370e3d0bc4b41874addd83dae38688c576f8b67e45aba`.
  /private/tmp/loopex-m7-early-spill-executor-floor-v1.log, SHA-256
  `19326462cac6cf5fc3daf5d8c70957022ee758157ba764fa202e8b86797420ef`.
  /private/tmp/loopex-m7-early-spill-executor-floor-v2.log, SHA-256
  `8af29785165d97862223516d99955006a809b7f0291347fbfd7b60401d4d1614`.
  /private/tmp/loopex-m7-early-spill-composition-current-v2.log, SHA-256
  `8df6806297402c8e8e4450e727d233d1a2e1317e17efcea508e87ba09bb14993`.
  /private/tmp/loopex-m7-early-spill-composition-floor-v1.log, SHA-256
  `b66f9f55a5543bbbee2be86c20db53587c8e7134a19baf06f0eadbbc32ac8c42`.
  /private/tmp/loopex-m7-early-spill-cli-current-v2.log, SHA-256
  `cf9ec501e30505137d332bd1427c4a5b222381b4500619f88f0e7ab8b19be746`.
  /private/tmp/loopex-m7-early-spill-cli-floor-v1.log, SHA-256
  `05dce9f76337fca8ff25f3523dc1bb57927f61183b579b73e0400dab21a93b6a`.
  /private/tmp/loopex-m7-early-spill-executor-current-v4.log, SHA-256
  `66e6d948111b5c5101eca8408934d4757e4ecbd2f9834411286f0fe392169918`.

  Failed drafts remain evidence. Executor current v2 reported 15/16 passed and
  exposed the real missing cancellation route, fixed above. Composition v1
  reported 15/17 passed: the initial 200-entry fixture did not fill ls/find output;
  300 entries now exercise the original bound without changing the assertion.
  Core v1 reported 9/10 passed because two calls in one reply were mistakenly
  expected in two turns; the fixture now expects the actual single turn.
  /private/tmp/loopex-m7-early-spill-executor-current-v2.log, SHA-256
  `c4f23ef61d3df6a2e2443589be71d98af9489f518594b45eae34e6397746f215`.
  /private/tmp/loopex-m7-early-spill-composition-current-v1.log, SHA-256
  `44aaf196f427320a3c22aea29c9c86da69bc2f810198c5de77011998f540740a`.
  /private/tmp/loopex-m7-early-spill-core-current-v1.log, SHA-256
  `920db59ab72f1f4e23e63461fa2ba9e86b88f0b299780c82119574d8968fba93`.
  Compilation v1 lacked sandbox TCP permission; v2 exposed ungrouped spill
  clauses; executor v1 had a fixture helper named binding/0 conflicting with
  Kernel. These attempts are not passes. The first CLI invocation incorrectly
  ran from the umbrella: only its actual CLI file set executed, with unavailable
  paths in other applications; evidence above uses the owning-directory run.
  The two early Core invocations named a nonexistent executor file and therefore
  prove only the ten actual artifact-admission cases, not executor conformance.

  Compilation, formatting, documentation ordering, dependency direction, status
  and diff gates pass. Complete output:
  `/private/tmp/loopex-m7-early-spill-final-gates-v3.log`, SHA-256
  `f0b428e62621733c67a5972fc325cafecd8512f458b7435e031c3516d12bf874`.
  The early-spill added subtask is complete. Original tally remains 44 done / 142
  todo; added tally is 136 done / 9 todo. Bounded preparation's combined remaining
  subtask, long-cutoff/Linux witnesses, independent clients, compatibility and
  milestone closure remain open. Run the full current fast check once on this
  committed integration candidate; focused proof does not replace it.

- Done: candidate `35519cc9c532a84c2fd8256bd9a3caf7d6e34621` passed its one
  full current-pair fast check in 1,386 seconds from a clean separate checkout.
  The exact SHA is retained in the complete output at
  `/private/tmp/loopex-m7-35519cc9-fast-check.log`; SHA-256
  `0d29feea7c5ae01515c53c83bcdf00172bd72b29969f7256ba9bb3c55f614d04`.
  All eleven credential-free application suites passed with warnings as errors.
  Existing lane exclusions remain unchanged; this is not release, paid-provider,
  old-reader/rollback or milestone-closure evidence. The added T12 repeated-tool-ID
  integration subtask is complete. Original tally remains 44 done / 142 todo;
  added tally is 135 done / 10 todo. The approved T02 early-spill implementation
  is in progress in the primary checkout and is not covered by this candidate.

- Implementation candidate: the approved repeated-tool-ID fix now writes
  `effect_intent_committed_v2`, `executor_receipt_committed_v2`,
  `tool_result_committed_v2`, `outcome_unknown_committed_v2`,
  `model_question_response_admitted_v2`, `model_question_settled_v2` and
  `model_question_abort_admitted_v2`. Payload members remain unchanged. The
  last kind applies only to an accepted abort cancelling an open model question;
  other aborts retain `command_admitted`. New started/finished IDs hash the
  deterministic ETF of `[namespace, session_id, {run_id, turn_id, raw_call_id}]`
  with the existing opaque-ID prefix/truncation recipe. Historical variants use
  their exact original raw-call recipe; replay selects from the retained kind.
  Newly constructed job and operation IDs bind turn/call within the run; already
  journaled jobs retain their exact old IDs and canonical bytes. This internal
  allocation choice prevents a second actual effect from colliding in the executor
  ledger. New non-receipt logical transaction IDs also bind turn/call, retaining the
  existing owner/head binding and exact unresolved proposal re-presentation.
  Effect-history scanning, drain-abort recognition and artifact provenance accept
  the explicit new variants without reinterpreting old records or granting work.
  Live Store fault seams and consumers now name the actual new writer kinds.
  Older readers refuse these unsupported variants; real old-reader and rollback
  witnesses remain T15 work, with no rewrite of retained history authorized.

  Fifty focused current Core cases pass with warnings as errors in 7.2 seconds.
  The final broader floor run passes all 277 total cases with its one existing
  exclusion in 144.1 seconds, also with warnings as errors. These suites pin
  literal new event IDs, repeated raw
  IDs across turns/runs, denied-question/effect continuation, repeated refusals,
  two answered questions reusing one raw ID, historical intent/receipt/refusal/
  answer/expiry/abort IDs, closed shapes and future-kind refusal, plus existing
  configuration/question unknown-commit and owner-loss proofs. Complete outputs:
  `/private/tmp/loopex-m7-tool-identities-core-current-v7.log`, SHA-256
  `0b5e913b4a71cfd5aee18f24fc4c15759315c83051d4c6b090e22150efb83506`;
  `/private/tmp/loopex-m7-tool-identities-core-floor-v5.log`, SHA-256
  `fc7763a7db369abb63b41ff66b568a49dc353bdf8d8d747d1ceaff4db81cb53f`.
  Thirty-three composition cases passed on both pairs in 17.1 seconds before the
  subsequent job-identity correction. The final composition results are retained
  below. Both include
  the original local-HTTP no-responder defect with the repeated provider ID
  restored, actual question restart and artifact-source admission. Complete outputs:
  `/private/tmp/loopex-m7-tool-identities-composition-current-v1.log`, SHA-256
  `355069bd491139936963611c88e089652f1c2f2e97d96387a8fef850bca50ca8`;
  `/private/tmp/loopex-m7-tool-identities-composition-floor-v1.log`, SHA-256
  `bac99bd6551c6ae9bc3ac4ad11111eb1c1d1ded19063e86985732b7866783730`.
  Thirteen current app-server mapping cases pass in 0.5 seconds, output
  `/private/tmp/loopex-m7-tool-identities-app-server-current.log`, SHA-256
  `37470e73fc314565c2cb1e47baa941ef29e22f96040c589af9c4124baccb437a`.

  The HTTP regression now repeats the same raw ID for two actual `ls` effects
  after the denied question. Before turn-bound job allocation, that executed case
  returned `cleanup_unproved`; output `/private/tmp/loopex-m7-repeated-real-job-current-v2.log`,
  SHA-256 `5299723b327ecabb5289f20b251ef36a4dc1e122bb36e184564a734292f0454e`.
  The earlier v1 name-filter invocation executed zero tests and is unavailable
  evidence, SHA-256 `b40fb6b464f6ae962d867aa9fe8c69fc3903276bd653140059a1ddd8b4b16a8c`.
  The final current composition suite passes 33 cases in 17.7 seconds, complete
  output `/private/tmp/loopex-m7-tool-identities-composition-current-v2.log`,
  SHA-256 `5d9e433a5304c989555fd066a84de4b837e677dda5c9d044dd47d3b5af09ea22`.
  The final floor suite passes 33 cases in 17.0 seconds; its complete output is
  `/private/tmp/loopex-m7-tool-identities-composition-floor-v2.log`, SHA-256
  `5ad481e540f2171af6eb7dfd622fa5371f9df6ddc936d637aca260fa46f20e57`.
  Current CLI receipt/workflow/coding-evidence tests pass 12 cases with two
  existing exclusions in 57.4 seconds, output
  `/private/tmp/loopex-m7-tool-identities-cli-current.log`, SHA-256
  `5f9347d6fab2b14cfc56d95e2a8e667e0475117dba69493a1ec69e9c76df9c94`.
  Eleven floor executor host-policy cases pass in 5.7 seconds, output
  `/private/tmp/loopex-m7-tool-identities-executor-floor.log`, SHA-256
  `a29ec55cf6afb73f2c9161696eccccb391b6fc88fdd461b6e655c551c134c02e`.
  These latter CLI/executor runs precede the final job-allocation correction;
  the committed candidate's full current suite checks their final integrated bytes.
  Final compilation, formatting, docs, dependency-direction, status and diff gates
  pass, output `/private/tmp/loopex-m7-tool-identities-final-gates.log`, SHA-256
  `eebc54f4531e448afe0c5034390b2162839713720b66aee3573a5bd8cb9e4066`.

  Failed drafts remain evidence. Current Core v1 invoked from the umbrella and
  is not credited. Current v2/floor v1 exposed the missing cancellation-parent
  kind; the new question-abort variant fixed that production path. Current v4
  and broader floor v3 exposed three synthetic historical-expiry fixtures adding
  private owner stamps to public events; the fixture now carries only the actual
  public event-sequence stamp. The broader floor run reported 276 total tests,
  three failures and one existing exclusion in 144.1 seconds; it is failed
  evidence, not a pass, and all three failed cases subsequently pass in the final
  focused set. No assertion or time bound was weakened. Retained failed outputs
  `/private/tmp/loopex-m7-tool-identities-core-current-v1.log`, SHA-256
  `37679c37fabeaf8dd4d0110b37f8ddf0e703b4d5077ec3644748fe4a0ed40ce2`;
  current v2 SHA-256 `b4954deeda8eb8ce2ca4ab7684694a7d68288f907b9620adee2e99789d56e830`;
  current v4 SHA-256 `a3f1f390c898f93235168f45daacebee1e271c736a1783cece7237199da8f128`;
  floor v1 SHA-256 `672001cd201a5b4f3d85689ebb53aea514bda6ea6c13968c3190d3e8ea90ae0f`;
  floor v3 SHA-256 `394d6dce2760437c1f859a29ed86511c118355a14842b3927f6b2e1418b54771`,
  under the same `<pair>-vN.log` naming. The full current integration check is
  pending on the committed candidate. One added T12 item tracks that completion;
  original tally remains 44 done / 142 remaining, added tally is 134 done / 11
  remaining. The approved early-spill contract is next.

- Done: the approved `Loopex.prepared_session_configuration/1` read routes through
  ResumeActivation to the serial owner's existing capability-holder/current-owner
  fence. It returns the exact four retained fields without activation, mutation
  or dispatch. Tests prove configured captures and immutable definitions after
  restart with an empty tool registry and changed defaults, legacy nils and grace,
  repeated read without spending, transfer and former-holder refusal, activation,
  abandonment, abort fencing, supersession, malformed input and an actual recovered
  pending prompt remaining paused. Public status still excludes instruction bytes.
  The complete returned capture also passes Store plain-data/65,536-byte
  admission before exposure. Forty-five affected cases pass with warnings as
  errors: current 6.9 seconds, floor 6.7 seconds. Complete outputs:
  `/private/tmp/loopex-m7-prepared-read-current-v4.log`, SHA-256
  `e2e0f6dfa439ebc12fa212f3c978f6c398c610eb5eccb907019cf8e711604ede`;
  `/private/tmp/loopex-m7-prepared-read-floor-v4.log`, SHA-256
  `d68bf756cc076f774725ecd9554ededa3dd8a2b225ac4c92164695ea2ff180d1`.
  Compilation, formatting, documentation, dependency direction, status and diff
  gates pass; complete output `/private/tmp/loopex-m7-prepared-read-final-gates.log`,
  SHA-256 `e94ef0d5c1628a81103feb85e7360d04c6e9113bd19d545ff3b901d6e4a56ffa`.
  Failed fixture drafts remain under `/private/tmp/loopex-m7-prepared-read-<pair>-v1.log`
  and `-v2.log`. V1 used the wrong update arity and expected an idle abort to admit
  rather than refuse while fencing; V2 held a v2 prompt kind for a v3 session.
  Production validation and time bounds were unchanged. Their SHA-256 digests are
  current v1 `588a460de37218ab6acf1c1b873d9f2ad3bc501211e18a09b6c0a63b6d858388`,
  floor v1 `9e828ceb8b9c9089c0f1b01e2b0ba31fccde0b29dd621947b31db15717fc8bb3`,
  current v2 `99b77b37eba27fc2fe10887521f1a35bca94bbbca4aa1aab464dfb25105d43c7`,
  floor v2 `336cccb4374779af614061d70c7c001a2391f60af232bc8843ec2374c05f6aee`.
  One added T06 item closes. Original tally remains 44 done / 142 remaining;
  added tally is 134 done / 10 remaining. Built-command resume remains open.
  The preceding workspace proof's formatting/docs/status gates are retained at
  `/private/tmp/loopex-m7-workspace-proof-gates.log`, SHA-256
  `75cefbf9338a87b5318d6c5ddd5dbe95ae26bed6fcc50cc26360fb624cc4f398`.

- Maintainer decisions, 2026-10-02: the maintainer answered "1. approverd.
  2. approved. 3. approved." to the three pending recommendations. Implementation
  is authorized for the capability-scoped public prepared-resume read, versioned
  tool-event identity records and the digest-bound early-spill projection context.
  The prepared read returns exactly `{configuration, tool_selection,
  policy_defer_mode, cleanup_grace_ms}` from retained state under the unspent
  capability's current holder and owner fence, with legacy nils unchanged and no
  activation, mutation or dispatch. Its packet is retained at
  `/private/tmp/loopex-m7-prepared-configuration-read-decision.md`, SHA-256
  `613b7ddf96697140d56f6a846d59809f5fe2d6f802615ca273d50ae05dbec209`.
  New effect-intent, executor-receipt and non-receipt tool-terminal record variants
  derive tool event IDs from session/run/turn/call identity; historical variants
  retain their original IDs and public member sets remain unchanged. Packet:
  `/private/tmp/loopex-m7-tool-event-identity-decision.md`, SHA-256
  `4d4751b0092731e0d79b8e06abacfac6119bfec36b61b60f438f92a4406f17dd`.
  Projection-aware read/search jobs retain the existing ordered JobRequest outer
  contract and digest-bind `artifact_policy.projection` with exactly `revision: 1`,
  `artifact_read: null | <frozen four-member binding>` and `normalized_call_id:
  "lx_<48 lowercase hex>"`. Core reconstructs these from retained selection and
  lineage, executors validate before effects, and legacy jobs keep exact bytes
  and spill behavior. New search generations capture at most 16,384 bytes and
  retain complete output when the encoded message exceeds 2,048 bytes with a
  non-null read binding. Packet:
  `/private/tmp/loopex-m7-early-spill-decision.md`, SHA-256
  `d8bcadf912294f9fbed7f265a9139cacd18565dbfdd58ff77150bf84f1efbadb`.
  Old readers refuse unsupported variants/generations; migration rewrites no
  retained job, receipt or event. These decisions supersede the pending labels
  in the earlier progress entries below. Closure, merge, tag and publication
  remain separate decisions.

- Done: the original T03 workspace/environment and selected-schema item now has
  a live staging proof for all three immutable tool profiles: none, coding and
  read-only. Prepared host facts include the exact workspace, platform and
  selected profile; the actual Core-dispatched request contains the exact
  rendered instructions and every selected definition, matching retained v3
  genesis. No executor job or credential reference enters the instructions.
  Sixty-four affected chat cases pass with warnings as errors on both toolchains:
  current 21.3 seconds, floor 21.2 seconds. Complete outputs:
  `/private/tmp/loopex-m7-chat-workspace-capture-current-v1.log`, SHA-256
  `76e3442e8aa70e72b5466fb6459a574323be65dc5fdfafa8055a1d8cd0a20607`;
  `/private/tmp/loopex-m7-chat-workspace-capture-floor-v1.log`, SHA-256
  `f067a2be04be07fa181498071a93df8d27892e0015199d06dc84ce87cd428ce8`.
  This uses a model-boundary fixture; real-provider and built-command proofs
  remain separate open items. Original tally is 44 done / 142 remaining;
  added tally remains 133 done / 11 remaining.

- Done: one added T00 subtask supplies `python3 scripts/m7-task-status.py`
  for repeatable task reports from the canonical checkbox sections. It prints
  every T00–T19 row, counts original and added work separately, ignores
  historical status prose and refuses duplicate/missing task headings, empty
  original sections or a changed 186-item original denominator. The path is
  anchored to the script, so invocation outside the repository reports the
  same ledger. Current original tally is 43 done / 143 remaining; added tally
  is 133 done / 11 remaining. This changes task reporting, not a product proof.
  The actual report is retained at `/private/tmp/loopex-m7-task-status-final-report.log`,
  SHA-256 `7ca35f6ea8eb8114739c90a7c6a5cd751052329299ce5f7a70a0f114b0718604`.
  Structure/status and formatting pass; output
  `/private/tmp/loopex-m7-task-status-gates.log`, SHA-256
  `2bde8a90a81179a725541af673d41ae58ba2fe7412c7c71baabe135c933638c4`.

- Pending maintainer choice: prepared chat recovery needs the exact retained
  configuration and immutable definitions, while existing status deliberately
  exposes only safe configuration values and instruction version/digest.
  Recommend `Loopex.prepared_session_configuration(activation)` returning the
  closed local four-member map `{configuration, tool_selection,
  policy_defer_mode, cleanup_grace_ms}` under the current unspent capability's
  holder and current-owner fence. Configuration/selection remain nil for legacy
  v2, never current defaults. The read neither spends the capability nor commits,
  activates or dispatches. It exposes captured instruction bytes to the trusted
  holder, with no credential, private continuation or runtime handle, and keeps
  existing status/wire allowlists unchanged. Transfer, abandonment, activation,
  abort and supersession enforce the existing capability refusals. The alternate
  choice authorizes a private Runtime read and its host-boundary exception.
  No dependent implementation has started. Concrete packet:
  `/private/tmp/loopex-m7-prepared-configuration-read-decision.md`, SHA-256
  `613b7ddf96697140d56f6a846d59809f5fe2d6f802615ca273d50ae05dbec209`.
  One added T06 subtask is now pending. Original tally is 43 done / 143
  remaining; added tally is 132 done / 11 remaining. Earlier event-identity
  and early-spill decisions remain pending independently.

- Done: audit closes the first original T08 item, committed per-run
  model/reasoning configuration and all six permitted configure fields. The
  existing live owner tests prove distinct models before/after configure,
  retained per-run configurations, restart, exact duplicate dispositions and
  commit-boundary faults through the approved facade. The chat workflow now
  admits all six fields together, proves default reasoning omission then exact
  `none`/thinking-disabled sampling, canonical model alias, changed instruction
  bytes, all three effective ceilings and safe instruction-digest inspection.
  Raw instruction content is absent from the transcript. Sixty-three affected
  chat cases pass with warnings as errors on both toolchains: current 19.1
  seconds, floor 19.0 seconds. Complete outputs:
  `/private/tmp/loopex-m7-chat-configure-all-fields-current-v1.log`, SHA-256
  `1573645a3bcf55dda3386cedf19376d169faf14132d909e4b240754750b8c7b3`;
  `/private/tmp/loopex-m7-chat-configure-all-fields-floor-v1.log`, SHA-256
  `a69b2da44c33d7987489720ac3affd7e942803313dc5d545ffbcea0037b9739a`.
  Original checklist is 43 done / 143 remaining; added subtasks remain
  132 done / 10 remaining. This closes the local configuration item; daemon
  admission, protocol generations, live thinking-round witnesses and maintenance
  checkpoint joins keep their own original items open.

- Integration check: exact `66aef0e19b031e9ff12aa6ee339b6c73d13640d4`
  passed the full current-pair fast check in 907 seconds. All eleven application
  suites and preliminary gates passed; CLI passed 478 cases with its six
  existing exclusions. Complete output:
  `/private/tmp/loopex-m7-66aef0e1-fast-check.log`, SHA-256
  `6ceed4ac9d04603a2ed2618b3893e9a5f6b02b1bc7dd526d0b85e1de25b8fde3`.
  This includes host configure preparation, live busy/history refusal and exact
  unknown observation. It predates the later all-six-field test extension and
  read-only task reporter. No floor closure matrix or release check has run.
  Earlier provider-deadline flake and supervisor diagnostics remain retained;
  this later pass does not erase those observations. No check process is running.

- Done: one added T08 subtask joins host configure preparation to the private
  chat driver's command holder through the approved public facade. Closed
  updates resolve only admitted provider routes and the immutable definitions;
  canonical model aliases, explicit ceilings and derived budgets share the
  existing creation/update validators. The holder advances its cache only on
  the exact accepted command identity. Invalid preparation, busy-owner and
  retained-history refusals leave it unchanged. Unknown admission observes its
  exact identity, issues no second configure and leaves the next input unread.
  Two real model requests prove the before/after reply allowance; the busy and
  history cases prove a later valid update still advances exactly one version.
  Sixty-three affected chat cases pass with warnings as errors on both pairs:
  current 19.1 seconds, floor 18.9 seconds. Complete outputs:
  `/private/tmp/loopex-m7-chat-configure-current-v3.log`, SHA-256
  `78753de458f4cfcbf40e0019774d045204dee16ff0b2cde73b240f7a77d90a88`;
  `/private/tmp/loopex-m7-chat-configure-floor-v3.log`, SHA-256
  `f97d9b905597d9c4a58a42add3e01a1877933cdded58b62c93ecb5e880a87d28`.
  Initial draft tests refused exact creation because the scripted runtime named
  `scripted:v1` while genesis selected the canonical Anthropic model. The fixture
  now accepts an explicit model and retains its original default; production
  exact-selection validation is unchanged. Failed outputs remain retained:
  current v1 SHA-256 `5a1c4cc0568177e277b347eb6f81b2b2898ff9b5f81cf0a97f5244892ed91908`;
  floor v1 SHA-256 `3d947b30c26bee0202e6c66a4b2883c6a3bda252611be4a00ff4499b2e0d21bb`,
  both under `/private/tmp/loopex-m7-chat-configure-<pair>-v1.log`.
  The existing configured-session suite also passes 37 cases with warnings as
  errors after the fixture change: current 6.7 seconds, floor 6.5 seconds.
  Complete outputs `/private/tmp/loopex-m7-chat-configure-core-current.log`,
  SHA-256 `3ca322515f601eebee4ba2823922349eddc805db66e27166beb7d2966b67abb2`,
  and `/private/tmp/loopex-m7-chat-configure-core-floor.log`, SHA-256
  `1736330c0130ca6659f21eeea049c15e9f96a42c3cefd33c77ddd550645a8b95`.
  Compilation, formatting, documentation, dependency direction and status gates
  pass; complete output `/private/tmp/loopex-m7-chat-configure-gates.log`, SHA-256
  `97bc95dd43792fb6f4e76d10989b2af0bdc24822e79857b5f046c87860bf3327`.
  Original checklist remains 42 done / 144 remaining; added subtasks are
  132 done / 10 remaining. The public chat command, prepared recovery,
  daemon configure, checkpoints and maintenance quiescence remain open.

- Done: the private chat driver captures already validated invocation run bounds
  once and adds them only to fresh prompts. Queued follow-ups use Core's inherited
  ordinary limits; steer and answers receive no bound override. A real owner
  scenario holds both the initial and promoted model calls, checks exact
  41-digit turn/token limits and each dispatched absolute cutoff through public
  status, and proves the wait barrier leaves quit unread until both runs finish.
  This extends the completed T06 driver subtask; no new checkbox credit.
  Thirteen driver cases pass with warnings as errors on both toolchains:
  current 1.0 seconds, floor 0.8 seconds. Complete outputs:
  `/private/tmp/loopex-m7-chat-driver-bounds-current.log`, SHA-256
  `66c9d248eddf7e1ffaec3d9f839f7d61a9166f7976c3037aa1182ba8bcdc23dc`;
  `/private/tmp/loopex-m7-chat-driver-bounds-floor.log`, SHA-256
  `8d58972290e378a7140fe255d84128fe9e546f27b53ba152d9e90fb3e4878d61`.

- Done: the maintainer approved the public prepared configure method on
  2026-10-02. `Loopex.command_with_configuration/3` forwards the separate
  authored command and resolved candidate through the existing attachment
  route to the sole serial owner. It performs no catalog or credential effects.
  All eighteen live configure calls now use that facade, preserving admission,
  changed-candidate duplicate replay, identity conflicts, unchanged refusals,
  unknown commits and restart recovery. A malformed-boundary case proves no
  journal mutation or model/executor work. Thirty-seven configured-session
  cases pass with warnings as errors on both toolchains: current 6.8 seconds,
  floor 6.6 seconds. Complete outputs:
  `/private/tmp/loopex-m7-configure-facade-current.log`, SHA-256
  `6456a0a68016ac5de608f056d4129d2717cac9ece652ba8ee8bd0026f2b3e099`;
  `/private/tmp/loopex-m7-configure-facade-floor.log`, SHA-256
  `244564569dce0a7744725f8a13ac4843935cc07bc09559e610906179cb61aa74`.
  The approved packet is `/private/tmp/loopex-m7-configure-facade-decision.md`,
  SHA-256 `4f7cf31054776c3afb9cf52b159d25bb3f893a91a9666345618889cb1eb4f3e0`.
  This closes one added T04 subtask. Original checklist remains 42 done / 144
  remaining; added subtasks are 131 done / 10 remaining. Host resolution,
  daemon routing and maintenance/checkpoint joins remain open. The earlier
  event-identity and early-spill choices remain pending separately.

- Integration check: exact `462c3ccad69ff245303d53e9af9dd6cd7beba29a`
  passed the full current-pair fast check in 907 seconds. All eleven application
  suites and preliminary gates passed. Complete output:
  `/private/tmp/loopex-m7-462c3cca-fast-check.log`, SHA-256
  `2b2fd9514cdc5c68a341d535d6e51a7fa1db8dc2e6879c2adf7fc64e88e40380`.
  This includes the driver and IO-owner fixture correction, but predates the
  invocation-bound extension and public configure method. No floor closure
  matrix or release check has run.

- Integration check: exact `5a21442a9a984b2338d33e3610f5bc68ab93c2dd`
  passed the full current-pair fast check in 907 seconds. All eleven application
  suites and preliminary gates passed. Complete output:
  `/private/tmp/loopex-m7-5a21442a-fast-check.log`, SHA-256
  `0470c967bf82851dcf108a047cb324f1d739e19d753e9121c2c82fdaf0348187`.
  This proves the committed active-bound status and fixture warning repair;
  it does not include the later chat driver. No floor closure matrix or release
  check has run. The earlier provider deadline flake and Task.Supervisor
  diagnostic remain unresolved observations.

- Done: one added T06 subtask connects the prepared chat input/output/control
  primitives to an already created live Core session. The private driver owns
  separate command/event attachment workers, a single-line input worker and
  the bounded output manager. One event grant and one pending command bound
  retained messages. Input admission is printed before its caused output.
  Wait drains through the owner's observed committed cursor before reporting
  settled/question; it leaves subsequent pipe input unread while work is active.
  Questions retain the actual opaque identity and exact whitespace-bearing
  answer. Quit, EOF and host interrupt share one captured committed cleanup
  backstop. Unknown admission is observed by exact ID without retry or a
  competing abort; second interrupt stops waiting, reports unknown cleanup and
  retains any outstanding worker monitors in the private driver. Confirmed
  local results require every owned worker DOWN. The outer host must supply its
  separate composition/credential cleanup proof before closing. Unconfirmed
  local cleanup cannot be overwritten by a confirmed outer result.

  The driver also distinguishes pipe syntax/state refusal, which stops input
  and exits nonzero, from interactive refusal, which leaves the conversation
  usable. Core events remain durable authority. Lost attachment holders and
  broken output return fixed failures; formatting of process status excludes
  private input and output. The accepted uncertainty branch now permits a known
  foreground run alongside an unresolved command, as ADR 0049 already requires.
  Startup/composition/trace/signal installation, public `chat` dispatch, status,
  configure/compact joins, prepared resume, TTY presentation, built-command
  restart and paid/attended proofs remain pending. No original item closes.
  Original checklist remains 42 done / 144 remaining; added subtasks are now
  130 done / 10 remaining. T01 and T09 remain the only complete original tasks.

  Focused verification runs warnings as errors over all four chat transport
  files: 45 cases, current 6.0 seconds and floor 5.7 seconds. Complete outputs:

  - `/private/tmp/loopex-m7-chat-driver-current-v9.log`, SHA-256
    `6aeb88c1f8f46462e0396e176b7900df4f0628e028dd228818b67de4943e9fe6`.
  - `/private/tmp/loopex-m7-chat-driver-floor-v2.log`, SHA-256
    `6d5404129d31c2eb96bac345ccc6ad70c2cfebee2cc006833920be0a9aff25c7`.

  Failed drafts remain retained, not successful evidence. The first compile
  caught an unreachable stopping-input clause, removed because caller admission
  already excludes that state. The first fixture run caught an unused alias,
  an initially inadequate caller-loss scenario and a system-message position
  assumption. Later tests caught a lost command holder still waiting for its
  cutoff and pipe syntax refusal reading the next line; both changed source
  before verification. A final existing output-worker test exposed a disposable
  IO relay peer mistaken for the linked worker. All such fixtures now capture
  the manager-owned worker before inducing failure, preserving the actual
  linked-worker death assertions and their original waits. That repairs the
  already completed output ownership proof, with no new task-count credit.

  | Failed draft | Complete output | SHA-256 |
  | --- | --- | --- |
  | Compile warning | `/private/tmp/loopex-m7-chat-driver-compile-v1.log` | `e26060acae99a175b781355ec9bed8a9e8cc744996a1245272182a5ee7e27205` |
  | First fixtures | `/private/tmp/loopex-m7-chat-driver-current-v1.log` | `0b5f9c75aab5c1ba5af3784319c019af51b212550c6f48348645b42131134e4d` |
  | Command-holder loss | `/private/tmp/loopex-m7-chat-driver-current-v6.log` | `f2fe4175ce71f1fa7d74233916162fe8596eefadf786c7ec998b7b90c5dc2584` |
  | Pipe refusal | `/private/tmp/loopex-m7-chat-driver-current-v7.log` | `045d16a86e4e1c5639de5c1121155fb2891c20963ae48e2f8d5ab47a7cc18cc7` |
  | IO peer mistaken for worker | `/private/tmp/loopex-m7-chat-driver-current-v8.log` | `dbbae42d9721a65ab7b3a8e203172d2b1895e224a0dd8ca097b251810f8dc51b` |

- Prior integration failure: exact `6750f9220da572c97e309e488a228b7a05bc17c4`
  exited 1. Preliminary gates passed; all application test assertions passed,
  but Core's `--warnings-as-errors` lane refused two compiler type warnings in
  the new parameterized frozen-resource fixture. Core passed 922 cases with
  five exclusions in 229.2 seconds; its command then aborted because each
  expanded test compared a statically fixed atom to the other boundary atom.
  Ten other suites were green. This candidate remains failed evidence, despite
  its successful assertions. Complete output:
  `/private/tmp/loopex-m7-6750f922-fast-check.log`, SHA-256
  `62110f8a991b9d806cc5dbc090cd16d30b57121bf9b05bdaa0ea29916e788103`.
  The earlier provider deadline flake and Task.Supervisor diagnostic remain
  separate unresolved observations; this failure is the fixture compiler warning.

- Done: the T08 fixture retains both named boundary tests and every original
  assertion, with their shared body in a private helper receiving the boundary
  at runtime. This removes the disjoint literal comparisons through ordinary
  function structure, with no warning suppression, skipped case or changed
  wait. Focused verification now explicitly uses `mix test --warnings-as-errors`.
  Both toolchains pass all 36 configured-session cases and 14 historical mapping
  cases: 6.5/0.8 seconds current and 6.6/0.8 seconds floor. These runs include
  the new active-bound status proof below. Counts remain original 42 done / 144
  remaining and added 129 done / 10 remaining. Complete outputs:
  `/private/tmp/loopex-m7-status-resource-warning-current-20261002.log`, SHA-256
  `c570d88858bf3f65c5960adb53164da04ed1db82b41cd1ca6e5f292714f6462d`;
  `/private/tmp/loopex-m7-status-resource-warning-floor-20261002.log`, SHA-256
  `16ba16dc2d74b87e18d128094eaf5e37186d7f164906545cd38ca6c98a2b7379`.
  The preceding focused logs retain successful assertions plus these warnings;
  they are not warning-free test evidence.

- Done: the existing local status view also exposes `active_bounds`, a closed
  projection of the active run's committed max_turns, token_budget, relative
  deadline_ms and staged absolute deadline. Settled status is null; before
  staging the absolute member is null. Projection reads the existing reducer
  accounting view without clocks or current runtime defaults, and does not
  substitute charged usage for declared limits. A real gated executor run
  verifies 41-digit turn/token limits and the exact dispatched request cutoff,
  then confirms null after completion. Both complete configured-session and
  historical wire-mapping suites pass 50 cases: 6.9/0.9 seconds current and
  6.7/0.8 seconds floor. The historical wire allowlist remains unchanged.
  This extends the already completed added T06 status subtask; counts remain
  original 42 done / 144 remaining, added 129 done / 10 remaining. The authored
  `deadline_at_ms` command/record integration remains pending; this change does
  not claim that feature or the live chat driver complete.
  Complete outputs:
  `/private/tmp/loopex-m7-active-bound-status-current-20261002.log`, SHA-256
  `86f8375d2152bd845735c72d5c4b7397755c76b3081893ef71332a2effff816c`;
  `/private/tmp/loopex-m7-active-bound-status-floor-20261002.log`, SHA-256
  `75071ec61227c3054a6c5fc534d9d453a11b24d0ddad827f358c450d50b2ad56`.

- Done: M7's accepted configuration-inspection allowlist is now exposed through
  the existing local `session_status` facade as `configuration`, read from the
  sole owner's committed reducer state. It contains exactly version, model,
  reasoning, reply/context/system ceilings and instruction version/digest.
  Instruction bytes, model capabilities and provider mappings stay private.
  Legacy unresolved configuration is nil rather than adopting host defaults.
  Live tests inspect initial genesis, an atomic configured version and recovery
  under different launch defaults; private instruction canaries remain absent.
  The historical foreground mapping still selects its old exact allowlist;
  no new field is emitted before the complete M7 generation switch. Authority is
  the accepted M7 technical plan's Configuration records row, implemented through
  `SessionConfiguration.public_view`, with no new facade operation or authority.
  Both toolchains pass 35 configured-session cases and 14 historical mapping
  cases: 6.8 and 0.8 seconds current, 6.6 and 0.8 seconds floor. This completes
  one added T06 subtask, no original item. Original: 42 done / 144 remaining.
  Added: 129 done / 10 remaining. Live chat status construction and startup/
  command/cleanup integration remain open.
  Complete retained outputs:
  `/private/tmp/loopex-m7-configuration-status-core-current-20261002.log`, SHA-256
  `92bd5bf6355ec083905f596f497d948a38adcbe7b8fc107272bf993488f5d353`;
  `/private/tmp/loopex-m7-configuration-status-wire-current-20261002.log`, SHA-256
  `8be14d08d77b6f9d47ed3a87d7ee9bf39bc1e0050fe68e8c319328acf8b26883`;
  `/private/tmp/loopex-m7-configuration-status-floor-20261002.log`, SHA-256
  `f5507a22e91077e25b1b470e2e0b2bad3c76e871ec539db25f3f41b79545b54f`.

- Done: T08's frozen resource-pack/steer continuation proof covers both live
  continuation and a real owner kill/restart after the executor receipt has
  committed. An admitted skill and selected supporting file appear as exact
  bytes in the first request. The executor's existing progress gate holds the
  tool while steer admission commits; the next request preserves the entire
  first prefix and appends assistant, required tool result, then exactly one
  steer. Continuation positions retain the native call ID and original base
  request digest. Both resource receipt headers match exactly, the first staged
  request has no applied steer and the second names the admitted steer. The
  successor receives only the same Store, no original resource manifest, and
  dispatches no duplicate executor job. Pure replay validates the complete
  retained private/public history. No runtime code changed.
  Both complete configured-session suites pass 34 cases, in 6.8 seconds current
  and 6.6 seconds floor. Complete outputs:
  `/private/tmp/loopex-m7-frozen-resource-steer-current-v3-20261002.log`, SHA-256
  `00dcf4d95494f2589d738d1c9a81afe7f6819c91e08c0282d4f01db6733eec56`;
  `/private/tmp/loopex-m7-frozen-resource-steer-floor-v3-20261002.log`, SHA-256
  `d49147774c411fd5a920aec2c8e56dc14c9919ce01b7a05920b320616e8606c7`.
  This completes one added T08 subtask, no original item. Original: 42 done /
  144 remaining. Added: 128 done / 10 remaining.
  Two failed drafts remain retained: the first used a nonexistent one-argument
  status facade; the second inspected the ordinary rather than resource-specific
  staging record kind. Both were corrected to the actual existing contracts,
  preserving every prefix, position, receipt and restart assertion.
  Current first draft `/private/tmp/loopex-m7-frozen-resource-steer-current-20261002.log`,
  SHA-256 `ca7e473c6e163099ca4009ce62e68abee614d9a07e65c9340c414598756d7e95`;
  floor first draft `/private/tmp/loopex-m7-frozen-resource-steer-floor-20261002.log`,
  SHA-256 `469f0a49eb85e8d46192752df5aff30c72862d27f76db9970ab1a0b4b9979aaf`;
  current second draft `/private/tmp/loopex-m7-frozen-resource-steer-current-v2-20261002.log`,
  SHA-256 `d6f22bfefa7b3b958ff038cc7b7c8e7405ec6848bfd99b25046d7f8f7ca73271`;
  floor second draft `/private/tmp/loopex-m7-frozen-resource-steer-floor-v2-20261002.log`,
  SHA-256 `939664f39f0ffd7dd9313d5bad25e1595c2010f240fd3ef694370c382cd6180b`.

- Done: the full fast check passed once on exact
  `385cf8cf84a4603f797191b823a84dd409a0b1ec` in 906 seconds, including
  composition's diagnostic dispatch fixture. All eleven application suites
  passed. Complete output: `/private/tmp/loopex-m7-385cf8cf-fast-check.log`,
  SHA-256 `0c58d9468c3beabdcc33b3d04cdf50d76ed4a4b1a58bb1902375c873d2f5c43b`.
  This is current-pair integration evidence for that exact candidate. The prior
  failed candidates remain failed evidence; the provider-launcher deadline flake
  and unrelated Task.Supervisor diagnostic still need causal investigation.

- Done: the approved T10 terminal codec, closed wait/closing constructors and
  independent payload vectors preserve run-only outcomes, exact null/host
  uncertainty branches, arbitrary ordinary turn/token quantities, u64 deadline/
  cleanup quantities and opaque reconciliation bytes. The codec adds no Core
  mutation or stored-data migration. Closing refuses a zero exit with unknown
  cleanup or an unsuccessful last run; a successful last run can still carry
  nonzero exit for prior failure. Native preflight failures expand only their
  known null fields. Existing ask JSON and event bytes remain unchanged.
  Both toolchains pass 11 protocol cases including the independent Node lane
  and 37 CLI cases. Protocol takes 0.07 seconds on each pair; CLI takes
  5.6 seconds current and 5.4 seconds floor. The same 64 literal terminal
  vectors run in both languages. Presentation tests retain an exactly
  65,536-byte closing record, refuse one extra byte and oversized legacy opaque
  references without truncation, and drain input/question/wait/closing bytes
  unchanged through the actual output writer. Complete retained outputs:
  `/private/tmp/loopex-m7-chat-terminal-protocol-current-20261002.log`, SHA-256
  `0a0bed7d0e79632bdd808b00ceae9b099a88f0a0a90e7220ed5e3c0ba19f1143`;
  `/private/tmp/loopex-m7-chat-terminal-cli-current-20261002.log`, SHA-256
  `8010fdcca935e93bac98490f9d15a62b25cd510b0b5ad41cedbd12cee7f89441`;
  `/private/tmp/loopex-m7-chat-terminal-floor-20261002.log`, SHA-256
  `bb9b07552c19d2fc84dee88c87f1a22e510563bce253427a917109ec994d9c9c`.
  Warning-free compilation, formatting, documentation, dependency and status
  gates passed. This completes one added T10 subtask, no original item.
  Status construction and the live chat driver remain in the original checklist.
  Original: 42 done / 144 remaining. Added: 127 done / 11 remaining.

- Integration check: exact 7d10f9f6941c105e3cd15ee21e03d4ba484f4f67
  completed with exit 1. Preliminary gates and ten application suites passed;
  composition passed 466 cases with one exclusion and failed the initial
  diagnostic blocked-device receive described below. Its full suite lasted
  208 seconds. Core passed 919 cases, ReqLLM 385, executor 268, CLI 455,
  daemon 458, app server 98, protocol 78, reference client 20, local store 91
  and telemetry 8. This is failed integration evidence, including the successful
  responder cases. The earlier provider-launcher deadline flake and unrelated
  Task.Supervisor diagnostic remain unresolved; this run does not erase them.
  Complete output: `/private/tmp/loopex-m7-7d10f9f6-fast-check.log`, SHA-256
  `504b349eebc0a9962d5b3f0a94bf2782698968246764bcb979af764803ec46e3`.

- Done: T16's diagnostic pressure fixture confirms actual writer dispatch through
  the existing owner-only status call before its unchanged implicit 100-ms
  device receive. Same-sender ordering places that observation after diagnostic
  rendering/registration. Pressure assertions, exact kind accounting, 1,000-ms
  cleanup grace, existing waits and asynchronous execution remain unchanged.
  Thirteen cases pass in 0.7 seconds on each supported pair.
  `/private/tmp/loopex-m7-diagnostic-dispatch-current-20261002.log`, SHA-256
  `ea6ad7aae7790d6e0c9a04286dd85ca5a5ceac8ac03c72dec8449bc9d403e976`;
  `/private/tmp/loopex-m7-diagnostic-dispatch-floor-20261002.log`, SHA-256
  `d51543a587eb5c4f0ccb43f2c8998189e6c8d25e4a9b9b536718b5b0a8349c0b`.
  This follows the failed initial device wait in the committed 7d10f9f6 full
  check. That candidate remains failed evidence; the new fixture bytes require
  their own committed integration check. Original: 42 done / 144 remaining.
  Added: 126 done / 12 remaining, including the pending T10 schema choice below.

<a id="decision-m7-chat-terminal-outcome-2026-10-02"></a>
- Maintainer decision, 2026-10-02: approved the terminal-only chat object,
  shared codec and independent vectors, preserving existing ask/event bytes.
  The accepted new chat object
  is exactly `{outcome, details}`. Completed/cancelled details are exactly
  `{cleanup_grace_ms}`; failed details `{reason, failure, cleanup_grace_ms}`
  preserve the existing public reason/structured-failure alternatives;
  bound_reached details are `{bound, observed, declared_limit, accounting_source,
  cleanup_grace_ms}`; outcome_unknown details are `{reconciliation_ref,
  cleanup_grace_ms}`. Quantities retain canonical decimal encodings and their
  existing Core domains, including non-u64 ordinary turn/token bounds. The
  reconciliation reference keeps opaque protocol identity encoding. There are
  no text/tool/profile/identity duplicates or host cleanup facts inside the
  terminal object. No_ending is excluded; null and the accepted uncertain-wait
  host literals keep their meanings. ADR 0049's pair records this approved
  amendment without rewriting its original acceptance history. Exact approved
  packet: `/private/tmp/loopex-m7-chat-outcome-decision.md`, SHA-256
  `3faa03f1b4167e53e6b612e7f900def682e63ba7cf3e402e785014b30a1a43f9`.
  The human response was: "Approve terminal-only object (recommended; compact
  records, new shared codec and vectors, existing ask unchanged)". The shared
  codec, terminal wait/closing constructors and independent vectors are now
  implemented and pass focused verification above.

- Done: T12 one-call responder integration consumes the unary callback before
  startup, rejects disabled/non-unary/duplicate selections, and retains reusable
  startup and per-call grammar. One temporary private-supervisor child is
  registered and monitored before its exact grant. The owner observes committed
  events through its existing single reader while the callback runs. Exact
  worker DOWN, current interaction and runtime generation precede answers through
  the existing validation/mutation slot. One captured call cutoff spans every
  question; Core expiry remains a committed run outcome. Invalid/raised/thrown/
  exited callbacks trigger ordinary abort and mandatory cleanup. Expiry, caller
  death and stop kill the exact worker; a fixed existing-grace join cutoff retains
  cleanup uncertainty even if later teardown completes. Stale response identities,
  forged DOWN while alive, serial joins, maximum text, choice, decline, blocked
  work, run expiry, caller death, policy deferral, root-removal uncertainty and
  missed join cutoffs have actual owner/Core/local-HTTP witnesses. The selected
  six files pass 73 cases in 42.0 seconds current and 42.1 seconds floor.
  No attended/provider or closure result is claimed.
  `/private/tmp/loopex-m7-responder-live-current-verified-20261002.log`, SHA-256
  `d301ae4e55d8937625051363089d157c2436aeedca8e8535ad6826c77c809379`;
  `/private/tmp/loopex-m7-responder-live-floor-verified-20261002.log`, SHA-256
  `5ddb16297cfd79892a2066f47e2ad5d7bcf1d79dbd1aa836ecbcad23930f7580`.
  The draft join-refusal branch incorrectly read a startup-only root field after
  readiness. It now uses the retained owned-root identity. Failed current/floor
  outputs are `/private/tmp/loopex-m7-responder-live-current-join-failed-20261002.log`,
  SHA-256 `99f4671e0072701ddc690593f246cc8de3ca92eaef2d03bcc1c22c91bca87a14`,
  and `/private/tmp/loopex-m7-responder-live-floor-join-failed-20261002.log`,
  SHA-256 `34ba8850122bb2f1963201b05d6a93bb5ee2dc56fabc248861ee5832dc2c176a`.
  Parameterized test-title compilation errors were corrected; both outputs remain
  at `/private/tmp/loopex-m7-responder-live-current-test-compile-failed-20261002.log`,
  SHA-256 `41c1a770d0fe684fa4621fe263eff6f07d96d4378fe2a2fb2b70048679b5ea16`,
  and `/private/tmp/loopex-m7-responder-live-floor-test-compile-failed-20261002.log`,
  SHA-256 `7622fdab20b5d869fcc1a5e9dd173727eeb5fad3d7375974c4ecbaf8cb0ab361`.
  The existing global temporary-root snapshot also attributed a concurrent floor
  VM's root to the current call. Each serial model-integration fixture now owns
  a distinct TMPDIR namespace; the original root-absence assertion remains.
  The failed run stays at
  `/private/tmp/loopex-m7-responder-live-current-shared-temp-failed-20261002.log`,
  SHA-256 `794282b027002a269f946804b909cff4d79dbe123b7e04322e1d451b6cec4151`.
  Original: 42 done / 144 remaining. Added: 125 done / 11 remaining.

- Done: T12's bounded callback component strips host/runtime fields from the
  model-question DTO, reconstructs exact offered choice identities through the
  existing Interaction validator, and waits for an exact owner/generation/reference
  grant before invoking host code. The temporary supervised worker admits only
  tagged text/choice or decline, preserves exact 8,192-byte UTF-8 answer bounds,
  and converts raise/throw/exit or invalid replies to responder_failed without
  private exception detail. Actual worker tests prove exact normal/killed DOWN
  and blocked callback isolation. Six cases pass in 0.09 seconds current and
  0.1 seconds floor; compilation, formatting, docs, dependency and status gates
  pass. This is a callback component: run/2 option consumption, session-owner
  registration, expiry/abort joins and cleanup precedence remain open. No public
  responder support is claimed yet.
  `/private/tmp/loopex-m7-responder-worker-current-verified-20261002.log`, SHA-256
  `ae16b0a6c6f85149d73c73ffd6bad6ffb7b5a9b0bf8f9d6ae134be09a104a3fc`;
  `/private/tmp/loopex-m7-responder-worker-floor-verified-20261002.log`, SHA-256
  `0f60a85c2082d0d5eb4cdf121e657e439d4a53fec6f615353ecadb77e2f6ba43`;
  `/private/tmp/loopex-m7-responder-worker-gates-20261002.log`, SHA-256
  `efc92d5c182748e4da7e3d57573c923d25ec59180debeff9cdd73fbb4ebabb35`.
  The draft fixture raced a linked supervisor's automatic termination with its
  on-exit stop. ExUnit now owns and joins that supervisor. Failed outputs stay
  retained at `/private/tmp/loopex-m7-responder-worker-current-20261002.log`,
  SHA-256 `797fa920560b44ec8eb86729c11a66cb02fc7978ccf039841a84bdcc2795054f`,
  and `/private/tmp/loopex-m7-responder-worker-floor-20261002.log`, SHA-256
  `36133e46c67d9b112559693c251e47b5bf4aaee493d3f0837e4fc056be704fd9`.
  Original: 38 done / 148 remaining. Added: 124 done / 11 remaining.

- Integration check: exact e1f9d7ba59b3511fa07308cf6ea747909b75ff8b
  ran once and passed all 11 application suites and every preliminary gate in
  904 seconds. Complete output: `/private/tmp/loopex-m7-e1f9d7ba-fast-check.log`,
  SHA-256 `9eadc817b82b0c87fea29438b4173853a8e05f44f89855cac6e456c6b97f6ee8`.
  This verifies the retained preparation failure facts and live lifecycle
  together. It does not erase earlier failed evidence, resolve the outstanding
  provider-cutoff flake, authorize the pending contracts, or close M7.
  The following checklist-only audit passes the documentation check in 18
  seconds: `/private/tmp/loopex-m7-t03-audit-docs-20261002.log`, SHA-256
  `423a1965ceffb7a086c7a92b01aadec29b580c3afaf090f48a0bee5f0fb74dcb`.

- Done: audited T03's original obligations against the implemented runtime and
  retained tests. Captured host instruction maps replace fixed Core text for
  configured sessions; legacy selection preserves its original renderer.
  Project and resource/skill facts keep separate source classes. Configured
  system ceilings and complete request bounds precede dispatch. Receipt revision
  4 binds captured instruction/configuration identities and independently
  measured continuation costs, while old receipt generations retain their
  decoders. Exact rendering/limits, actual two-prompt restart, malformed
  substitutions, required refusal order, frozen native costs and typed resource
  admission pass in four complete files: 73 cases in 7.6 seconds on each pair.
  `/private/tmp/loopex-m7-t03-obligations-current-20261002.log`, SHA-256
  `cc4deab414213b4187700b92d13493b1eca8068c20bbed675a6db535aa7c33bf`;
  `/private/tmp/loopex-m7-t03-obligations-floor-20261002.log`, SHA-256
  `6d0e5941ebb612f4cf6e28157d2b6430ba78df4453895b311a3da930ab2d0a35`.
  Five original T03 checkboxes now close. Host workflow fact capture, the full
  admitted/declined/changed instruction scenarios and policy/helper authority
  remain open. Original: 38 done / 148 remaining. Added: 123 done / 11 remaining.
- Decision pending: T02 early spill needs an immutable executor projection
  context. Recommended artifact_policy is the closed retain=true plus projection
  map with revision=1, artifact_read equal to the captured binding or explicit
  null, and normalized_call_id from the existing lineage recipe. The entire
  policy remains digest/grant-bound; old jobs retain exact bytes and spill
  behavior. New read/search generations validate this context before effects;
  new search allowances cover their exact capture ceiling. Alternative: a new
  JobRequest protocol generation with first-class projection members. The
  schema, compatibility and proof packet is retained at
  `/private/tmp/loopex-m7-early-spill-decision.md`. AGENTS.md's new cross-app
  contract tier requires a maintainer decision; dependent implementation stays
  pending. The earlier repeated public tool-event identity packet remains a
  separate unanswered decision.

- Done: T02's live preparation uses the configured public transfer store. The
  session owner commits source credit before verified put, waits for the exact
  worker DOWN, and commits the prepared reference before staging another
  request. Abort and the retained run cutoff join that worker before a terminal
  event. Adapter raise/throw/exit becomes a bounded retained failure; private
  adapter detail does not enter records. Missing transfer configuration refuses
  with the same named cause. Recovery with an empty registry repeats the exact
  reserved source under the same counters, episode identity and cutoff, without
  another reservation. Both live uncertain commits resolve by re-presenting the
  exact transaction before downstream work. Original receipts stay immutable.
  Four focused files pass 69 cases in 7.7 seconds current and 7.6 seconds floor;
  warning-free compilation, formatting, docs, dependency and status gates pass.
  Complete outputs:
  `/private/tmp/loopex-m7-preparation-live-current-verified-20261002.log`, SHA-256
  `70be4246b3eac9334ef9f6841f4d17f45de8f661246851d8455f2dde17bc38ff`;
  `/private/tmp/loopex-m7-preparation-live-floor-verified-20261002.log`, SHA-256
  `852d04007fdda3581c9a16e19a62ee86505373301e9072ae5d43e759bb38bdf6`;
  `/private/tmp/loopex-m7-preparation-live-gates-20261002.log`, SHA-256
  `2d658cad685689c00ef9c25d4afabb82c319344f20f2464ed82f7df3a0287a52`.
  Draft witnesses incorrectly assumed journal rows carried transaction IDs and
  that internal resolution queried status. The corrected fixture observes the
  actual exact re-presentation. Failed outputs remain retained:
  `/private/tmp/loopex-m7-preparation-live-current-recovery-20261002.log`, SHA-256
  `eb970a4ae6ba6a4c48a74551b020224bfdde17e2bdd74bbf495e20f91a7787a7`;
  `/private/tmp/loopex-m7-preparation-live-current-recovery-fixed-20261002.log`, SHA-256
  `2e68f39747cf5fb21805f260921422a5b88970c14a0a3835d0b836906c52a8b2`;
  `/private/tmp/loopex-m7-preparation-live-current-final-20261002.log`, SHA-256
  `df91dd70fd0a7da253bfe241fcd550c9dc24160d40d4dbd19437c603d283a88e`;
  `/private/tmp/loopex-m7-preparation-live-floor-20261002.log`, SHA-256
  `27656b09af5a261f261647d65b5622ae0ab692d1bbf040a71d1619eb29e6ff20`.
  Early spill/new tool generations and the long episode-cutoff witness remain
  unfinished. Original: 33 done / 153 remaining. Added: 123 done / 10 remaining.
- Integration check: exact 360d293ac9e84b783be58c7b0fd9808601f7e45e
  ran once and passed all 11 application suites and preliminary gates in 906
  seconds. Complete output: `/private/tmp/loopex-m7-360d293a-fast-check.log`, SHA-256
  `472a980511a8404d02f0eedbcc6a424bf4053b42084cab8edcc32f23d36a7cbd`.
  It covers the pure preparation reservations/references, not the subsequent
  retained failure or live lifecycle changes. Earlier failures remain failures;
  this does not resolve the outstanding provider-cutoff flake or close M7.

- Done: T02 retains tool_result_preparation_failed_v1 before emitting an
  unavailable refusal. The closed record captures episode/run/turn, exact
  source fingerprint, bounded cause and observation clock. Replay independently
  checks deadline/origin or exhausted credit; definite adapter failure is a
  reserved-source fact with no copied exception or adapter detail. Failure
  preserves counters/cursor and cannot reset the episode. Count exhaustion
  consumes no seventeenth source. Existing refusal-v2 and failed-terminal
  constructors derive the accepted artifact_preparation_* causes from the
  retained fact; a missing, altered or invented fact cannot justify the cause.
  Reservation admission now checks captured renderer/history capability and
  source validity before IO can become eligible. The original receipt and
  prior requests stay exact. Live worker dispatch, cancellation, public
  transfer-store wiring and early spill remain unfinished.
  Four complete focused files pass 60 cases in 7.0 seconds current and 6.9
  seconds floor, with warning-free compilation, formatting, docs, dependency
  and status gates passing. Complete outputs:
  `/private/tmp/loopex-m7-preparation-failures-current-final-20261002.log`, SHA-256
  `b0ebe5d2ece2ecedb4e01dc234c6ef1b2d587f4732ee62bfbfa49a34ec061e43`;
  `/private/tmp/loopex-m7-preparation-failures-floor-final-20261002.log`, SHA-256
  `da2e3f1cefbaea4a7f399b08dc587fc2d1bcc99936e85c3b1888a8bb3712e5ca`.
  An unnecessary draft fixture mapping lacked its required reasoning subset
  and refused genesis before three witnesses; the original fixture profile
  remains sufficient and was restored. Failed output is retained at
  `/private/tmp/loopex-m7-preparation-failures-current-initial-20261002.log`, SHA-256
  `d0c1868da2694cfd0407e090d4fceb4f0825faf20f79ec503c81374980defb7f`.
  Original: 33 done / 153 remaining. Added: 122 done / 10 remaining.

- Done: T02's versioned preparation records now reserve one oldest-first
  oversized inline source before IO and complete it under the same episode.
  The closed tool_result_preparation_state_v1 payload binds staging/run/turn,
  projection revision, fixed start/deadline/origin, reservation clock, count,
  encoded source-record bytes, cursor and the original receipt fingerprint.
  Version 1 of tool_result_reference_prepared binds that reservation, exact
  original text digest/size, five-label provenance, completion clock and the
  full reference. Independent canonical use reconstruction rejects borrowed
  provenance. Completion advances the cursor without another charge; recovery
  retains the exact reservation, counters and cutoff. Pending reservations
  block staging both in proposal construction and journal replay. Projection
  overlays a committed prepared reference on a transient element copy; original
  receipts, conversation and previously staged bytes stay immutable. Prepared
  references resolve through the existing session-owned artifact range boundary.
  Core Store transactions prove ambiguous reservation/completion convergence;
  the retained in-memory artifact adapter proves exact bytes/use metadata and
  idempotent storage. Negative replay covers identity, counters, deadline,
  schema, source digests/sizes and borrowed uses. Fixed cutoff/origin, exact
  16-source/1,048,576-byte caps and binary-reference selection are covered.
  This is a reducer/codec milestone: live workers, cancellation joins, retained
  failure facts, public transfer-store wiring and early spill remain open.
  All three complete focused files pass 27 cases in 1.5 seconds on both pairs;
  warning-free compilation, formatting, docs, dependency and status gates pass.
  Complete outputs:
  `/private/tmp/loopex-m7-preparation-records-current-all-20261002.log`, SHA-256
  `fedc2c4c7ac6dcaaf7b345d4a56a207d3d0eddb150b67698efc4ddf0de3e4226`;
  `/private/tmp/loopex-m7-preparation-records-floor-all-20261002.log`, SHA-256
  `aa3a11e88bd9261d312c80df81acaa724a9c0795806384f7ee78d973be5c0398`.
  The initial fixture used an artifact-store reference shape for the journal
  Store and failed before reservation; its retained output is
  `/private/tmp/loopex-m7-preparation-records-current-initial-20261002.log`, SHA-256
  `7b34966d0c66deb70576a485806658969c5998a92b615c407e230490ed70ca48`.
  Correcting the fixture to the existing Store struct repairs that harness error.
  Original: 33 done / 153 remaining. Added: 121 done / 10 remaining.
- Integration check: exact d83423d8efc8ef365be4bfdae88b4b9bcb5ad1b3
  candidate ran once and passed all 11 application suites and every preliminary
  gate in 909 seconds. Its complete immutable output is
  `/private/tmp/loopex-m7-d83423d8-fast-check.log`, SHA-256
  `de829545c53dcc1f5131909865c766704d54fe01329d56d5cdcf5118326400ee`.
  This verifies the refusal and denying-adapter inventory amendments together;
  it does not cover later preparation-source/record changes, erase earlier
  failed evidence, resolve the provider-cutoff flake, or authorize M7 closure.

- Done: T02 now selects oversized inline preparation sources from the selected
  ordinary lineage, using each complete encoded tool message rather than raw
  content length. Receipt replay retains the original canonical record digest,
  independently measured record byte cost, journal identity and only ADR 0015's
  five provenance labels. Frozen native prefixes, questions, explicit ranges,
  usable committed references and excluded units consume no preparation work.
  Exact 2,048-byte, escaping, ordered-source, unavailable-reference and retained
  receipt/replay witnesses pass 19 cases in 1.5 seconds on both supported pairs.
  Original facts stay immutable; this adds no storage writes yet. Episode
  reservation, completed reference records, live retention and early spill
  remain open. Complete outputs:
  `/private/tmp/loopex-m7-preparation-sources-current-complete-20261002.log`, SHA-256
  `2fce001b7c58920a4407fce2fc33811df754978f9bcbc349b20013bae09208b2`;
  `/private/tmp/loopex-m7-preparation-sources-floor-complete-20261002.log`, SHA-256
  `501ac4c54f9e67c052835d921fc469d044d8a3b36a6f53b1c004b7179edd0b3e`.
  Initial fixture assertions overlooked normalized call-ID length and used a
  source whose encoded cost was below the cap; the failed output remains at
  `/private/tmp/loopex-m7-preparation-sources-current-initial-20261002.log`, SHA-256
  `a5d50f18989c65a64cbafb8217764eb90affd69d53aec7f8826e606af90d7d2b`.
  Corrected fixtures pin actual normalized message cost and escaped content.
  Original: 33 done / 153 remaining. Added: 120 done / 10 remaining.

- Done: the maintainer-approved refusal-v2 amendment adds the exact optional
  pair project_resource_count/resource_pack_count for measured frozen prefixes.
  Both are unsigned 64-bit, at least one is positive, the six-count sum is
  bounded, and positive project input agrees with staged disposition. The live
  constructor partitions the complete descriptor sequence without dropping the
  native prefix. Required-only v1/v2 and unavailable v2 retain their historical
  shapes; fresh optional blocks retain withholding rather than becoming terminal
  required failures. Both ADR companions record the concrete schema.
  Actual project-only, resource-only and combined exchanges prove the captured
  preflight partition, independently recomputed ordered digest, exact estimate,
  no second dispatch, body-free compact record, independent deterministic byte
  encoding and replay. Missing, negative, null, fractional, overflowing,
  all-zero, extra and disposition-inconsistent count variants refuse.
  Complete configured, context admission and skill context files pass 66 cases
  in 7.5 seconds current and 7.3 seconds floor; compilation, formatting, docs,
  dependency and status gates pass. Complete outputs:
  `/private/tmp/loopex-m7-frozen-refusal-current-verified-20261002.log`, SHA-256
  `8030fd3825d7c76f07c24de4a9a774645dd53ef174d03a03e40a95bf88d50325`;
  `/private/tmp/loopex-m7-frozen-refusal-floor-verified-20261002.log`, SHA-256
  `00b243a2f1951154a439c3289352cfa84a4ced8b0af2fac41543a1043bc3d0d4`.
  The original implementation stops without a terminal on
  refused_not_required_only; the corrected fixture retains that failure at
  `/private/tmp/loopex-m7-frozen-refusal-before-final-20261002.log`, SHA-256
  `a00bd0566e13236d8026c888997a1814aa84b2c96e6ef121a3ec2e59774811eb`.
  The first draft's overly broad optional-count eligibility terminated fresh
  resource intake; its failure remains at
  `/private/tmp/loopex-m7-frozen-refusal-current-complete-20261002.log`, SHA-256
  `9d4f4d43f240497329019bc2646e2832cddcde16c14e04741a663d01c0328a13`.
  Restricting eligibility to a captured frozen context repairs that regression.
  A new fixture assertion initially double-counted system-provenance tool
  descriptors as messages; its failed output remains at
  `/private/tmp/loopex-m7-frozen-refusal-current-initial-20261002.log`, SHA-256
  `860c69c0d15cc7f94c31fcf1df0f32b5d8563e8869ac9eacf7c0be9cea89685e`.
  Original: 33 done / 153 remaining. Added: 119 done / 10 remaining.
- Integration check: exact committed 4d77e61c candidate ran once and exited 1.
  Core's 898 tests and nine other application suites passed; composition passed
  447 of 448 and failed the no-policy-callback inventory assertion described
  below. That assertion is repaired in 065f02a8 with focused proof, but the
  failed candidate is not a successful integration result. Complete output:
  `/private/tmp/loopex-m7-4d77e61c-fast-check.log`, SHA-256
  `999ac6c713b5140e6c549dbf360a32f92ba9e2df7d8e1b13edff182fa7bf1d31`.
  No full check has run on the subsequent inventory/count amendment bytes.

- Done: the composition authority inventory now verifies the approved contextual
  question adapter supplies no default authority. It still proves omitted/nil
  host policy refusal and admits exactly that adapter in the inventory, then
  checks every shipped ordinary and question generation denies through a bare
  reference and through contextual invocation without a supplied host policy.
  The prior blanket no-decide/1-export assertion rejected the new denying
  adapter during the 4d77e61c integration run. The proof now tests its actual
  authority contract; it does not waive a check or admit permissive defaults.
  The complete kernel composition file passes all nine cases on both pairs.
  Complete outputs:
  `/private/tmp/loopex-m7-question-policy-inventory-current-20261002.log`, SHA-256
  `2036405d6a42c4efb93c39a07214f2eb646b20818a8dda9ee6d37e671d1b3b97`;
  `/private/tmp/loopex-m7-question-policy-inventory-floor-20261002.log`, SHA-256
  `f4adc86be48450784db8f09d384675d8681f87f94864b228740eb441b0180af8`.
  That exact committed integration run remains active for the other suites;
  its composition failure remains failed evidence. Original: 33 done / 153
  remaining. Added: 118 done / 11 remaining.

- Done: public ephemeral startup accepts Boolean questions, default false,
  appending the exact question generation only to nonempty profiles. Invalid
  values, empty enabled profiles and per-call overrides refuse. Reusable
  text/choice/decline witnesses now use the public start_session facade. The
  one-shot wrapper uses the selected contextual Policy port to deny the exact
  question generation before admission, preserves the original policy identity,
  and delegates ordinary allow and defer decisions. Actual HTTP continuation
  proves denial followed by an ordinary effect for distinct provider call IDs;
  the separately retained repeated-ID defect below remains open. Complete
  options, model integration, API and run-cleanup files pass 54 cases in 22.0
  seconds current and 22.1 seconds floor. Compilation, formatting, docs,
  dependency and status gates pass after staging the new production adapter.
  Responder callback support and attended proof remain open. Complete outputs:
  `/private/tmp/loopex-m7-public-questions-current-complete-20261002.log`, SHA-256
  `482bef67855c1aabac777e6bb7e949187c0ea918cf729a59629036c5defbf44c`;
  `/private/tmp/loopex-m7-public-questions-floor-complete-20261002.log`, SHA-256
  `e1005a44db4a7dddcb18a0482005b19af41d7155960acb2433dd133ec61debaf`.
  Original: 33 done / 153 remaining. Added: 117 done / 11 remaining.

- Pending decision: public tool event IDs currently bind session and call ID,
  while canonical lineage permits the same provider ID in a later run/turn.
  A denied question followed by an effect with that ID ends the coordinator
  with executor_fact_failed/duplicate_event_id after dispatch. Recommended:
  version the affected intent, receipt and non-receipt terminal records and
  include run/turn/call in new event identities, preserving old replay bytes.
  Alternative: a new captured session event-identity revision plus migration.
  No dependent implementation is authorized yet. Decision packet:
  `/private/tmp/loopex-m7-tool-event-identity-decision.md`.
  Credential-free exact-DOWN reproduction:
  `/private/tmp/loopex-m7-question-continuation-diagnosis.exs`, SHA-256
  `09ecb1263a70d8aede7cd02da7bfb21bc8b6b662c5d6fc794c780dcd281d1b7d`;
  `/private/tmp/loopex-m7-question-continuation-diagnosis.log`, SHA-256
  `3c81c4f5985434214afb95cf39a9fbbf2491daf8a420d54d39a8b42872d3d4ac`.
  Runtime-owned trace: `/private/tmp/loopex-m7-no-responder-trace-20261002.log`,
  SHA-256 `23dcf46afd2f23bd1c19a5d1157328e439d587be434be0a700c378d724127fde`.
  Original public HTTP failure:
  `/private/tmp/loopex-m7-public-questions-current-20261002.log`, SHA-256
  `fc97c1156c43b107cf3f1854bb58f8980d40d5e8e118e01ce9c1dbe36983f648`.
  Distinct-call boundary proof below does not repair this defect.

- Done: the provider-child supervisor-loss fixture now obtains a child
  acknowledgement after sending its monitor signal and before killing the
  supervisor. This establishes the monitor before a termination propagated by
  another sender; the exact child/ref/killed assertion and all original receive
  bounds remain unchanged. Both complete cases pass in 0.04 seconds on each
  toolchain. Complete outputs:
  `/private/tmp/loopex-m7-provider-monitor-current-20261002.log`, SHA-256
  `eb28ccb572cac7d83e0ee64d49d8fb0797622343fa4b4cac401a9774f2d2267b`;
  `/private/tmp/loopex-m7-provider-monitor-floor-20261002.log`, SHA-256
  `8fa6bcdb11ead59f1d3dca667e707d8b49dbbd48416d78999e8c0ad7f8189992`.
  The failed 44a716df integration output remains retained. A new integration
  candidate is required before claiming the full check passes.
  Original: 32 done / 154 remaining. Added: 115 done / 11 remaining.

- Done: the maintainer-selected contextual Policy port accepts an exact
  `%{module: adapter, context: private_context}` reference and invokes optional
  `decide/2`; bare modules preserve `decide/1`. Invalid references and missing
  contextual callbacks refuse without falling back. Runtime startup validates
  the reference; telemetry retains only the adapter module. Private context
  never enters decisions, events or history. The complete contextual and
  existing interaction files pass 29 cases in 12.2 seconds current and 12.1
  seconds floor, including actual owner dispatch, denial before a pending
  question and exact aborted-worker shutdown. Compilation, formatting,
  documentation, dependency and status gates pass. One-shot composition and
  responder integration remain open. Complete outputs:
  `/private/tmp/loopex-m7-policy-context-current-complete-20261002.log`, SHA-256
  `e38932dd9d6c02e226cf56ca1140cea4485c3b80d5d394ef39c70f55e8360fe7`;
  `/private/tmp/loopex-m7-policy-context-floor-complete-20261002.log`, SHA-256
  `631feb828a4e7ea1312f1c3d4e5e2714e0d6bff6cd435ac915cee6a778e716dd`.
  A new assertion initially guessed killed rather than the existing shutdown
  reason; the failed output remains at
  `/private/tmp/loopex-m7-policy-context-core-current-verified-20261002.log`,
  SHA-256 `099148427d9c447981ff5853c0e90183bee64eb72bbe39788b0e2ddfe59bd1c1`.
- Integration check: exact committed candidate
  `44a716df846ddd4581d417cbe261c3fbd1714b27` ran once and exited 1.
  Preliminary gates and ten application suites passed, including composition's
  approved diagnostic-loss proof and all 385 provider cases. Core passed
  888 of 889: the provider-child supervisor-loss fixture observed `noproc`
  instead of the asserted killed reason. This is failed integration evidence.
  Complete output: `/private/tmp/loopex-m7-44a716df-fast-check.log`, SHA-256
  `13d7452089ba14a415cc80164da6c3a22124c1f9643fc2b96c25cae7b5842f23`.
  The earlier provider-launcher deadline failure on e5 remains unresolved;
  its pass here does not repair or invalidate that failed evidence.
  Original: 32 done / 154 remaining. Added: 114 done / 12 remaining.

- Done: public `Loopex.create_session/3` accepts explicit `genesis: payload`
  and delegates to the existing exact writer. Omission preserves v2 creation;
  present nil/malformed payload, mismatched options and malformed command
  options refuse. Repetition keeps the exact original session; changed genesis
  preserves the writer's `tx_id_conflict`. Both v2/v3 use shared validation and
  historical lookup. Chat's real local-store creation/restart witness now uses
  the public facade. Complete Core file passes six cases in 0.5 seconds on each
  pair; complete chat file passes eleven in 7.9 seconds current and 7.7 seconds
  floor. Compilation, formatting, docs, dependency and status gates pass.
  Complete outputs:
  `/private/tmp/loopex-m7-public-genesis-core-current-final-20261002.log`, SHA-256
  `9b31fa1e5e3ed43003800ab4daa6fb6e89a0c829ede4a514e9219e7c21bb7fd1`;
  `/private/tmp/loopex-m7-public-genesis-core-floor-20261002.log`, SHA-256
  `52aa0ee3705fc1e98b70fe7a643a3f784db51fcbab09ce41bda7cbeb8b77c352`;
  `/private/tmp/loopex-m7-public-genesis-chat-current-20261002.log`, SHA-256
  `d278bea301b5b773e9231de7158119ca7fa56dc17e6fdc09807fc8a404f8ce16`;
  `/private/tmp/loopex-m7-public-genesis-chat-floor-20261002.log`, SHA-256
  `1c366da5a7897350d1051616901255c5abece59ca32dcba4212dbebb87c92c2f`.
  The initial new conflict assertion guessed a different category and failed
  one of six cases; it was corrected to the unchanged writer contract. Retained
  failed output: `/private/tmp/loopex-m7-public-genesis-core-current-20261002.log`,
  SHA-256 `7461f25171f8c7e76c3c8a395f482d3d6eef3bd6b8fac85f29a0c20e5228ff49`.
  Original: 32 done / 154 remaining. Added: 112 done / 11 remaining.
- Applied: the exact maintainer-approved diagnostic-loss patch, SHA-256
  `2076f86b43c07390e93ce9e6e7b232d5e7c7d430dfc56fd254ee9cc416b4187f`.
  It captures one 1,000-ms deadline at owner/drain fault injection and proves
  exact worker, supervisor and consumer DOWNs within the remaining shared
  allowance and final cutoff. All thirteen diagnostic cases pass in 0.7 seconds
  current and 0.6 seconds floor, including blocked IO and supervisor faults.
  Complete outputs:
  `/private/tmp/loopex-m7-diagnostic-loss-approved-current-20261002.log`, SHA-256
  `e71f6f4d36b44313eb96b0f546f110777e1a282a658e5ee1ca1280c789e00744`;
  `/private/tmp/loopex-m7-diagnostic-loss-approved-floor-20261002.log`, SHA-256
  `ec625303d49e05a9ddabdbda9895920b69775484b1a92fdc441de8f47967da52`.
  The added T16 item remains open until the new committed integration check
  runs; earlier failed outputs remain failed evidence.
- Decisions resolved — 2026-10-02: the maintainer selected public facade
  extension for exact genesis, reuse of the public transfer store for result
  preparation, concrete refusal-v2 amendment with optional project/resource
  counts and byte proofs, the captured 1,000-ms diagnostic fixture cutoff,
  and contextual Policy-port extension for absent-responder denial. These
  explicit choices supersede the pending packets below; implementation and
  verification remain open. The diagnostic override is also retained in the
  Concept plan's Progress and Evidence section. No runtime cleanup bound or
  provider-launcher terminal test bound changes with that approval.
- Done: T08's registered reasoning subset and literal mappings are joined
  through complete file/flag chat preparation into exact validated genesis.
  All nine accepted cells retain the full subset, thinking controls, continuation
  requirement, reply allowance, derived context ceiling and value origins.
  Manual budgets equal to reply allowance refuse; allowance plus one admits
  without enlargement. Fable none, unregistered high/low and misleading aliases
  refuse before state creation. No summarizer is inferred. Complete chat and
  selection files pass 25 cases in 8.9 seconds current and 9.0 seconds floor;
  compile, formatting, documentation, dependency and status gates pass.
  Complete outputs: `/private/tmp/loopex-m7-chat-cells-current-20261002.log`,
  SHA-256 `c69c3f16628943d4479678157fd933f48fbd53ae2c3019c7dd528ac606136ca8`;
  `/private/tmp/loopex-m7-chat-cells-floor-20261002.log`, SHA-256
  `12ce56038bd9e8871b777df6c210e7702cb9266df56eca670818aa101afae850`.
  This establishes prepared configuration; chat execution, daemon routing,
  checkpoint preflight and real-provider witnesses remain open. Original:
  32 done / 154 remaining. Added: 111 done / 11 remaining.
- Done: T13's fixture source catalog now requires each retained task's exact
  changed/created path allowance, rather than accepting any well-formed path
  list. Four mutation witnesses reject review edits, invented repair files,
  removed feature edit allowance and extra long-fixture outputs. Existing
  seed/oracle bytes and all seven deterministic cases remain unchanged.
  Extended tests fail against the prior validator; the corrected complete file
  passes seven cases in 5.1 seconds current and 4.6 seconds floor. Compilation,
  formatting, documentation, dependency and status gates pass. Complete outputs:
  `/private/tmp/loopex-m7-fixture-write-policy-red-20261002.log`, SHA-256
  `d726502b8532f6a408b650136219b1ea372f6d50067e12a46cbd5e78b5211b63`;
  `/private/tmp/loopex-m7-fixture-write-policy-current-final-20261002.log`, SHA-256
  `a4c89c2d9884c9a403f3993f41bdbb7af3b48aa152035bfbb95309a76a954c38`;
  `/private/tmp/loopex-m7-fixture-write-policy-floor-20261002.log`, SHA-256
  `b2e18050fabacedd03f4333708af977e447cfe3dd08bbd6fa9fe9ccb310e1041`.
  Original counts: 32 done / 154 remaining. Added: 110 done / 12 remaining.
- Failed: the complete fast check ran once on clean checkpoint projection SHA
  `e5f03ff8e946dc6c99bf3f955f76894fdd27371d` and exited 1. Ten application
  suites pass; ReqLLM passes 384/385 with its namespace-cleanup interrupted-wait
  case missing Port exit-status and DOWN inside the captured 2,100 ms window.
  Its subsequent live process-group inventory is empty and all five guard
  signals succeeded. This does not prove the terminal bound. Required cleanup
  acknowledgement refusal and termination assertions remain intact; root-cause
  investigation is pending. Complete output:
  `/private/tmp/loopex-m7-e5f03ff8-fast-check.log`, SHA-256
  `aa02a54a81bbc417818025580fedfc8c787bb513e15a05d05386ebede9f67f75`.
- Passed: full fast check once on clean fixture catalog SHA
  `08beed1583474ed737df60ca7063b89a8a6afe90`: all eleven application suites,
  3,185 passed, 34 existing exclusions, 890 seconds. Complete output:
  `/private/tmp/loopex-m7-08beed15-fast-check.log`, SHA-256
  `6e08ac03e4932869f8c6e640bb939afa16e3b7b6fa90eda627def0e1edbdb99b`.
  This predates policy notice and checkpoint rendering changes.
- Done: T07's canonical maintenance request constructor uses the explicitly
  eligible thinking-off selection, verifies the exact frozen instruction capture
  and retains the prepared source-v2 bytes as one user message. Tools are empty,
  continuation nil and reply reserve exactly 1,024; ordinary sampling/resources
  supply no defaults. Missing model/instructions and unsupported reasoning keep
  distinct refusals; changed instruction bytes/version/digest, malformed source
  text and oversized source refuse. Source ownership, complete admission,
  episode persistence, provider permits/accounting and recovery remain open.
  The existing registered Haiku summarizer local-HTTP witness now uses this Core
  constructor and independently checks exact outgoing system/source bytes,
  disabled thinking, reply reserve and natural completion without continuation.
  Complete affected Core files pass 36 cases in 0.4 seconds on each pair.
  Complete native transport file passes 14 tests in 2.7 seconds current and
  3.1 seconds floor. Compile, formatting, documentation, dependency and status
  gates pass. Complete final outputs:
  `/private/tmp/loopex-m7-maintenance-request-current-final-20261002.log`, SHA-256
  `41450e938990c40f37ebc3e5a9b530455c04779e5b6c1ae050fd9a704ff560e1`;
  `/private/tmp/loopex-m7-maintenance-request-floor-20261002.log`, SHA-256
  `64fee8aade3beaabd99a80e3e7ba7333c22769c57d700455ca5ef5bbe616ee54`;
  `/private/tmp/loopex-m7-maintenance-request-transport-current-20261002.log`, SHA-256
  `72de24ae03e3bfc32db8805fef64d8bfe175329e47c899b959d92e886752b00a`;
  `/private/tmp/loopex-m7-maintenance-request-transport-floor-20261002.log`, SHA-256
  `d0ae2cb6cd33f21896a9fd684bd1639e25528103435230710bf5ae5614cfac12`.
- Checklist audit: T13's retained repair and review fixture definitions and
  independent oracles fulfill those two original implementation items. Their
  seed/oracle bytes were implemented in `8ae0c371`; the catalog, complete
  inventory checks and seven deterministic tests on both pairs now pin and
  verify them. The actual agent execution, approved test policy, helper/question
  joins and provider evidence belong to the remaining items and stay open.
  Original counts: 32 done / 154 remaining. Added: 109 done / 12 remaining.
- Decision pending: T12's one-shot absent-responder denial needs per-call
  admission state, while the released Policy port accepts only a module with
  decide/1. Recommended: an immutable runtime model-question admission gate,
  selected as deny by the wrapper without a responder, producing the existing
  interaction_unsupported denial before opening a question. Alternative: amend
  Policy to accept explicit per-runtime adapter context, with broader contract
  and compatibility work. This is a new cross-application decision under AGENTS;
  neither path is implemented. Asked 2026-10-02. The four earlier decisions
  (exact-genesis bridge, preparation store, refusal counts, diagnostic-loss
  assertion bound) remain unanswered; general continuation did not resolve them.
- Done: T07's existing summary owner captures covered-record provenance from
  trusted inputs, ORs the current source excerpt classification with inherited
  omissions, and renders a closed checkpoint summary as one canonical user
  message with its exact checkpoint source reference. Model output still admits
  only summary/carry-forward and cannot author provenance. Source reuse and
  rendering now share the same prior-data validator. An independently encoded
  UTF-8 vector pins 325 bytes and SHA-256
  `7517073f290d4df4edb21469e31b8a678dfbcd0fdc6c30075cf209a95aa6d2c2`.
  All nine native mappings preserve those bytes as user text in both streaming
  and buffered rendering. No instruction or tool result is fabricated.
  Source/summary tests pass 30 cases in 0.4 seconds on each toolchain; native
  request tests pass 15 in 1.9 seconds current and 1.8 seconds floor. Compile,
  formatting, documentation, dependency and status gates pass. The initial new
  test confused a source's current excerpt classification with an inherited
  checkpoint flag; it failed 1 of 29 cases. The final test preserves the source's
  existing meaning and exercises the new owner capture step instead.
  Retained complete outputs:
  `/private/tmp/loopex-m7-checkpoint-render-core-current-20261002.log`, SHA-256
  `ded23bdfbe68735a4a69f4741b41d33b2482790f5eca40fbc4fd2e00b886e027`;
  `/private/tmp/loopex-m7-checkpoint-render-core-current-final-20261002.log`, SHA-256
  `b5f45d2321dd4ae9c08b89f879e2a3ffb32b9e9eba00ea19d648c486aff96627`;
  `/private/tmp/loopex-m7-checkpoint-render-core-floor-20261002.log`, SHA-256
  `059edd640412dd2b98136d903dcecf280a9b7b82e762375700f1ee96701208ad`;
  `/private/tmp/loopex-m7-checkpoint-render-native-current-20261002.log`, SHA-256
  `f4c30c30505269c912a0b3f33054747c17aa8fd4cd1c24daf1edd2f8f2d60084`;
  `/private/tmp/loopex-m7-checkpoint-render-native-floor-20261002.log`, SHA-256
  `7381ee807aa74ebe104237d793109c4053efdd74f209603ab12513fe96372ea2`.
  This is pure content/provenance preparation and adapter rendering, not retained
  checkpoint, episode admission, range-integrity, recovery or provider proof.
  Original counts remain 30 done / 156 remaining. Added: 108 done / 11 remaining.
- Done: the reference client's explicitly selected AllowAll policy no longer
  transfers a VM-lifetime notice table to init. The retained defect reproduces
  after a short-lived first decision caller exits: its table survives at init
  and init logs an unexpected ETS-TRANSFER. The policy now retains the notice
  fact in persistent_term and serializes the first update through a local global
  transaction with distinct caller identities, matching the CLI's existing
  approach without importing another client. Policy decisions and notice text
  remain unchanged; no actor or ETS table is allocated.
  The complete policy file passes four tests on both toolchains (0.2 seconds
  current, 0.1 seconds floor), including 64 concurrent decisions and exact first
  caller DOWN followed by a silent later decision. The complete reference-client
  suite passes 20 tests with two existing exclusions in 3.7 seconds current.
  Compile, formatting, documentation, dependency and status gates pass.
  Complete failing-before and final outputs:
  `/private/tmp/loopex-m7-policy-notice-lifetime-red-20261002.log`, SHA-256
  `07326d1eeff959969e258ba509188607b597ee17aede2e42c8489d58936ce67f`;
  `/private/tmp/loopex-m7-policy-notice-lifetime-current-20261002.log`, SHA-256
  `772f3ecd1f7a2ba3706fa235b614c62800fc23a0d8890a07f9389e5aad5e7b09`;
  `/private/tmp/loopex-m7-policy-notice-lifetime-floor-20261002.log`, SHA-256
  `c0dd4626b3d4171096ad666e2afc6f439ed609a5cfbd5b622943018f156cbedf`;
  `/private/tmp/loopex-m7-policy-reference-suite-current-20261002.log`, SHA-256
  `0e75edd68f9e4d81e4211b0924012df582b537729b5eb0b65a1f915f27992387`.
  Original counts remain 30 done / 156 remaining. Added: 107 done / 11 remaining.
- Passed: the full fast check ran once on clean implementation SHA
  `bd2828eae9d9095634e002875bbb9001dd9a12d0`. All eleven application suites
  passed: 3,182 tests, 34 existing exclusions, 895 seconds. Complete output:
  `/private/tmp/loopex-m7-bd2828ea-fast-check.log`, SHA-256
  `364f044af71530fca0c6ca20972b504ad09359575cb0e6a60da1bda061a6a6a4`.
  This candidate includes tagged ephemeral answers and supervisor-first diagnostic
  teardown; it predates the fixture catalog. Earlier timing failures remain
  retained, and the separate diagnostic-loss deadline decision remains open.
- Done: T13's source catalog pins the four retained seeds and independent oracle
  bytes/modes, literal prompts, baseline bounds, permitted workspace changes,
  objective results and required question/helper actions. The validator refuses
  duplicate/unknown JSON members, invalid paths, changed sources/oracles,
  forbidden workspace edits/additions/modes and symlinks. Existing seeded-failure
  and corrected-result tests now check workspace inventories and oracle identity
  before and after each actual oracle invocation. No seed or oracle bytes changed.
  The seven-test file passes in 4.8 seconds current and 4.5 seconds floor without
  warnings. Compile, formatting, documentation, dependency and status gates pass.
  Complete outputs:
  `/private/tmp/loopex-m7-fixture-catalog-current-verified-20261002.log`, SHA-256
  `a2b971b1de5a3e97588d17cc34d6283d678c93ed0912e8968f586cae6b7eacd9`.
  `/private/tmp/loopex-m7-fixture-catalog-floor-verified-20261002.log`, SHA-256
  `ce6ee4c2e677cc76b6da203e51f7153b777c862ae9378428f2b25ea772562686`.
  Development runs passed assertions but reported clause-ordering and then runtime
  deprecation warnings; both were corrected before the final checks. Retained:
  `/private/tmp/loopex-m7-fixture-catalog-current-initial-20261002.log`, SHA-256
  `e02e47049fdf225ec9eac30731bf210fddc4f5e4f13ede8b29631671d7efa7b1`;
  `/private/tmp/loopex-m7-fixture-catalog-current-final-20261002.log`, SHA-256
  `a899fde9dce50fabdd6876051cdc15fcb813dc882648a79bd8c4e27e70afc388`.
  Complete V1–V13 execution bindings, approved fixture-host policy, committed
  question/helper/checkpoint joins, provider execution and the deferred external
  target remain open. No provider attempt ran. Original counts remain 30 done /
  156 remaining; added counts are 106 done / 12 remaining.
- Done: diagnostic shutdown now asks the private supervisor to stop before
  collecting the writer and supervisor monitor joins. Killing a task first and
  receiving its DOWN does not order that task's linked EXIT at the supervisor
  ahead of a stop request from a different sender. A suspended-supervisor fault
  witness failed on the old ordering: its blocked writer was already dead before
  the supervisor could process shutdown. The new ordering leaves that child
  under its supervisor until shutdown, then proves both joins and unchanged
  unconfirmed-delivery accounting. Synchronous close, asynchronous close and
  owner-loss termination use this order; the existing Task worker, actor count,
  cleanup grace and receive timeouts remain unchanged.
  Complete diagnostic/ephemeral-trace files pass 24 tests in 6.2 seconds current
  and 6.1 seconds floor. Real CLI stderr/JSON and OS-signal files pass eight
  tests with one existing exclusion, 22.1 seconds current and 19.9 seconds floor.
  Compile, formatting, documentation and dependency gates pass. Outputs:
  `/private/tmp/loopex-m7-diagnostic-supervisor-first-red-20261002.log`, SHA-256
  `0347a1cad069343d497e35f4a43c60c247b4904e92c7fa6df929422f2bfa5b99`.
  `/private/tmp/loopex-m7-diagnostic-supervisor-first-current-20261002.log`, SHA-256
  `f108e156eb325bfba1abe42796e6b8deb1f25e249261f0273b38236dac9c37b6`.
  `/private/tmp/loopex-m7-diagnostic-supervisor-first-floor-20261002.log`, SHA-256
  `75364c015e84f48570fcdd39d885d985a537211a5d1fb39985f6d1a39587e911`.
  `/private/tmp/loopex-m7-diagnostic-supervisor-first-cli-current-20261002.log`, SHA-256
  `7d899b23a63af1b9e608049a500678d776778771820be8bcd62a896262374d16`.
  `/private/tmp/loopex-m7-diagnostic-supervisor-first-cli-floor-20261002.log`, SHA-256
  `6895b9d90dc7a041e16f046ee08e4c2208d2ba1783f468d5070d4ce5e6fae59f`.
  This fixes the demonstrated child-before-supervisor teardown race. It does
  not establish a universal 100 ms scheduler bound for abrupt consumer death;
  the separate proposed assertion-deadline override stays unapplied and open.
  Original counts remain 30 done / 156 remaining. Added counts: 105 done /
  12 remaining. Other Task.Supervisor and policy ETS lifecycle investigations
  remain open.
- Passed: the full fast check ran once on clean query implementation SHA
  `46ffbf7e633f7410c6884f5f1bab026766944495`. All eleven application suites
  passed: 3,174 tests, 34 existing exclusions, 900 seconds. Complete output:
  `/private/tmp/loopex-m7-46ffbf7e-fast-check.log`, SHA-256
  `5a12917d71cd5db79a9fba7399c3e930d7ac1f8e2178471d331652c294073239`.
  It predates the tagged ephemeral answer and diagnostic shutdown changes.
  Earlier diagnostic timing failures remain retained; this pass does not turn
  those unchanged-revision failures into passes or close their investigation.
- Done: T12's `answer/3` keeps the choice-ID shorthand and adds tagged
  choice/text and explicit decline. The existing serial owner checks the pending
  producer and kind before occupying its command slot, including an answer
  reserved while the sole event reader is polling. Policy-defer remains
  choice-only; malformed, wrong-kind, unoffered and stale answers leave the
  pending observation unchanged. Model question projection retains its producer
  and kind; answered/declined terminals clear only model questions. No response
  creates a responder worker or grants effect authority.
  The private prepared owner configuration can select the exact question tool
  generation alongside its existing nonempty tools. Public startup grammar
  still refuses `questions`; the complete opt-in/responder union remains open.
  Existing API/serial tests and three actual-owner/Core/local-HTTP witnesses
  pass 36 cases in 19.5 seconds on each toolchain. Actual Core records prove
  model questions/answers without executor intents, preserve a 2,200-byte answer
  in the next request, refuse stale answers and admit a subsequent prompt.
  The scripted boundary witness also preserves the full 8,192-byte UTF-8 maximum.
  Development verification caught a replacement-script syntax error, then a new
  real-path fixture reading session identity from the wrong owner field. Both
  were corrected without weakening product validation or prior assertions.
  Complete outputs include those failures and final passes:
  `/private/tmp/loopex-m7-ephemeral-tagged-answer-current-initial-20261002.log`, SHA-256
  `e29df8d6c5eac4da172bc3bc0c8fc9d35900899d6edef1e392310c31df7ea993`.
  `/private/tmp/loopex-m7-ephemeral-tagged-answer-current-fixed-20261002.log`, SHA-256
  `d2a5e8d34970d339409b799aa2701d3a348404daaa76e99ba99c07f0f6d8fa6b`.
  `/private/tmp/loopex-m7-ephemeral-tagged-answer-current-real-20261002.log`, SHA-256
  `e6632cc39237ce86cd25587c06e3057d8f0da69f99afc1fd39016bf4b5c367a7`.
  `/private/tmp/loopex-m7-ephemeral-tagged-answer-current-complete-20261002.log`, SHA-256
  `391d939f46d7434ea245a81f27724fd7863855e213eaedf1fb7cd6ffde6078a3`.
  `/private/tmp/loopex-m7-ephemeral-tagged-answer-floor-complete-20261002.log`, SHA-256
  `e7f3aa6c300f978e5d39dc0527fa79c9fded004e2775d041ecd03fa6eb22a5e1`.
  Compile, formatting, documentation and dependency gates pass. Original T12's
  tagged-answer item is complete; startup opt-in, one-shot responder, cancellation
  joins and attended evidence remain open. Original counts: 30 done / 156
  remaining. Added counts: 104 done / 12 remaining.
- Done: T11's accepted private `Runtime.effect_intents/4` query authenticates
  runtime/session scope, scans bounded captured journal cuts and verifies an
  opaque raw prefix token before returning resumed coverage. Empty projected
  rows still advance coverage; only nil next_cursor completes the cut. Closed
  cursor/error forms, contiguous bounded Store records, supported record shapes,
  plain job/terminal projections and complete response limits refuse malformed
  history. The reader neither activates a coordinator nor writes history. The
  existing Control guardian joins its reader before timeout or owner-loss
  results. Actual Memory and Local histories, Local log reopen, v3 model/question
  histories and a literal effect-free genesis/token vector pass on both pairs.
  Shared process-only test adapters were moved byte-for-byte from the guarded
  Core helper for use by both applications; temporary host paths remain isolated.
  Initial composition fixtures failed because the guarded Core helper lacked
  a temporary LOOPEX_HOME, then because modern tool options lacked explicit
  tool/policy fields. The final fixture uses isolated paths and explicit accepted
  options; product validation and existing assertions remain unchanged.
  Complete Core selection: 130 tests, 26.7 seconds current and 26.5 seconds floor.
  Complete Store/question selection: five tests, 0.5 seconds on each pair.
  Compilation, formatting, documentation, dependency and status gates pass.
  Retained outputs, including the two development failures:
  `/private/tmp/loopex-m7-effect-query-core-current-complete-20261002.log`, SHA-256
  `674d77436e9292ddc27ea3fd823b03950e52d650eb3ef7b2c1a1f729affe48b8`.
  `/private/tmp/loopex-m7-effect-query-core-floor-20261002.log`, SHA-256
  `a5748831bd51855c8dd0c005289fbc14d6980a6b281f6d6bf2f187c8a7e592d7`.
  `/private/tmp/loopex-m7-effect-query-stores-current-initial-20261002.log`, SHA-256
  `8c53763facfca724069be52e09ec46096bba588aa06691a8db8461f053f629dc`.
  `/private/tmp/loopex-m7-effect-query-stores-current-final-20261002.log`, SHA-256
  `7d436900f81c0e92ebdadfd2568426dafd9b1174329c1c18323d2ec5786bd0e2`.
  `/private/tmp/loopex-m7-effect-query-stores-current-complete-20261002.log`, SHA-256
  `36d371ab8cbc46d5a065665dc41daf409661f62cd721cb2837e62c6f804e159f`.
  `/private/tmp/loopex-m7-effect-query-stores-floor-20261002.log`, SHA-256
  `dc0c64a3eac91d67daf677e1feba202a9167b00dd8111b1732ded4cbe33ab595`.
  Original T11's read-only provenance/effect query item is complete. The stateless
  query validates the admitted record shapes and effect projections; it does not
  replay whole-session transitions or join intent/terminal rows across pages.
  New maintenance writers must extend its supported record inventory in their
  integration change. Host classification, cache coverage and helper recovery
  remain open. Original counts: 29 done / 157 remaining. Added counts:
  103 done / 12 remaining. Four maintainer decisions remain pending.
- Failed evidence retained: the full fast check ran once on clean SHA
  `87c1205ab69a492560ac415c4be67c844bef920b` and exited 1. Preliminary gates and
  ten application suites passed. Composition passed 434 tests and failed one
  diagnostic owner/drain-loss case: its supervisor DOWN missed the existing
  implicit 100 ms assertion window. Total: 3,163 passed, one failed and 34
  existing exclusions. The last measured progress line was 892 seconds; the
  failed runner printed no final elapsed duration. Complete output:
  `/private/tmp/loopex-m7-87c1205a-fast-check.log`, SHA-256
  `265819095065373913bacde075ceb98d1e17e36b2b0e032fc246ea024da8b302`.
  The earlier full pass does not resolve this repeated failure. The proposed
  captured-grace proof remains unapplied and awaits the maintainer's decision.
- Done: T11's private effect-fact projection reuses the reducer's job, grant
  and receipt decoders, checks closed complete records and nested projections,
  validates canonical job bytes/digest and exact session/run bindings, and
  excludes grants and owner stamps from returned evidence. Committed receipts
  retain `receipt_committed` for every supported receipt outcome; core failed
  and cancelled tool-result facts project `refused_before_effect`, other tool
  terminal outcomes project `outcome_unknown`, and run-level unknown facts
  carry a null call identity. Reason text cannot select a disposition. Captured
  past deadlines remain readable; impossible deadline bounds refuse. Full
  input and projected-row sizes retain 65,536-byte bounds. Actual owner-created
  intent/receipt records and the dispatched executor job are the positive
  witness; malformed, expanded, wrong-scope, forged and oversized facts refuse.
  The first development test returned before run completion and failed all
  five cases; it also exposed a redundant type assertion. Output:
  `/private/tmp/loopex-m7-effect-projection-current-initial-20261002.log`, SHA-256
  `a7943c5b649aaa8b7145fdeff2003f0982945f5ccae8536be5abaa09988aa640`.
  The corrected wait then passed four cases and caught an incorrect test
  assumption that a captured deadline of 1 must refuse. The existing port
  accepts that historical positive instant within a declared wall ceiling;
  the final test preserves it and refuses 0 or a deadline beyond the run bound.
  Development output:
  `/private/tmp/loopex-m7-effect-projection-current-final-20261002.log`, SHA-256
  `34615f783e00d4b7f1ba6a90402fbb3f91c8699202e6d7839ba407fcce6c6681`.
  Final projection/question/create-history files pass 14 tests in 1.1 seconds
  on each pair. Complete projection/agent-loop files pass 113 tests in
  25.3 seconds current and 25.2 seconds floor. Outputs:
  `/private/tmp/loopex-m7-effect-projection-current-verified-20261002.log`, SHA-256
  `392f9dd49a967cced01c8847d9083d497d44924eb3eb8959227c13a254cecb57`;
  `/private/tmp/loopex-m7-effect-projection-floor-20261002.log`, SHA-256
  `99c6abea2a8636b4dcb4fbe41e5feae5068ac83eae895bf298bf22498be4126a`;
  `/private/tmp/loopex-m7-effect-projection-agent-loop-current-20261002.log`, SHA-256
  `ba83fab1d656e70bd3bf7daf8b2b345463e079be47d7ea38a650bcd9531158f1`;
  `/private/tmp/loopex-m7-effect-projection-agent-loop-floor-20261002.log`, SHA-256
  `377fe98b50065aa5fd48f70d19487036263e79037fb1992e4ba2846c30cf0eff`.
  Compile, formatting, compiled documentation, dependency and status gates pass.
  One added prerequisite is complete; original T11's query item stays open.
  The public paging query, prefix-token verification and startup classification
  are not implemented by this per-record decoder. Original counts remain
  28 done / 158 remaining; added counts are 102 done / 12 remaining. The four
  unanswered maintainer decisions remain pending; no proposed timeout change
  has been applied.
- Passed: the full fast check ran once on clean implementation SHA
  `ba07394e45a85ec640e3879e18212d6a68616626`. All eleven application suites
  passed: 3,159 tests, 34 existing exclusions, 897 seconds. Complete output:
  `/private/tmp/loopex-m7-ba07394e-fast-check.log`, SHA-256
  `e9d0573527bab06859b8fe11bd2d74c120dcc57496a4d55f4eefd0b3fa9c2e8f`.
  This includes the provenance callback and both shipped Store proofs. The run
  is terminal; do not restart or poll it. The earlier diagnostic timing failure
  remains retained failed evidence and its proposed bound change remains
  unanswered, unapplied and open under T16. Original counts remain 28 done /
  158 remaining; added counts remain 101 done / 12 remaining.
- Done: ADR 0046's accepted optional creation-provenance callback is implemented
  through Runtime, Store and both shipped adapters. Closed command/session
  point queries and runtime pages carry supported genesis versions and exact
  canonical create digests. Per-runtime ordinals and reverse indexes derive
  from committed create transactions in replay order; no frame, genesis or
  retained transaction bytes change. Pages preserve one captured high-water cut
  while later creates occur, and only nil next_cursor proves complete coverage.
  Invalid selectors/cursors, missing callbacks, unsupported genesis, incomplete
  indexes and malformed outputs retain their distinct refusal/unavailability
  meanings. No query activates a coordinator or mutates either Store.
  Boundary validation checks scalar bounds before encoding, visits at most
  sixteen rows and refuses duplicate command/session identities. The duplicate
  regression first failed against the incomplete decoder:
  `/private/tmp/loopex-m7-creation-provenance-duplicate-regression-20261002.log`,
  SHA-256 `4304a19851c14e8fcb31d13c25620f6030b8972a4b317edfe77a32dce12e924b`.
  Final focused proofs pass on both pairs: 38 Core history/genesis/boundary
  tests in 0.4 seconds each, all 91 Store tests in 11.1 seconds current and
  10.8 seconds floor, and three actual Store/runtime composition cases in 0.3
  seconds each. The final added conflicting-create witness passes the complete
  eight-case reusable conformance file in 2.2 seconds current and 1.9 seconds
  floor. Outputs:
  `/private/tmp/loopex-m7-creation-provenance-core-current-verified-20261002.log`,
  SHA-256 `f723cab415152f02d2c2a22e4a5410908a08a9eb59bdab3106c4b9a2118ce264`;
  `/private/tmp/loopex-m7-creation-provenance-core-floor-20261002.log`, SHA-256
  `c43eb1e6545648f4c2bf8d5ca49e1c25c1e4fa293446a2ebeddd5ad4adcc0ce3`;
  `/private/tmp/loopex-m7-creation-provenance-store-app-current-final-20261002.log`,
  SHA-256 `0b0f8cb941f911fdc1774fdb61df84c165c3fc6d25f8b0a78a7910ffbbae5841`;
  `/private/tmp/loopex-m7-creation-provenance-store-app-floor-final-20261002.log`,
  SHA-256 `9237738d1558f9c2ee4ac54f817394d6927cca7e75e9768198d24d7a67d5abef`;
  `/private/tmp/loopex-m7-creation-provenance-composition-current-20261002.log`,
  SHA-256 `6aa5e3fdd36cb2af5220ed2c7e36f796410d8afd951d8b0983eb46c574a65129`;
  `/private/tmp/loopex-m7-creation-provenance-composition-floor-20261002.log`,
  SHA-256 `b845158444aff7df9dd1dc062914eecbbad6e7b71a0af562c87fed34268007b1`.
  Final conformance outputs:
  `/private/tmp/loopex-m7-creation-provenance-conformance-current-final-20261002.log`,
  SHA-256 `214ecc787bd39599af890e44f39d533d83ad0c7e090f4c8d3f53ba171c733dfb`;
  `/private/tmp/loopex-m7-creation-provenance-conformance-floor-final-20261002.log`,
  SHA-256 `25fb740ce2703b580e5f4951e34656e217cd55f1495a307fc1f7807302f09209`.
  One added T11 prerequisite is complete. Original counts remain 28 done / 158
  remaining; added counts are 101 done / 12 remaining. Helper ownership,
  effect-intent queries and startup classification remain open. The full
  fast check has passed on this provenance candidate as recorded above.
  The four pending maintainer decisions are
  unchanged; no diagnostic timeout proposal was applied.
- Passed: the full fast check ran once on clean exact implementation SHA
  `ee7bb3e4039a1929ec8b92b276c3cdde64371257`. All eleven application suites
  passed: 3,153 tests, 34 existing exclusions, 898 seconds. Complete output:
  `/private/tmp/loopex-m7-ee7bb3e4-fast-check.log`, SHA-256
  `bc1651e5d20cbd9ff60f17c7d29581b29c2bbdc1098679ca2b596e2f9b658271`.
  The check is terminal; do not poll its old handle or rerun the unchanged
  candidate. It includes exact-history lookup and question-record vectors but
  predates the provenance callback above. The earlier diagnostic timing failure
  remains retained failed evidence and its proposed bound change remains
  unanswered, unapplied and open under T16.
- Done: ADR 0046's accepted host-private `Runtime.lookup_create_result/4`
  normalizes complete retained v2/v3 genesis and matching original options,
  constructs the exact transaction purely and reads its existing Store binding.
  It never expands current cleanup defaults, activates a coordinator or checks
  current tool/model registration. Both shipped Stores prove unchanged state;
  the local proof reopens the actual log before lookup. Conflict, absence,
  malformed input, Store uncertainty and Control loss retain their distinct
  meanings. The existing three-argument query stays unchanged.
  Inspection also found that exact-create accepted the private `:legacy`
  sentinel as a request to substitute current defaults. Its new map guard
  refuses before a Store write. The regression fails against the original
  branch with an actual session created:
  `/private/tmp/loopex-m7-exact-history-sentinel-regression-20261002.log`, SHA-256
  `6407324069a1b86011faf35b6dfd237c3a2f85017fe7122dd7db1baf2bd247e8`.
  The first guard returned a two-member error instead of the existing detailed
  response; that development failure is retained:
  `/private/tmp/loopex-m7-exact-history-current-final-20261002.log`, SHA-256
  `b0a4cdff3e6006803bfe5280297d19d20efa3f93233c68c34518e4656450bdd4`.
  The final guard uses the existing detailed refusal and passes all 64 tests in
  the complete Core history/genesis/configured files on both pairs, 6.0 seconds
  current and 5.9 seconds floor. The complete composition history/restart files
  pass three cases in 0.3 seconds each. Final outputs:
  `/private/tmp/loopex-m7-exact-history-current-verified-20261002.log`, SHA-256
  `6bb51636f2ef1ecf172e806022f400ab4f3ba0a16d9540573a022f5c1f335475`;
  `/private/tmp/loopex-m7-exact-history-floor-final-20261002.log`, SHA-256
  `71255566ab6f98bba770e682d36992970dc8a0cb8b51b5f3004d8107fce1150d`;
  `/private/tmp/loopex-m7-exact-history-stores-current-final-20261002.log`, SHA-256
  `8b4db55552afbbd42fd75c788f9e98ea4656220c22ef7f2fa4082a71cfc98563`;
  `/private/tmp/loopex-m7-exact-history-stores-floor-20261002.log`, SHA-256
  `e247503fc9663ea8c26031bd353ec82cb912667e8052b6014230625834ab744a`.
  One added T11 prerequisite is complete. Original counts remain 28 done / 158
  remaining; added counts are 100 done / 12 remaining. Helper implementation,
  creation provenance and complete runtime enumeration remain open.
- Done: literal model-question vectors pin the argument/request ETF preimages,
  digests, stable run/question identities and normalized response-command bytes
  for text, choice and decline. The real-owner decoder proof retains actual
  captured clocks and compares both complete record shapes. Replay refuses every
  missing/nil member, extra members, same-cardinality substitutions, altered
  identities, invalid instants and forged request/answer bindings whose digests
  were recomputed consistently. All 34 tests in the complete question-record and
  configured-session files pass on both supported pairs: 6.3 seconds current and
  6.2 seconds floor. Complete outputs:
  `/private/tmp/loopex-m7-question-records-current-20261002.log`, SHA-256
  `1b1deee4652fde5bd9a16b07a7469c377034b9ecec2a767fc4291255db77df0d`;
  `/private/tmp/loopex-m7-question-records-floor-20261002.log`, SHA-256
  `ff7a5ea5692897753c1a26334dc2df505fd6a561fbaf99368404d1da1cf59c9b`.
  This completes one added T09 decoder-proof subtask. Its broader public event
  schema and coordinated /3-/4 joins remain open. Original counts stay 28 done /
  158 remaining; added counts are 99 done / 12 remaining. The failed full check
  below remains failed evidence, and the diagnostic timeout proposal is unapplied.
  Next independent work is ADR 0046's accepted exact-genesis read-only lookup.
- Pending maintainer decision: diagnostic loss must be proved against its
  intended bound. The new full fast check on exact implementation SHA
  `5bebb2272f78d9c48faec9a2be9f53e5c0f5f952` finished with exit 1. Ten suites
  passed, including CLI's 450 tests; composition failed one diagnostic-loss
  case. Overall: 3,145 passed, one failed and 34 existing exclusions. Complete
  immutable output: `/private/tmp/loopex-m7-5bebb227-fast-check.log`, SHA-256
  `26df61e377b4c2e07c94523845d21db37a2376a467b86d0d9e3b1bd59845cf93`.
  The blocked worker stopped, but the private Task.Supervisor DOWN exceeded the
  test's implicit 100-ms wait. The fixture creates its consumer with 1,000-ms
  cleanup grace. A reviewable proposal captures one deadline at fault injection
  and requires worker, supervisor and consumer DOWNs before that same cutoff.
  This changes the tested time bound and remains unapplied. AGENTS.md prohibits
  inflating timeouts to make required checks pass; the explicit override was
  requested with options to approve the captured-grace proof or retain the
  original waits and investigate further. No response has been received.
  Proposal: `/private/tmp/loopex-m7-diagnostic-loss-deadline.patch`, SHA-256
  `2076f86b43c07390e93ce9e6e7b232d5e7c7d430dfc56fd254ee9cc416b4187f`.
  Its complete diagnostic test file passes all 12 cases in 0.6 seconds on each
  supported pair from a temporary file, without replacing repository tests or
  the failed integration evidence. Outputs:
  `/private/tmp/loopex-m7-diagnostic-loss-proposal-current-final-20261002.log`,
  SHA-256 `2f61f9225f9753e794e52e42c855ae4773b185a6c7697e39e42a2e649f753372`;
  `/private/tmp/loopex-m7-diagnostic-loss-proposal-floor-20261002.log`, SHA-256
  `f4e4af0dc9ddb6ce340c0f29eb104dff7c59840531e743973d7474fe431468f6`.
  The first temporary run used a filename outside test_load_filters and exited
  1 for that warning after 12 assertions passed; it is not PASS evidence:
  `/private/tmp/loopex-m7-diagnostic-loss-proposal-current-20261002.log`, SHA-256
  `92feb851657b2bc97129336bb40543ee893fa7bf918b0b8caa781f41ff60b5a2`.
  Renaming the temporary fixture to the configured *_test.exs convention fixed
  the runner setup. Production and repository test bytes remain unchanged.
  The exact proposed patch bytes are retained below as base64 for full resume
  if temporary files are lost. Original counts stay 28 done / 158 remaining. Added counts are 98
  done / 12 remaining after adding this pending T16 task. No agents or checks
  are running; do not poll the finished check handle or repeat 5bebb227 unchanged.
  Continue independent M7 work while this and the three earlier contract
  decisions remain pending. T09 research located the private pending/response
  readers and event projector in SessionState, with configured_session_test.exs
  providing the existing real-owner recovery fixtures. The legacy
  Interaction.from_record decoder remains policy-choice-only; model readers
  rederive their retained request from committed call arguments. Public schema
  work must join the coordinated new /3-/4 cutover, never alter /1-/2 in place.

```base64
LS0tIGEvYXBwcy9sb29wZXhfY29tcG9zaXRpb24vdGVzdC9kaWFnbm9zdGljX2NvbnN1bWVyX3Rl
c3QuZXhzCisrKyBiL2FwcHMvbG9vcGV4X2NvbXBvc2l0aW9uL3Rlc3QvZGlhZ25vc3RpY19jb25z
dW1lcl90ZXN0LmV4cwpAQCAtMjM4LDYgKzIzOCw4IEBACiAgICAgICBzdXBlcnZpc29yX3JlZiA9
IFByb2Nlc3MubW9uaXRvcihzdXBlcnZpc29yKQogICAgICAgY29uc3VtZXJfcmVmID0gUHJvY2Vz
cy5tb25pdG9yKGNvbnN1bWVyKQogCisgICAgICBjdXRvZmYgPSBTeXN0ZW0ubW9ub3RvbmljX3Rp
bWUoOm1pbGxpc2Vjb25kKSArIDFfMDAwCisKICAgICAgIGNhc2UgZGlzcG9zaXRpb24gZG8KICAg
ICAgICAgOm93bmVyIC0+CiAgICAgICAgICAgc2VuZChvd25lciwgOnN0b3ApCkBAIC0yNDcsOSAr
MjQ5LDEyIEBACiAgICAgICAgICAgc2VuZChvd25lciwgOnN0b3ApCiAgICAgICBlbmQKIAotICAg
ICAgYXNzZXJ0X3JlY2VpdmUgezpET1dOLCBed29ya2VyX3JlZiwgOnByb2Nlc3MsIF53b3JrZXIs
IF99Ci0gICAgICBhc3NlcnRfcmVjZWl2ZSB7OkRPV04sIF5zdXBlcnZpc29yX3JlZiwgOnByb2Nl
c3MsIF5zdXBlcnZpc29yLCBffQotICAgICAgYXNzZXJ0X3JlY2VpdmUgezpET1dOLCBeY29uc3Vt
ZXJfcmVmLCA6cHJvY2VzcywgXmNvbnN1bWVyLCBffQorICAgICAgZm9yIHtwaWQsIG1vbml0b3J9
IDwtIFt7d29ya2VyLCB3b3JrZXJfcmVmfSwge3N1cGVydmlzb3IsIHN1cGVydmlzb3JfcmVmfSwg
e2NvbnN1bWVyLCBjb25zdW1lcl9yZWZ9XSBkbworICAgICAgICByZW1haW5pbmcgPSBtYXgoY3V0
b2ZmIC0gU3lzdGVtLm1vbm90b25pY190aW1lKDptaWxsaXNlY29uZCksIDApCisgICAgICAgIGFz
c2VydF9yZWNlaXZlIHs6RE9XTiwgXm1vbml0b3IsIDpwcm9jZXNzLCBecGlkLCBffSwgcmVtYWlu
aW5nCisgICAgICBlbmQKKworICAgICAgYXNzZXJ0IFN5c3RlbS5tb25vdG9uaWNfdGltZSg6bWls
bGlzZWNvbmQpIDw9IGN1dG9mZgogICAgIGVuZAogICBlbmQKIAo=
```

- Done: CLI `ask` and `-p` now accept the closed trace controls for both
  profiles. Invalid disabled selections refuse before workspace, application,
  signal or credential effects. Ephemeral ask forwards the startup map to its
  existing private owner. Durable ask owns the shared consumer, binds it through
  existing diagnostics_to, activates the existing runtime trace before session
  creation, and seals diagnostics before composition teardown. One captured
  cutoff covers the certificate and all captured actor DOWN proofs. Missing
  proof discards the provisional answer as runtime_cleanup_unconfirmed.
  Startup failure refuses instead of dispatching an untraced question. The
  standalone owner captures the existing 5,000-ms default and forwards that
  same grace to composition. No new runtime contract or sink is introduced.
  Real local HTTP and separate-VM OS-signal witnesses prove stderr separation
  and owned actor joins. Chat/file/daemon driver integration remains open.
  This completes one added T10 subtask, no original item.
  Current: the broad affected selection passed 141 tests in 48.5 seconds;
  the final signal file passed eight tests in 21.9 seconds. Floor: the complete
  final selection passed 140 tests in 48.8 seconds. Its two fewer tty-handler
  cases are the existing conditional tests for prim_tty_sighandler, absent on
  OTP 27; the current broad selection preceded the one added signal case.
  Complete retained outputs:
  `/private/tmp/loopex-m7-ask-trace-current-20261002.log`, SHA-256
  `34543fb8961dd85f7800c7ed886901f3bced368796af30499010e086c99dca41`;
  `/private/tmp/loopex-m7-ask-trace-os-current-20261002.log`, SHA-256
  `39ded3a398fd6c72fb414fae570c36934f0e91c07bca8bea65a0c28c193b8cf6`;
  `/private/tmp/loopex-m7-ask-trace-floor-20261002.log`, SHA-256
  `ab6232908ecb3f52c8450fa438f345acceb55214a9e72be1a736a2e68af1004b`.
  The final ephemeral ask file also passes 22 tests in 1.1 seconds per pair,
  with no-effects assertions bound to the actual cwd, path, identity, credential
  and application seams. Outputs:
  `/private/tmp/loopex-m7-ask-trace-preflight-current-20261002.log`, SHA-256
  `f1ac8827509aaa34ea0dab9ea0ad3370021c8fe8c4bd2a1717188b2fad323929`;
  `/private/tmp/loopex-m7-ask-trace-preflight-floor-20261002.log`, SHA-256
  `fcb8861ff0fc5b0dc8d0521a5aace16314b3043eb520898502cc609d1e5fb9d8`.
  The first new-case run failed one test because its text-mode fixture expected
  empty stderr instead of the existing ending line. Corrected the assertion;
  no product behavior, deadline or bound changed. Failure output:
  `/private/tmp/loopex-m7-ask-trace-first-20261002.log`, SHA-256
  `ba722291f90ae2bb507340346209adc86cee46c53a4dcb32af4b0f00d6c2f55a`.
  Compilation, formatting, documentation ordering, status and dependency gates
  passed. No paid provider calls or live agents were used.
- Done: the full fast check on exact pressure-repair candidate
  `c226cef735c8b9e605690c1f69115dcec59e5270` exited 1. Ten application suites
  passed; CLI failed one chat-output startup fixture. Overall: 3,131 passed,
  one failed and 34 existing exclusions. Complete immutable output:
  `/private/tmp/loopex-m7-c226cef7-fast-check.log`, SHA-256
  `204a130b6d4c20d46b8ab18e202deaaa9c00f6fcd409fac1adbd1d695ca5c76e`.
  This is failed evidence. The abrupt writer-loss fixture expected an unrelated
  spawned host to complete startup and write admission within 100 ms. Its
  replacement uses the test itself as the live host, starts the writer through
  its synchronous API and unlinks only the host-to-writer edge before killing
  the writer. The writer-to-IO-worker link remains intact. It now proves both
  exact killed DOWNs, retaining the original receive timeouts. No product
  latency, capacity, retry or cleanup assertion is weakened. The complete
  output and signal files passed together on the current pair, 19 tests in
  25.8 seconds; the complete output file passed on the floor pair, 11 tests in
  5.4 seconds. Retained outputs:
  `/private/tmp/loopex-m7-chat-writer-current-20261002.log`, SHA-256
  `f7fb37429382eff6337f127b3cdd336bf3811f471448604856349eca9a0a8b92`;
  `/private/tmp/loopex-m7-chat-writer-floor-20261002.log`, SHA-256
  `0edaa6b25216e11fa1fb11b6dfd46f7f53dbc92387bce0ffc3ef03351490e0dc`.
  This completes one added T16 repair. Original totals remain 28 done / 158
  remaining; added totals are 98 done / 11 remaining. Commit and push this
  checkpoint, then run that new clean candidate once in the managed
  m7-trace-check checkout. Do not rerun c226cef7 unchanged as a pass.
- Done: the preceding full fast check on exact candidate
  `1d384b803c3a7fe2c836c7c47cbefbbf0d4c30b5` also exited 1. It passed 3,131
  tests, failed the diagnostic pressure fixture and retained 34 existing
  exclusions. Complete immutable output:
  `/private/tmp/loopex-m7-1d384b80-fast-check.log`, SHA-256
  `bcab6b181858c44a153c68037f66b17c5a30805a87c1bc9b5e0754b902217040`.
  The committed c226cef7 repair primes the real blocked writer before the
  6,000-message pressure, preserving 100-ms receive bounds, exactly 256 pending
  entries, one writer, 5,744 immediate drops and 6,000 final drops with one
  unconfirmed write. Both affected files passed 20 tests in 2.2 seconds on each
  pair. Outputs:
  `/private/tmp/loopex-m7-diagnostic-pressure-pair-current-20261002.log`, SHA-256
  `2b733524f4f689e44e14b03a1f5b6a8068a934428239e8e406f36167cb4c155f`;
  `/private/tmp/loopex-m7-diagnostic-pressure-floor-20261002.log`, SHA-256
  `a70a22885c250d0cad32050ada7f4d20c136563273faed3e0d9f1f7567080d2d`.
- Done: the full fast check of exact candidate
  `a47022cfcfdcc5f62c72654705e90a7d91a6cebb` finished with exit 1.
  Ten application suites passed; composition had one failed startup-protocol
  test. Overall: 3,131 passed, one failed, 34 existing exclusions. Complete
  immutable output: `/private/tmp/loopex-m7-a47022cf-fast-check.log`, SHA-256
  `9fb778469308260c3ac96d48b85ace0b4bf18ce4d6277187eebeeabac333b257`.
  This is failed evidence. Do not rerun that unchanged candidate as a pass.
  The failure is in the direct SessionRoot protocol fixture, outside the initial
  filename-based focused selection. Its sequence still expected runtime_holder
  immediately after trace_handle. The repair explicitly grants and acknowledges
  disabled diagnostics, proves no next phase before that acknowledgement, and
  proves no prepared subtree before the exact trace-start grant. Wrong-reference
  grants still refuse. Both complete eight-test files pass in 2.2 seconds:
  `/private/tmp/loopex-m7-root-trace-order-current-20261002.log`, SHA-256
  `e4a67721cd56edc9eb5293d209690699ae356893b524b31a271558607896f7cf`;
  `/private/tmp/loopex-m7-root-trace-order-floor-20261002.log`, SHA-256
  `b582eae86fe79a5ccefb94541268384b61c45fb77c525c7d09d44b9bd4edc79c`.
  This completes one added T16 subtask: original counts stay 28 done / 158
  remaining; added counts are 95 done / 11 remaining. The repair is committed
  and pushed as `d3097cf528d7d9374364da1ec88ddb89d3adc304`. Embedding and
  compatibility pages now describe the opt-in trace startup, closed selection,
  process inventory and cleanup contract. The documentation status check first
  found a nonexistent ADR tracing fragment; the corrected link uses its exact
  technical-depth anchor. Failed documentation output:
  `/private/tmp/loopex-m7-ephemeral-trace-status-20261002.log`, SHA-256
  `18a4457eabe322f31a4fd3a2c0e359b35eafbdc49fbea028c0cf5ba0eaa36b20`.
  Next: run the full fast check once on the committed repair plus documentation
  candidate, retaining its exact SHA and complete output. No new product-source
  changes remain uncommitted. CLI ask's trace flags/owner integration is next;
  they must cover both existing profiles before the flag vocabulary is exposed.
- Done: T12's optional ephemeral trace lifecycle is integrated. The closed trace
  map validates before preflight effects. Enabled startup grants and registers
  the diagnostic drain and its private writer supervisor before binding and
  activating the runtime trace; absent/disabled startup retains the original
  process inventory. A temporary diagnostic child can close normally without
  restarting the private tree. Tracing persists across prompts. Teardown seals
  delivery, captures and monitors an active writer, and requires the exact
  asynchronous certificate plus every registered DOWN under the existing
  deadline. Lost/expired diagnostic proof stays unproved on later stop retries.
  Real runtime and local HTTP model tests cover activation ordering, requested
  startup refusal, the original startup timeout, successive prompts, peer
  isolation, stalled stderr and drain/writer/supervisor loss. No paid provider
  calls were made. Original counts remain 28 done / 158 remaining; added counts
  are now 94 done / 11 remaining. T12 added subtasks are 2 done / 0 remaining;
  its ten original checklist items still require the remaining profile work.
  Current-pair affected-file regression: 207 passed, one existing real-provider
  exclusion, 145.3 seconds. The subsequently added public trace/local HTTP
  model witness passes with its complete 11-test file in 10.6 seconds. Floor
  pair runs the final complete affected files: 208 passed, one existing
  real-provider exclusion, 146.1 seconds. Compilation, formatting, documentation
  ordering and dependency direction pass. Complete immutable test outputs:
  `/private/tmp/loopex-m7-ephemeral-trace-current-20261002.log`, SHA-256
  `88c68b87765b7b3dd1882a207da544cac281ab750b864f07df6401a6f23b27fe`;
  `/private/tmp/loopex-m7-ephemeral-trace-model-current-20261002.log`, SHA-256
  `bfc60271f76e37f176d07f113c68573a88d9d37a94a9236e194bd5ad9a2606cf`;
  `/private/tmp/loopex-m7-ephemeral-trace-floor-20261002.log`, SHA-256
  `d1691fc3598d913ad6c5c861cdb5724988abc02b603747845e6232587e4d6709`.
  Development failures remain retained: the first compile found a trace-handle
  variable left outside its new phase's scope, corrected by fetching the exact
  registered handle; the first new test run exposed incorrect test assumptions
  about root/facade monitor counts, increasing trace counters and an owner that
  already retired after automatic cleanup. The loss proof now kills the drain
  during an observed active stop and proves an unconfirmed result across retry.
  Failed outputs: `/private/tmp/loopex-m7-ephemeral-trace-baseline-20261002.log`,
  SHA-256 `81c76b7379d051f56f45cee376554bff3bfb52f215011f108927ccdb74f863de`;
  `/private/tmp/loopex-m7-ephemeral-trace-first-20261002.log`, SHA-256
  `2697782ba841271f4a225dbfc4cd5500750aef6db2913318f2bcd1e9df103cef`.
  No required check, timeout or cleanup proof was weakened. The first full
  check of the committed integration failed on the protocol fixture; the
  complete failed output and verified repair are recorded above.
- Done: trace selector resolution now lives in composition and both CLI
  configuration callers use that same compiled trusted-module inventory.
  A shared pure validator translates the accepted binary-keyed host trace map
  into enabled plus closed runtime configuration, with a diagnostics-only sink.
  Disabled tracing still validates all authored fields; unknown selectors create
  no atoms, and inspection starts no applications or trace. The old CLI-only
  implementation is removed. Both pairs pass the complete composition trace
  configuration/consumer files, 16 tests in 0.6 seconds each, and the three
  CLI selector/schema/options files, 30 tests in 0.09 seconds current and 0.1
  seconds floor. Compilation, formatting, documentation and dependency direction
  pass. The dependency gate first refused the untracked new sources; staging
  their ordinary 100644 blobs satisfied its identity precondition, without
  weakening the gate. Complete test outputs:
  `/private/tmp/loopex-m7-trace-selection-current.log`, SHA-256
  `98b8fbb3234fb437f3609c68deb61fda358b2e7af3f4682e2d596f97a068a969`;
  `/private/tmp/loopex-m7-trace-selection-floor.log`, SHA-256
  `3abff825408bbef55c6df672cb607d317f6c4cc73e3a1a353f2d69357c728b8e`;
  `/private/tmp/loopex-m7-shared-trace-cli-current.log`, SHA-256
  `f9bb54f3d1b0fe8454c1dc042f2b6e8b0837c3c4751668f9164022e284147468`;
  `/private/tmp/loopex-m7-shared-trace-cli-floor.log`, SHA-256
  `ebe2ad33729bc295b9328a03101249274decddca553cb4d951d4026f861546be`.
  Embedded startup still rejects the not-yet-integrated trace option; the new
  pure validator cannot silently enable or discard an authored trace request.
  This completes one added T10 subtask. One T12 integration subtask now tracks
  the expanded ephemeral actor/cleanup proof. Original checklist: 28 done / 158
  remaining. Added subtasks: 93 done / 12 remaining.
- Done: a shared host diagnostic consumer drains the existing private sink while
  a separately supervised one-entry IO worker is stalled. Its explicit pending
  queue stays at 256 bounded entries; excess and shutdown-discarded entries
  count by trace/ordinary kind. Acknowledged writes count as emitted, and
  unacknowledged writes remain delivery-unconfirmed through failure and closing.
  The drain's observed 6,000-message mailbox backlog is deliberately separate
  from its proved output queue/writer bounds. Owner loss, abrupt drain and
  supervisor loss, broken output, buffer-status redaction, serialized writer
  capacity and expired shared deadlines are proved. Both supported pairs pass
  all ten tests in 0.6 seconds each, with warning-free compilation, formatting
  and documentation ordering. Complete outputs:
  `/private/tmp/loopex-m7-diagnostic-current-verified.log`, SHA-256
  `4725cac08f1b2e61d9a397d40c3bf3f64072be8c57d0c04759bf322a513b826a`;
  `/private/tmp/loopex-m7-diagnostic-floor-verified.log`, SHA-256
  `d1cbd73db366fa34d98e1ac2a3e43dcca730bc56cfad9866f1abd7e055235987`.
  This completes an added T10 subtask. Chat, ask and daemon startup/trace
  integration remain open; no original item is closed by the consumer alone.
  Original checklist: 28 done / 158 remaining. Added subtasks: 92 done / 11
  remaining.
- Passed: the full fast check ran once on
  `611b2541bc2c68b515769dcb0f7a63055f9a0d8a` in a new managed checkout.
  Its dependency root is a real ignored directory, and exact HEAD plus complete
  porcelain status were checked before the run. The former check worktree is
  archived. All eleven application suites pass: 3,101 tests passed with 34
  existing exclusions in 960 seconds. Complete output:
  `/private/tmp/loopex-m7-611b2541-fast-check.log`, SHA-256
  `2bf7d0a6772e04dff1b36c798fd2b344b1b968eb91ef0fe4c3bd15dd4c8e277e`.
  This run replaces no failed evidence and no same-candidate suite is repeated.
  Archival of this completed check worktree was requested after output retention.
  This exact candidate includes the control codec, not the later consumer.
- Done: the closed input, question and error control encoder preserves opaque
  identities and canonical quantity encodings, refuses missing/extra members
  and malformed producer-specific choices, and counts the prefix and LF in
  the exact 65,536-byte ceiling. Escaped hostile question content stays within
  one physical record. Maximum admitted question content and oversized legacy
  identities are proved without truncation, including delivery through the
  independently draining writer. Wait, status, closing and the owning driver
  remain open; this completes one added T10 subtask, no original item.
  Both supported pairs pass the three complete control/input/output test files:
  29 tests, 5.7 seconds current and 5.4 seconds floor. Warning-free compilation,
  formatting and documentation ordering pass. Complete outputs:
  `/private/tmp/loopex-m7-chat-control-current-final.log`, SHA-256
  `078e3031d97c8e7fc00c7bd2b1a46e3181f8b7902195a6986983c41642f0c5f9`;
  `/private/tmp/loopex-m7-chat-control-floor-final.log`, SHA-256
  `bda4979fbed7c66fc06d9d4a7f56f9b1e396e80b7f47a23f1756055b224b5fb8`.
  The first run passed its tests but exposed a dynamic-range guard warning;
  the guard now uses explicit comparisons. That initial output is retained:
  `/private/tmp/loopex-m7-chat-control-current-first.log`, SHA-256
  `a44cbc6fb5609081f5e27f9f0a7e6f54c4badb8a7e5cc33e6b3d9e205044df35`.
  Original checklist: 28 done / 158 remaining. Added subtasks: 91 done / 11
  remaining.
- Failed evidence retained: the full fast check on
  `39f57d8b13787761c799b78e51bb785c76a15a03` exited 1 with two provider fixture failures.
  Its isolated checkout contains an untracked dependency symlink: `/deps/`
  ignores directories, not symlinks. The clean-source fixtures correctly refuse.
  This is a check-setup failure, not PASS: 3,090 tests passed, two failed and 34
  existing exclusions remained. The clean-source fixtures in provider companion
  entry and child-environment conformance both refused; no gate was weakened.
  Complete output: `/private/tmp/loopex-m7-39f57d8b-fast-check.log`, SHA-256
  `17031200b7a03b5033aadfe6c2b342d8e1cb5d5b9b7e665a0c2525e79616b97a`.
  The setup symlink was removed after the check finished and worktree archival
  was requested; the retained output is outside it. The next integration candidate
  must use a real ignored dependency directory and prove its checkout clean
  before running. Do not rerun the same full candidate as a pass.
- Done: observation boundary review preserves the existing opaque command
  identity range and reports absent identities through 65,536 bytes as pending,
  including IDs larger than the Store's 256-byte transaction-identity ceiling.
  Current ordinary and resource admissions keep their existing narrower Store
  and resource validators. A retained structured command-size refusal now
  exposes its stable command_admission_too_large code, rather than pending.
  The corresponding fault proof submits once, waits for observation, and still
  checks exact refusal fields and transaction conflict binding. The lifecycle
  fault matrix also submits the authored command once and observes resolution.
  Both pairs pass all 39 observation/context-admission tests, 50.6 seconds
  current and 50.5 seconds floor, plus all 14 lifecycle tests in 21.8 seconds
  each. Outputs and SHA-256 digests:
  `/private/tmp/loopex-m7-admission-observation-current-final.log`,
  `739151f2418985767c27b16107d3d615e1200a416763526d8861a073c4d85816`;
  `/private/tmp/loopex-m7-admission-observation-floor-final.log`,
  `0dfdd58e620cb403124581e1da12b71bb5c48a5405e030ace4ed729bb9e5492d`;
  `/private/tmp/loopex-m7-admission-lifecycle-current.log`,
  `4754542fa1b4e4287ee58ac57447f0a719fb2a77eb75906ca6563c26ff781752`;
  `/private/tmp/loopex-m7-admission-lifecycle-floor.log`,
  `682153a00d9e06c8c506607b042d6e2e7d28fcb339752741c1f5ee198e9ac319`.
  The earlier full fast check on
  `96cff19fdd7ae8b712513cbea5f252ceb149f925` was deliberately stopped when
  review found the observation-boundary defects. Its preliminary gates passed;
  its suite did not complete. This is interrupted evidence, not PASS:
  `/private/tmp/loopex-m7-96cff19f-fast-check.log`, SHA-256
  `04a8aea1cca567ea4b02f7b5e5d35ea2e5eb7fff9bfe45523eb9f49fb052af2e`.
  Run the full fast check once on this corrected committed candidate.
- Done: the full fast check passes once on unchanged integration candidate
  `35ec8929274d7f355ed63a157d80fe6b32917763`, across all eleven applications:
  3,077 tests passed with 34 existing exclusions, in 888 seconds. Complete
  output: `/private/tmp/loopex-m7-35ec8929-fast-check.log`, SHA-256
  `8efb7b585be8f7627f196dc2697974cbcfa9dca634b31af1a5149e2a235e3304`.
  This proves the current integration, not the
  unfinished M7 outcomes or its floor/release closure matrix. No suite repeats
  on this candidate. The following evidence-only commit does not change source.
- Done: original T10's unknown-admission resolver and three added subtasks are
  complete. The attachment-based observation API reads replay-derived command
  facts without Store calls, activation or dispatch. Missing identities stay
  pending; only an exact conclusive Store refusal proves not_committed. Question
  answers retain their interaction's committed run identity through recovery.
  The first unknown command reply returns immediately. Every later exact
  transaction presentation runs in an owner-owned worker on a 100-ms tick,
  within one first-unknown plus committed cleanup backstop. Other commands keep
  the fenced reply; no authored command is resubmitted. Conclusive adoption
  starts normal abort cleanup before draining deferred scheduling, worker and
  timer signals in arrival order. Real two-second run deadlines, both actual
  22,001-ms backstop paths, owner loss, executor receipts, resource transaction
  identities, before/after persistence and recreated owners are proved.
  The nine complete affected Core files pass 211 tests with one existing
  long-bound exclusion on each supported pair, 132.9 seconds current and
  132.8 seconds floor. No retry or timeout was inflated. Warning-free compilation,
  formatting and compiled documentation pass. Complete outputs:
  `/private/tmp/loopex-m7-admission-current-verified.log`, SHA-256
  `31ec638266ec042910519fa6ecc0e94053a20483b148c525fa939cac574e3bee`;
  `/private/tmp/loopex-m7-admission-floor-verified.log`, SHA-256
  `1a8e454600e71dabcee4aefd916a3d04dd637468ecf8fc31f82b0c669b6a2813`.
  Original checklist: 28 done / 158 remaining. Added subtasks: 90 done / 11
  remaining. The chat driver and its pipe-ordering obligation remain open.
- Next: join the shared diagnostic consumer and accepted trace configuration
  into owning startup and teardown, beginning with T12's private ephemeral
  owner. Its current granted startup registers each actor before activation;
  diagnostics must join that registration and loss/fault proof. Trace activation
  follows capability binding and precedes dispatch. Consumer and writer cleanup
  need an explicit joined certificate within the existing shared shutdown bound;
  parent DOWN alone cannot prove a nested IO worker gone. Preserve the absent/
  disabled default and keep rejecting enabled startup until the lifecycle is
  integrated. Complete the remaining chat control records
  and join the owning driver after the exact-genesis
  creation decision. The creation, preparation-store and refusal-schema questions
  were bundled again for the maintainer; no dependent contract change is made.
- Done: T07's bounded source selector scans complete eligible-unit prefixes,
  retains the largest passing complete maintenance-request preflight and uses
  serialized-message bytes for the 6,144-byte small-prefix threshold. A small
  prefix consumes its next oversized eligible unit through a marked excerpt;
  refusal of every quota cannot fall back to the small complete prefix. The
  fixed quota order is tested independently of source-cap fit, and cancellation
  before another lazy unit is read preserves the caller's failure. Entire
  assistant/result groups remain covered, with their full-list count and digest.
  Both supported pairs pass 49 source, summary and conversation tests in
  0.4 seconds each. This selects from an owner-supplied eligible range; tail
  release, actual request construction, episode persistence and dispatch remain
  open. No original T07 item is closed by this local selector alone.
  Current output: `/private/tmp/loopex-m7-compaction-selection-current.log`,
  SHA-256 `6156487bdf743bd71d9a80cc98b18f9495ef362d81967f639e3b9f9f3451d6c0`.
  Floor output: `/private/tmp/loopex-m7-compaction-selection-floor.log`, SHA-256
  `7987c014ab139640d59a5f61d38697af3be710e5c1c7116a4a31c395cb3ecd05`.
- Done: original T09's remaining runtime boundary tests are complete. Direct
  denial and policy deferral create no question or executor effect. An exact
  8,192-byte answer remains admitted, replayable and recoverable when the next
  request exceeds either its 700-token input ceiling or the 65,536-byte Store
  record ceiling; neither case dispatches another model call. A live two-second
  deadline/question-expiry race commits one terminal settlement, preserves its
  actual disposition through recovery and refuses a late answer. Together with
  existing large-answer, duplicate/conflict, cancellation, expiry-boundary and
  fault cases, both complete lifecycle files pass 51 tests on each supported
  pair: 17.6 seconds current, 17.5 seconds floor. Public question event/record
  vectors and the coordinated /3-/4 mutation paths remain open added subtasks.
  Current output: `/private/tmp/loopex-m7-question-boundaries-current-final.log`,
  SHA-256 `0ab48c6cd97ced22b132ae33f60d6bf8f78404478075d50c2ed1d30bd3d81c8f`.
  Floor output: `/private/tmp/loopex-m7-question-boundaries-floor.log`, SHA-256
  `06433ce1e0118081343dc77fd23304b40780038e7bbda61e8825ac1b5434c4e5`.
  Initial vectors had an inconsistent system/input budget and treated the
  ordinary deterministic term encoding as JSON. Corrected vectors use a valid
  configuration and a 24,000-byte retained prompt; production admission,
  assertions and limits remain intact. Initial failed output:
  `/private/tmp/loopex-m7-question-boundaries-current-first.log`, SHA-256
  `2f8953aee654e0eaf9c8ccf627cb660178c19640667dd794b8c9f580a12ff5d3`.
  The undersized vector's failed complete lifecycle output:
  `/private/tmp/loopex-m7-question-boundaries-current-verified.log`, SHA-256
  `7bb3d6f654a4826eb33d9cca34a5f4d097cb6e62eda02bd7f90d05db8fb9b845`.
  Its measured byte diagnostic: `/private/tmp/loopex-m7-question-byte-measure.log`,
  SHA-256 `fe11c55459710866aa1a58269516e4cb461023aa5cf51464823ef419250550f5`.
- Done: original T04's authored conversation-bounds requirement is complete.
  Removing any one of max_turns, deadline_ms or token_budget refuses with its
  exact file pointer even when all three matching flags are supplied. A valid
  complete file admits the overrides with flag origins. The full preparation
  path creates no state directory in either case. Configuration/schema/selection
  verification passes 40 tests on each supported pair, 4.6 seconds current and
  4.7 seconds floor. This closes only that original item; chat dispatch, effective
  inspection and remaining whole-profile integration stay open.
  Current output: `/private/tmp/loopex-m7-file-bounds-current.log`, SHA-256
  `37b4a6df8a3d04c7516cef7d81f04bfe33fbc9287ba95850e1c4889f65d3b19d`.
  Floor output: `/private/tmp/loopex-m7-file-bounds-floor.log`, SHA-256
  `f105edfb7686fc28918d318b39ec9bbaa10577cbe0445325c3a3eee2dbc27498`.
- Done: T07 admits maintenance replies through the existing whole-callback
  provider boundary, retains their exact canonical usage, and checks natural
  completion before calls or output. Nine-key v2 replies fail as incomplete;
  unreadable callbacks provide no admitted reply. Closed summary/carry-forward
  limits now share one validator with prior checkpoint reuse, including all
  escaping, path, list and combined-envelope bounds. No checkpoint is committed
  by this validator; progress, cancellation precedence and owner integration
  remain open. Eight new cases plus source, provider-ceiling and configured
  recovery regressions pass: 47 tests on each supported toolchain, 3.7 seconds
  current and 3.5 seconds floor.
  Current output: `/private/tmp/loopex-m7-compaction-summary-current.log`, SHA-256
  `776ffbf02496750074b4856841fb353ae028b03cbda139b855558582b68655b1`.
  Floor output: `/private/tmp/loopex-m7-compaction-summary-floor.log`, SHA-256
  `41c9ca0cf23b23e3f30d8f2432a8a8df6690c14bca62a0ec5866d53f03945d86`.
  Initial test fixtures used the conversation call field instead of provider
  callback `id`, and expected usage `kind` instead of the existing `status`.
  Those fixture shapes were corrected; production admission was preserved.
  Initial output: `/private/tmp/loopex-m7-compaction-summary-current-first.log`,
  SHA-256 `d7caaafb57662bafce7b1ebbcd9cff1a216ddfad1ce4c143883295dfafbf3b02`.
- Done: T07's source-v2 encoder streams canonical messages into exact counts
  and SHA-256 without collecting the whole projected list or serialized unit.
  It retains at most a 16,384-byte complete candidate and two 4,099-byte end
  buffers, checks cancellation/deadline between bounded chunks, and emits the
  fixed quota candidates with UTF-8-safe disjoint fragments and an omitted
  middle. Envelope framing, prior checkpoint and fragment escaping spend the
  source cap. Closed message/call shapes exclude private fields; admitted float
  and large integer arguments survive. Selection and full request preflight
  remain the owner's future integration work; this encoder dispatches nothing.
  Nine source cases plus grouping, lineage and real recovery regressions pass:
  67 tests on each supported toolchain, 3.6 seconds each.
  Current output: `/private/tmp/loopex-m7-compaction-source-current-final.log`,
  SHA-256 `e87685df34a4c096685e290cda1fd594688891b288c93cba2a313a24acd3d00c`.
  Floor output: `/private/tmp/loopex-m7-compaction-source-floor-final.log`, SHA-256
  `af3f93ede4ae60f9d1dab1dacdf2cd721b7ddac75030811a08e37eec8c9c326f`.
  The initial run failed one test because its NUL vector did not cause the
  intended second-escaping overflow. A quote/backslash vector now does; no
  quota assertion was relaxed. Initial output:
  `/private/tmp/loopex-m7-compaction-source-current-first.log`, SHA-256
  `875db77fd37fe51d9119e3b14e2f522878a1328a0af321c2f2af08dcbe45b2a8`.
- Done: T07 now derives indivisible assistant/result groups with preceding
  same-run inputs and trailing input-only units. Current work, unfinished groups,
  pending interactions and every unit containing a frozen native-prefix source
  remain protected. Idle sessions can release their terminal history. This is
  selection-unit construction; request sizing, tail release, checkpoint storage
  and maintenance dispatch remain open.
  Eight new cases plus existing lineage and configured-session regressions pass:
  58 tests on each supported toolchain, 3.7 seconds current and 3.6 seconds floor.
  Recovery of a real two-run journal preserves the exact units after restart.
  Current output: `/private/tmp/loopex-m7-compaction-units-current-verified.log`,
  SHA-256 `98b536b84d58c622babd85832fc8eab79ada7c2d1ae41a9380eb3d92b492cb87`.
  Floor output: `/private/tmp/loopex-m7-compaction-units-floor.log`, SHA-256
  `5e3d32f57be8d308c3d3dd7574cd9201b6a9e7874d3567b083fdfbcfec13fe63`.
- Done: the resumed full fast check on `ba0d453f5317b64ac4e47eb794e8db63d7c0f717`
  passes all eleven application suites, 3,036 tests with 34 existing exclusions,
  in 890 seconds. Complete output:
  `/private/tmp/loopex-m7-ba0d453f-fast-check.log`, SHA-256
  `d1bb5747ca8c491110159d12ef6215038b6a036d0791b30a34bc9d025153dd8a`.
  The prior two failures remain retained; their repaired candidate is now proved.
- Done: four initial M7 fixture roots and independent oracles cover ledger
  repair, both possible row-default choices, the exact duplicated-fee finding
  and generated long-conversation file facts. Four positive/negative control
  cases pass on each supported toolchain. Complete manifest/schema pins,
  required question/helper calls, checkpoint/restart witnesses and provider
  execution remain open.
- Done: original T01 is complete, including live conversation after failure and
  prompt commit uncertainty on either side of persistence. The real-provider
  conversation witness remains a separate release obligation.
- Done: T02 exact-generation capability checks now guard runtime admission,
  registry loading and the local executor's compiled tool inventory. Original
  checklist completion is 27/186 items and 2/20 original top-level tasks.
- Done: T02 attachment-budget baseline audit distinguishes existing attachment
  limitations from the required job-owned bounds. Snapshot creation failure now
  closes its source descriptor before returning; both toolchains prove the repair.
- Done: T02 pure range-result encoding selects the largest UTF-8 prefix within
  the complete 8,192-byte conversation-message limit, including double escaping,
  normalized call identity and metadata. Local storage and executor integration
  now pass real range tests. The real session-owner path preserves receipt-owned
  ranges across restart. Receipt-owned excerpt staging and replay now work;
  prepared references and earlier spill thresholds remain open. Legacy v2/v3
  sessions preserve full inline results after object deletion and registry-free
  restart, completing the original legacy-inline compatibility item.
- Decision recorded: on 2026-10-01 the maintainer selected the separate optional
  `ArtifactStore.read_job_range(handle, validated_job)` callback for job reads.
  The local callback now verifies real objects with shared transfer capacity,
  reserved work and a linked deadline watchdog. Exact 1.1.0 executor dispatch now
  uses that callback, refuses adapters without it and retains readable receipts
  through restart. Existing attachment callbacks remain compatible.
- Done: configured chat captures read 1.1.0 through composition's admitted
  inventory. The legacy active read stays pinned to 1.0.0; both are registered.
  Durable composition always owns the shared job transfer process, including
  empty current tool selections. Public attachment access remains explicit.
- Done: the pure T02 receipt-content formatter proves the largest UTF-8 prefix
  within the complete 2,048-byte tool message, including double escaping and
  reference metadata. Source ranges bind the original receipt bytes. Ordinary
  staging, replay, frozen prefixes and shared allocation are now joined for
  receipt-owned references. Oversized inline sources still need preparation.
- Done: T02 resolves committed-receipt artifact membership before policy and
  binds approved ranges to their exact source in the journaled job. Prepared
  references remain open. The receipt-owned range workflow is now proved with
  the real local journal, executor and artifact store across restart.
- Done: reproduce cross-run conversation loss with the real session-owner path
  and a scripted model in `apps/loopex/test/agent_loop_test.exs`.
- Done: run-scoped result joins, replayed admission order, revision-1 normalized
  call identities and strict complete-lineage validation. These are projection
  foundations; the coordinator now stages the complete committed lineage.
- Done: v2 request staging, revision-4 nil-continuation receipts, exact lineage
  replay validation, and terminal-derived unknown/cancelled call results.
- Done: conversation integration candidate fast check; all 11 suites pass
  2,638 tests at `2d804649ca82ce87b58511bc0739c93e700c7559`.
- Done: pinned artifact-read generation vectors and pure capability binding;
  instruction capture/render validation preserves exact legacy staging bytes.
- Done: shared v3 genesis normalization/resolution and pure replay retain closed
  configuration, exact tools, artifact-read binding and policy-defer mode.
- Done: exact-genesis live creation and configuration-bound runtime staging;
  two prompts plus restart retain captured instructions, settings and tools.
- Done: captured-configuration runtime candidate fast check; all 11 suites pass
  2,679 tests at `d46c8d10881e6ba811b6c1d5204c9545aa785d37`.
- Done: reference-host instruction capture, exact environment JSON rendering,
  bounded base/appendix/role files and retained-content byte fixtures.
- Done: bounded host JSON syntax decoding with duplicate-key pointers and exact
  integers; pure provider-reference validation against the adapter catalog.
- Done: closed authored-file schema, bounded selected-file loading and relative
  path resolution; trace selectors resolve through trusted module manifests.
- Done: chat/config inspection flag parsing, duplicate/conflict rejection,
  repeatable array selection and exact numeric-domain validation.
- Done: new-session precedence composition and per-value origins, including
  flag/environment/file selection and harmless literal defaults.
- Done: bounded model-limit capture from the verified pinned packaged catalog,
  preserving unknown limits and the one accepted literal Haiku alias.
- Done: shared pure initial-configuration resolution derives context ceilings
  and their origins, validating captured instructions and all selected schemas.
- Done: exact v2 question-tool definition, pinned canonical preimage/digest,
  argument admission and interaction-versus-executor dispatch separation.
- Done: committed model-question requests and atomic answer, decline, expiry and
  abort settlement retain the original call and response identity through replay.
- Done: live owner succession at all four pending/response commit boundaries
  retains one question and one settlement without repeating provider work.
- Done: commit-unknown recovery re-presents exact question/response payloads;
  disk-backed Store restarts retain the pending identity and settled answer.
- Done: shared closed answer normalization and literal answer payload/schema
  vectors pass both the Elixir and independent Node decoders.
- Done: pure whole-candidate configuration updates validate every mutable member,
  advance one version and recompute derived ceilings while retaining explicit ones.
- Done: pure atomic configuration admission/replay retains exact command identity,
  one instruction copy, unchanged earlier run captures and an allowlisted event.
- Done: terminal-tool-history capability preflight validates complete lineage,
  treats empty assistant completions as absent and gates configuration replay.
- Done: configured ordinary staging checks terminal-history capability before
  request intent, committing an unavailable v2 preparation refusal and terminal.
- Done: reproduce and fix false OwnerGroup shutdown_error/noproc reports while
  preserving parallel shutdown, owner-worker barriers and actual fault reporting.
- Done: join host-prepared ordinary configuration to live owner admission, exact
  retained-history sizing, atomic commit, restart and commit-boundary fault proofs.
- Done: implement shared bounded content-reference expansion and pure exact native
  block capture, preserving text slices, ordered arguments and both JSON ceilings.
- Done: prepare strict M7 callback projection and source-bound v3 settlement
  readers, including monotonic cutover and unchanged historical reply shapes.
- Done: emit v3 for every new ordinary settlement, migrate exact callback
  fixtures and preserve conservative accounting and historical reader schemas.
- Done: source-bound ordinary continuation envelopes, full expanded costs,
  frozen project content through owner recovery, native-ID collision refusal,
  and independently replayed aggregate-overflow preparation failures.
- Done: bounded native Anthropic event assembly and pinned SSE parsing/flush
  checks preserve signatures, block order and final usage with permanent failure.
- Done: captured-cell native request rendering, exact tool/limit preservation
  and final Finch request sealing against the pinned dependency's mutation hooks.
- Done: join native capture/rendering to the durable worker's ReqLLM transport,
  with strict replies, eligible summary projection, fatal wakeup and owned drain
  cleanup; resolve canonical tool names through their complete generations.
- Done: repair the historical interaction control, complete CLI/daemon native
  fixtures, retain Core accounting witnesses over actual provider transports,
  and route config model validation through composition.
- Done: join buffered native capture and request rendering to OneShotHTTP1,
  screen captured private values for the selected key, and keep native request
  bytes out of Finch metadata through one-use invocation-owned body streams.
- Done: register all nine literal adapter cells after deterministic native
  conformance; share exact mapping resolution with transport validation.
- Done: join new-session host selection to explicit provider routes, captured
  instructions, exact mappings and whole-configuration admission.
- Done: validate and capture explicit Core maintenance settings, forward them
  privately to session owners, and resolve the host's separate thinking-off
  summarizer with fixed-budget native transport conformance.
- Done: validate maintenance instructions before durable/ephemeral owned effects
  and forward them through every durable constructor and ephemeral SessionOwner
  into the real runtime and coordinator.
- Done: join explicit ephemeral provider bindings to committed-model dispatch,
  caller-only credential resolution and separately resolved maintenance startup.
- Done: full fast check of the maintenance/ephemeral-routing integration at
  `7c266c4678776908b159bea13927117e1bf40bd7`, with all 11 suites passing.
- Done: admit closed durable token-route maps and select exactly one token from
  the committed request before provider-process startup, retaining the existing
  private credential bootstrap and cleanup path.
- Done: shared explicit durable binding loading and version-2 plane construction;
  borrowing hosts retain custody while issuing fresh trace capabilities.
- Done: executor-local launch exclusions reach ordinary jobs and cleanup helpers;
  first images exclude all 17 names even when reintroduced after the snapshot.
- Done: validated credential exclusions reach project revision discovery, skill-import
  executors and placement probes; placement release accepts the same scoped probe.
- Done: direct and borrowed version-2 durable startup validates complete planes,
  selected routes and maintenance models before owned effects, then forwards
  immutable exclusions to Store, executor and provider launches.
- Done: consolidate constructor preflight in DurableOptions, restoring the
  reference composition to 154 effective lines under its unchanged 180-line gate.
- Done: daemon bootstrap validates explicit bindings before placement/environment
  effects, uses shared custody loading, forwards model/maintenance options and
  preserves classified cleanup for every custody plus scoped placement exclusions.
- Done: offline CLI startup caches explicit bindings across compositions, refuses
  rebinding, forwards model/maintenance options and scopes discovery/placement
  exclusions. Chat, daemon-command and remaining host entrypoints are unfinished.
- Done: full fast check of `cf7e875f61e86538867d54135a7c136e235e3ff1`,
  all 11 application suites passing in 970 seconds.
- Done: foreground app-server programmatic provider options, with whole-map and
  selected-route preflight, fixed missing-credential refusal and real two-route
  startup/EOF cleanup. Host and policy witnesses pass on both toolchains.
- Done: bounded chat line reading and explicit command parsing, with no read
  beyond a wait line, exact answer decoding and malformed-input refusal.
- Done: bounded independently draining chat output and quoted transcript
  rendering, including progress eviction, unchanged control deadlines, inherited
  shutdown bounds and joined IO-worker cleanup on both supported toolchains.
- Next: join configuration preparation, ChatInput and ChatOutput to the runtime-
  owning chat driver and closed control records for the first complete workflow.
- Done: new-chat preparation captures exact v3 genesis from file/flag selection,
  instructions and immutable tools. Explicit question selection reaches every
  durable constructor. Configuration and constructor tests pass on both supported
  toolchains, including real durable creation and restart. Chat dispatch is still open.
- Decision pending: expose captured genesis through the existing Loopex creation
  facade, or keep that facade unchanged and route chat through composition to
  the accepted host-private exact-genesis operation. No dependent public API
  change has been made.
- Decision pending: provide Core a separate optional `artifact_preparation_store`
  using the existing ArtifactStore put contract, or enable the existing public
  transfer store whenever preparation is needed. Separate preparation access is
  recommended so composition's `artifact_transfers: false` keeps its behavior.
  No dependent startup-contract change has been made.
- Decision pending: ADR 0043's required-only refusal counts cannot describe an
  oversized ADR 0044 frozen request containing project/resource blocks. The
  proposed v2 amendment adds explicit counts for those classes. Do not implement
  the dependent refusal schema without the maintainer's decision.
- Next: complete whole-profile and startup integration, maintenance
  quiescence and checkpoint-aware configuration preflight; complete question
  projection/private-record vectors and the remaining M7
  configuration/maintenance/bound payloads before the coordinated /3-/4 switch;
  continue prompt-file and mapping
  preparation, effective inspection and command entry wiring, then live
  chat/configuration composition and maintenance accounting in T04/T06/T08.
- Remaining: all unchecked tasks below. Closure, main integration and release
  retain their explicit maintainer decision gates.

## Development observations

- 2026-10-01: observation-boundary verification initially used a 257-byte
  ordinary command ID, exceeding the existing Store transaction-ID ceiling,
  and omitted one use of its fixture binding. The corrected vector admits an
  opaque 256-byte ID and separately observes an unknown 65,536-byte ID; resource
  validation keeps its existing 256-byte UTF-8 bound. Retained failed output:
  `/private/tmp/loopex-m7-admission-identities-current.log`, SHA-256
  `109984b559d536c9f58ede35acc687e9e1008e6a2993996d3c814922bfde55c9`.
  The first context-admission regression expected the earlier synchronous
  post-unknown refusal. It now observes the accepted timer resolution, while
  retaining every exact-byte, limit, no-dispatch and conflicting-binding proof:
  `/private/tmp/loopex-m7-admission-observation-current-verified.log`, SHA-256
  `2491862e1c8840cac2247bd2282ffb37f89dca1df158249f39a4872116e20e7f`.
- 2026-10-01: admission verification first exposed three test setup defects:
  missing steer run ID, missing model script and a Store fault matching later
  abort settlement rather than just the original admission transaction. The
  wrapper now binds the first target transaction ID and records the actual
  callback caller. Retained failures:
  `/private/tmp/loopex-m7-command-disposition-current-first.log`, SHA-256
  `9d2135afbbc330d89ac7bac3bf3e761af3207f632e912802cff9ef6fd7896591`;
  `/private/tmp/loopex-m7-command-disposition-current-second.log`, SHA-256
  `30a9fd61fb90443fa22be1fa6aba40d66a2c760210c68a4d96017fc8671fbada`.
  Bounded blocking-call diagnosis:
  `/private/tmp/loopex-m7-abort-resolver-stack-bounded.log`, SHA-256
  `d9ae23f9fbf8aeb61593ffd172af79124c0c32c0b5b84252c3db26f1f71f01f4`.
  The first broader run used a nonexistent run.admitted event in a new assertion;
  it now checks the real user.message_appended and run.started facts:
  `/private/tmp/loopex-m7-admission-current-regressions-first.log`, SHA-256
  `5ec7c874413899df3e046f3c142128fe628dce2e5023e4def5a4ba2dc9d4838c`.
  Review also reproduced a production ordering defect: draining a deferred
  advance_work before establishing the resolved abort's cleanup fabricated
  outcome_unknown. Restoring held signals for selective cleanup reads and
  starting normal cleanup before queue reduction repairs it. The regression
  retains the scheduling-before-result interleaving and expects cancelled:
  `/private/tmp/loopex-m7-admission-abort-order-repro.log`, SHA-256
  `58142016b8777a0ef7df5fe5bfc21195e17b6cde29d99f53a370687b6b7925bf`.

- 2026-10-01: T00's base oracles run outside each disposable workspace;
  fixture implementations and generated outputs stay in the workspace.
  Repair rejects the seeded empty-ledger failure and accepts exact signed sums.
  Feature independently checks the chosen default and both explicit modes;
  no default is selected for a real task by these controls. Review requires the
  exact bounded TSV finding and call-chain sequence while preserving every
  workspace byte. Long checks actual files against `amber` and batch size 3.
  The tests exercise the oracles directly, with no provider or runtime startup.
  Current: four cases in 4.8 seconds, output
  `/private/tmp/loopex-m7-base-oracles-current.log`, SHA-256
  `9ed6d7cf7563a5f9338099dbfbb68af0bfcb5284d9efadc83456a05acbcf3a6c`.
  Floor: four cases in 4.6 seconds, output
  `/private/tmp/loopex-m7-base-oracles-floor.log`, SHA-256
  `c718cc9e188cbeca05626f3e698cbfa37a71bef6cdb44fe97e53e530c71df5f0`.
  The first control run failed because it expected exit 1 for failed ExUnit
  assertions; both supported versions document and return exit 2. The controls
  now require that exact code without changing the task assertions. Retained
  first output: `/private/tmp/loopex-m7-base-oracles-current-first.log`, SHA-256
  `a9d1d226952053f277e993fcb84c62ee41d42f23302d0ab1818f4b76b35ea9c4`.
- 2026-10-01: ChatOutput admits rendered bytes only from its creating host,
  counts active and queued writes together against 256 KiB, evicts queued
  progress before required output, and never truncates a control record above
  65,536 bytes. Its independent IO worker is linked and monitored. A successful
  finish follows worker termination; IO failures, overflow and the original
  five-second control deadline seal the writer and notify the host once.
  Later progress and finish preserve an earlier deadline; an existing host
  shutdown deadline can shorten finish. Owner loss joins blocked IO, and abrupt
  manager loss kills its linked worker. OTP status excludes buffered text.
  Render.chat_text prefixes every model/tool line, escapes terminal and Unicode
  format controls, terminates a final fragment before the next host record and
  refuses invalid UTF-8 or expansion beyond the queue limit. Eleven cases pass
  in 5.6 seconds on current and 5.4 seconds on floor. Closed control schemas,
  driver integration, real pipe/PTY tests and the prescribed Linux load runs
  remain open; no original checklist item is closed by this standalone stage.
  - Current: `/private/tmp/loopex-m7-chat-output-final-current.log`, SHA-256
    `0971b7c3633f6c2ca417bd8b0d8c457af324e423786cf5e3db03021e2e0c5cea`.
  - Floor: `/private/tmp/loopex-m7-chat-output-floor.log`, SHA-256
    `6110f49e17f378aca7166170c74ed378f32905092979a08dc628675339d91ce9`.
  - Initial nine-case pass: `/private/tmp/loopex-m7-chat-output-current.log`,
    SHA-256 `3d1639b6b85e21fcd3f234283e75149eb8782e5081fa7ff998f52c6be0bdeedd`.

- 2026-10-01: ChatConfiguration joins the existing explicit file/flag resolvers,
  required paths, exact instruction capture, selected tool definitions and
  shared genesis resolver without credential loading or runtime startup. Coding
  and read-only profiles include the exact question generation; none is empty.
  DurableOptions registers that interaction only when explicitly selected, leaving
  omitted/default selections unchanged. The prepared genesis creates a real
  local-Store session and survives runtime restart unchanged. The complete selected
  definitions contribute to system-budget admission. Credential-free profiles
  remain valid authored input but refuse durable chat; resume and enabled helper
  preparation remain explicit unfinished paths, not silently narrowed profiles.
  No chat command entry or new public creation API is enabled by this change.
  CLI configuration/flag regressions pass 31 cases on current/floor in 4.0/4.2
  seconds; all-constructor regressions pass 17 cases in 7.7/7.6 seconds.
  - Current CLI: `/private/tmp/loopex-m7-chat-configuration-routes-current.log`,
    SHA-256 `3ed2ab06dd2cd56512e400516e685aeb9b3fdf254dc279aaac35e0d210583e93`.
  - Floor CLI: `/private/tmp/loopex-m7-chat-configuration-floor.log`, SHA-256
    `99372e515de5f7f7cc5c74b7ad26768ddda2d374c09e54aac9e5540836d851dc`.
  - Current constructors: `/private/tmp/loopex-m7-chat-tools-current.log`, SHA-256
    `d524331052cab71427df4f5cde421cc9f02926144d8d336c63580f0386ab77a6`.
  - Floor constructors: `/private/tmp/loopex-m7-chat-tools-floor.log`, SHA-256
    `2007ae84eb151456e79c8aec9d96496f023975897941f51a30c37f486b76e4fd`.
  - Initial run failed before test bodies because a fixture used ExUnit's reserved
    file field: `/private/tmp/loopex-m7-chat-configuration-current.log`, SHA-256
    `6eb804de7c5f0e9282c8b1aa5e697e37f62945593cd8ecca2f0d3410afaf9733`.
    After correcting it, six cases passed in 2.3 seconds:
    `/private/tmp/loopex-m7-chat-configuration-fixture-current.log`, SHA-256
    `7e220900bae1c021504dadc2e4f9687258cd206b586d9e8ce56577a8bd90ddec`.
    The first expanded 31-case run passed in 3.8 seconds, but its credential-free
    test used an invalid binding shape. It was strengthened to require authored
    schema acceptance and the exact durable-model refusal before the final runs:
    `/private/tmp/loopex-m7-chat-configuration-final-current.log`, SHA-256
    `ecbe9fef5322320dfbc3b2339aaa73b5ce6d170937a386f00670d165b21fd894`.

- 2026-10-01: Restored reporting against the maintainer's original numbered
  checklist after clarification. It contains 20 tasks and 186 original items;
  20 original items are checked, with all top-level tasks still open. Earlier
  86/262 reporting counted added implementation work and is not the original
  checklist's completion measure. Original T09 recovery proof is restored as
  one checked item, supported by its pure, live-owner and local-Store restart
  witnesses below; those implementation witnesses remain separate additions.

- 2026-10-01: ChatInput reads one LF/CRLF line at a time with a 65,536-byte
  pre-terminator ceiling. It consumes no next-command byte after a wait line.
  EOF fragments, bare CR, NUL, malformed UTF-8 and failed IO refuse. Explicit
  command parsing preserves prompt text, decodes question/choice wire IDs and
  JSON answer strings once, and rejects duplicate configure members. The driver
  still owns admission, input sequence/command IDs, barriers and cancellation;
  this is not yet a callable chat workflow. Nine focused cases pass on both
  toolchains in 0.2 seconds each.
  The initial floor run exposed a test cleanup race. Removing a link did not
  solve StringIO's owner monitor; the final fixture uses its callback bracket
  to close before owner exit. Failed outputs are retained, not counted as passes.
  - Initial current pass: `/private/tmp/loopex-m7-chat-input-current.log`, SHA-256
    `8c616b29c29ae70b2fe461c309b19ae779d2f1dad32dd04a2270f4a9fc87f1de`.
  - Initial floor failure: `/private/tmp/loopex-m7-chat-input-floor.log`, SHA-256
    `3bb0887f4258ac64795d4946859dd8fdabdc21bcd87e9df2630fc0054316aa3c`.
  - Unlink-only failures: `/private/tmp/loopex-m7-chat-input-fixed-current.log`,
    SHA-256 `af21dc060b326ac3fde279185552adc2dd7d0bf66fce6bb0cff15cf0da5d316d`;
    `/private/tmp/loopex-m7-chat-input-fixed-floor.log`, SHA-256
    `97fa074cf840d90d143ffeccc9fdbe1577c637f083015678ea4cb484eed6cdab`.
  - Final current pass: `/private/tmp/loopex-m7-chat-input-bracket-current.log`,
    SHA-256 `00bce9e55ed81ad771df87996509b3ab072c9b36f014d99209957eeaaee579b3`.
  - Final floor pass: `/private/tmp/loopex-m7-chat-input-bracket-floor.log`, SHA-256
    `40921e3c6f10662b016634983f2d4fdee133d2c53de3163d934bc3fa73fc5ea5`.

- 2026-10-01: The exact offline-binding integration candidate
  `cf7e875f61e86538867d54135a7c136e235e3ff1` passes the full fast check in a
  clean detached worktree. All 11 application suites pass; total 970 seconds.
  The complete output is `/private/tmp/loopex-m7-cf7e875f-fast-check.log`, SHA-256
  `1aafc2f1799a25a43b6d5d3caea88b6d92cbe79471f754ff3efc30c832ddd1de`.
  Foreground changes below were outside that exact candidate.

- 2026-10-01: Foreground `Host.serve/1` accepts the closed programmatic durable
  options without loading a configuration file. Binding and route validation
  precede launch effects. Missing explicit credentials use a fixed diagnostic.
  Real subprocess fixtures exercise invalid maps, unbound ordinary/maintenance
  routes, missing credentials, two-route startup, maintenance/tool forwarding,
  environment deletion and joined EOF cleanup of all nine owned processes.
  Host and policy tests pass 20 cases on current and floor toolchains in 6.6 and
  6.0 seconds respectively. Both runs also report the existing AllowAll notice
  table's ETS transfer to `:init`; that diagnostic is retained for investigation.
  - `/private/tmp/loopex-m7-foreground-current.log`, SHA-256
    `32c033f3cfe25befd72e4ca13f33ec00ec55f0216c670e138add7cbcd65e6b49`.
  - `/private/tmp/loopex-m7-foreground-floor.log`, SHA-256
    `e17daadf7ca27e3a339014882b66244e8207eb5a0afb8daf8272f1f12977319e`.

- 2026-10-01: The offline CLI's existing credential cache accepts an explicit
  immutable binding map and lends it through fresh trace capabilities. A changed
  map or replacement of legacy custody refuses without consuming another value;
  a failed load leaves no cached partial host. Runtime startup validates selected
  ordinary and maintenance routes before loading credentials, forwards the
  programmatic model/bounds/sampling/active-tool/maintenance options, and captures
  exclusions for project discovery and placement acquisition/release. Runtime
  composition receives the borrowed plane without a conflicting raw binding map.
  Repeated real composition reaches the Core startup boundary with identical
  tokens, distinct capabilities and original keys after environment reinsertion.
  This proves shared offline startup; the chat driver, daemon command, foreground
  server and remaining ask/helper entrypoint work stay open.
  Seven new/existing cache and offline cases pass in 1.6 seconds. The affected
  CLI, prepared-recovery, ask and context-budget regression set passes 155 cases
  on both toolchains: current 48.4 seconds, floor 47.5 seconds.
  - `/private/tmp/loopex-m7-offline-bindings-current.log`, SHA-256
    `272d38f08b0bc0ca21ac07df0ce5085963ea035da76f60bca7251dc26a07ef94`.
  - `/private/tmp/loopex-m7-offline-bindings-regression-current.log`, SHA-256
    `40911dd043f424f6b0df6d5f7e23c2c84f25ff42167915aa7605b121c9930b7f`.
  - `/private/tmp/loopex-m7-offline-bindings-regression-floor.log`, SHA-256
    `3a1707a411d60fc92a904bef5cb124012c5fc1f5b6f53d8a836f6125e89215e2`.

- 2026-10-01: Daemon Service accepts explicit provider bindings through the
  shared durable loader. Conflicting value-bearing credentials, invalid complete
  maps and unbound ordinary/maintenance selections refuse before placement or
  environment effects under the existing credential-plane startup class. Each
  unique slot gets one tracked custody; shared references reuse its token.
  The existing orderly and failed-start teardown now visit every custody before
  its registry, with custody loss retaining the existing fatal class. Fatal
  fail-stop retains ADR 0031's bounded executor/Store tail and VM-halt lifetime
  for the remaining VM-local components. No new failure class or wire record is
  introduced. Placement acquisition/release capture validated exclusions;
  composition receives the model, bounds, sampling, active-tool selection and
  explicit maintenance settings alongside its version-2 plane.
  New real-daemon tests cover route selection, private configuration, shared-slot
  deduplication, pre-effect refusals, partial loading, post-bootstrap failure,
  orderly joins and loss of either custody. The current toolchain passes 52
  initial binding/legacy-lifecycle cases in 137.8 seconds, then all six final
  binding cases in 1.6 seconds after adding post-bootstrap cleanup and complete
  forwarding assertions. The floor toolchain passes the final 53-case set in
  137.9 seconds. CLI discovery, early credential consumption and entrypoint
  forwarding remain unfinished.
  - `/private/tmp/loopex-m7-daemon-bindings-fixed-current.log`, SHA-256
    `55c12430170266af60bf95cf84c7156cee29a8f21f0d4c63393938b56a839644`.
  - `/private/tmp/loopex-m7-daemon-bindings-final-current.log`, SHA-256
    `b7b0c5069f4e81770ae46124b04550442a7cb36ad19376afbccffd8ba7ef5c1c`.
  - `/private/tmp/loopex-m7-daemon-bindings-floor.log`, SHA-256
    `52cb41295740c9ad029aa49487fb1204ff73cc3d1aef6ba56cfef7c7091308c0`.
  The first new test run failed two witnesses: it treated the second acquisition
  probe as the release probe and required orderly custody cleanup after fatal
  fail-stop. The corrected witnesses select a distinct release worker and follow
  ADR 0031's VM-halt contract; in-process fixtures explicitly join remaining
  children in cleanup. Existing lifecycle tests and bounds are unchanged.
  Initial output: `/private/tmp/loopex-m7-daemon-bindings-current.log`, SHA-256
  `20daa95697fcfb64c995e3a3400c95bd007edaa9b3dcaf1c4629e695cf3a41b6`.

- 2026-10-01: The complete fast check on
  `53a60e346e3523c09b0e95fbfda3877146dd15ba` failed only the reference
  composition's existing size assertion: 198 effective lines exceeded 180.
  All ten other application suites passed. The composition suite passed its
  other 385 tests; this run is retained as failed evidence, not a pass.
  Complete output: `/private/tmp/loopex-m7-53a60e34-fast-check.log`, SHA-256
  `395b7c5c7f84187b3e18f2afe94f242dcb6e8018fc072d143c4df3dd222904cd`.
  The repair moves the existing required-input and launch-option validation
  into DurableOptions, which already owns model, bounds, sampling, active-tool
  and maintenance validation. All three constructors use its complete preflight;
  order, error values, first-duplicate behavior and effect boundaries are unchanged.
  Composition retains startup wiring and now has 154 effective lines. The test
  and its 180-line ceiling are unchanged. Focused constructor, precedence,
  failure-cleanup and binding-startup tests pass 33 cases on each toolchain:
  current in 10.4 seconds and floor in 9.7 seconds. These focused results prove
  the repair; they do not relabel the failed integration candidate as green.
  - `/private/tmp/loopex-m7-validation-owner-current.log`, SHA-256
    `d7657b9baed490a6333658daec63397791138a542c085c5e27a315875f45b513`.
  - `/private/tmp/loopex-m7-validation-owner-floor.log`, SHA-256
    `93054405c4f2ce2742cc8fcfbfb9fe31f88d91ccdbfbd84ab3b35598399c71c2`.

- 2026-10-01: Durable composition now admits direct explicit bindings and
  borrowed version-2 planes. Preflight checks complete plane/model-option shapes,
  tracing-capability agreement, optional capability PID identity, every token's
  membership in the exact registry, sorted launch exclusions, the ordinary route
  and the separately selected maintenance route. Conflicting bindings and planes,
  local durable routes and unbound selections refuse before owned effects.
  Maintenance metadata is resolved once from admitted provider identities without
  inventing credential references or inheriting an unconfigured summarizer.
  Borrowed planes never reread reintroduced keys; direct partial-load failure
  joins the created custodies. Tests cover start, with_runtime and start_edges,
  public-view exclusion and the existing exhaustive durable-option subsets.
  The launch audit also found Store writer probes and provider companion Port
  startup. Both now receive instance-scoped exclusions; Store validates names
  before preparing its path and keeps them out of marker/log bytes. Provider
  configuration validates the same shared host-name grammar; the first-image
  witness reinserts all 17 names after the snapshot. Actual provider launch
  forwarding and cleanup retain their existing process-group conformance.
  Current proof includes 41 durable cases in 17.8 seconds, then all five final
  binding-startup cases in 2.2 seconds after adding partial-load cleanup; Store
  passes 10 in 7.6 seconds and the final launcher file passes eight in 5.3 seconds.
  Floor proof passes Store 10 in 7.3 seconds, provider 40 in 70.7 seconds and
  durable composition 42 in 16.3 seconds, each application in its own VM.
  Complete successful outputs:
  - `/private/tmp/loopex-m7-durable-startup-fixed-current.log`, SHA-256
    `f05d5b07be369a949b63f5d469ea5dbd2abe6b766c3c5151a21bb7ed95258d9b`.
  - `/private/tmp/loopex-m7-durable-startup-final-current.log`, SHA-256
    `5ac7c91d78bbe88be7ca3ad4db2cbbd2945dbceb307c579ac33207e866dcba5d`.
  - `/private/tmp/loopex-m7-store-exclusions-current.log`, SHA-256
    `bc1dcf0990476b2b2cdda9b37e070424b494079391ebd3a4a05da581331c1b5a`.
  - `/private/tmp/loopex-m7-provider-launcher-final-current.log`, SHA-256
    `205a0172d02f8659bc9d50595749ded8632bd8f57fb45a076b3fa6456e769b52`.
  - `/private/tmp/loopex-m7-store-exclusions-floor.log`, SHA-256
    `579043888dd49e9ae3c43bf42a457cd24d5cf42181d9a72a33b33c16d6b6cb2e`.
  - `/private/tmp/loopex-m7-provider-exclusions-floor.log`, SHA-256
    `1ae4e3c86b77e2cd37472bda5aa64e89b361c580164a6dbd6aaae932f1967f5a`.
  - `/private/tmp/loopex-m7-durable-startup-floor.log`, SHA-256
    `3ad16c3d8e8fbdf3cc865da37239b63cc8a4f9b975791fbccc49f4d032dfefd6`.
  The first integration run exposed the missing Store option allowlist entry
  and a fixture cleanup lookup after its registry had stopped. Both were fixed.
  The provider witness needed a separate trace observer and its exclusions on
  the actual launch fixture, rather than the earlier vector-only fixture. These
  were code/test changes; no failing run was relabelled as a pass or retried
  unchanged. Retained failure outputs:
  - `/private/tmp/loopex-m7-durable-startup-current.log`, SHA-256
    `962e37a11648cd91ed21aaffef57f83d1637c669103e9f609aaac4c3250502e4`.
  - `/private/tmp/loopex-m7-provider-exclusions-current.log`, SHA-256
    `58a56679a32584168cb1e3c281657c75d43a2039332e878cb3f192fae951ba53`.
  - `/private/tmp/loopex-m7-provider-exclusions-fixed-current.log`, SHA-256
    `b238e73296b5fde40ced7fcd78ec9e918046cf0c977311856da4a5d1db01bba6`.
  Daemon binding ownership/conflict handling, CLI entrypoints and helper-host
  forwarding remain pending. This checkpoint does not claim those workflows.

- 2026-10-01: Project revision discovery, resource-import executors and placement
  probes now accept the same bounded sorted credential-exclusion list. Shared
  validation rejects malformed lists before discovery reads entries, import
  creates directories, or a placement probe starts its subprocess.
  Discovery and placement explicitly unset every captured name at System.cmd;
  resource import passes the list into the actual local executor constructor.
  Placement release can use the same scoped probe as acquisition and inspection.
  The legacy single-name defaults and existing receipt fields remain unchanged.
  The reference adapter additionally reserves `LC_ALL`, as ADR 0048 permits
  narrower exclusions: placement requires `LC_ALL=C`, which would conflict with
  removing that name if it were admitted as a credential slot. The shared
  binding validator rejects it before custody reads or startup.
  Tests observe discovery after all 17 names are reintroduced, actual placement
  acquisition/inspection/release, the actual import executor's startup options,
  unchanged receipts, invalid-name refusal and custody admission. Final focused
  suites pass 42 cases on current in 38.3 seconds and on the floor in 37.9 seconds.
  Complete outputs:
  - `/private/tmp/loopex-m7-composition-exclusions-final-verified-current.log`, SHA-256
    `594b395860ff77139ae7a98db2d194036d43d050032d710280787e1ecdac4f04`.
  - `/private/tmp/loopex-m7-composition-exclusions-verified-floor.log`, SHA-256
    `c63d9b7c9669ff0ace83475d8d7bd82e998c9903233ed3aa388ff167756e87cf`.
  Two test-witness defects were fixed before this proof. The first tried to read
  job context from the separate bounded unlink worker; it now observes the real
  executor constructor. The floor then exposed an order-dependent trace install
  before module loading. A fresh-VM diagnostic proved zero matched functions
  before loading and one after; the test explicitly loads the module and asserts
  both trace-install counts. Neither timeout nor required check was relaxed.
  Retained diagnosis:
  - `/private/tmp/loopex-m7-composition-exclusions-current.log`, SHA-256
    `fa5da6cee0d9d98716ba012a57a5cc4cb41dfda0c1794ac6998498e10a6fef36`.
  - `/private/tmp/loopex-m7-composition-exclusions-floor.log`, SHA-256
    `79aae65f5fe9d92ff6a9e14006cdd9a9de0f8a645093cd44967c5ede298afc62`.
  - `/private/tmp/loopex-m7-import-trace-load-diagnostic.log`, SHA-256
    `b36ac8dd48de8ed6ecb51bc153fb5a86f5ea616289374e1b13860119b9dc0a98`.
  Runtime composition and reference-host entrypoints still need to forward the
  plane's immutable list. Version-2 durable planes remain refused until that
  integration also supplies route validation and selected-model startup.

- 2026-10-01: The trusted local executor accepts a bounded, sorted unique
  `excluded_env_names` startup list containing the legacy provider key. It
  retains that list only in private executor/job context, transfers it to launch
  and drain workers, and restores the caller's context after execution. The
  single production Port boundary explicitly removes every listed name after
  the ambient snapshot; ordinary jobs and cleanup helpers use that boundary.
  Existing jobs and receipt fields are unchanged. A real first-image witness
  reinserts all 17 admitted names after the snapshot for both coding and
  demonstration environments. A separate actual-job trace proves that configured
  exclusions reach the ordinary launch and its cleanup helpers; malformed lists
  refuse before ledger creation. The focused executor and coding suites pass
  147 cases on current in 122.0 seconds and on the floor in 119.4 seconds.
  Complete outputs:
  - `/private/tmp/loopex-m7-executor-exclusions-current.log`, SHA-256
    `6987a3d3bf4ab8d2a4d815e022a371b9adb0b1429a27789323eee87f8986502d`.
  - `/private/tmp/loopex-m7-executor-exclusions-floor.log`, SHA-256
    `b7f8153ed99e9a957c3291da5228e489feb0f02f2919e73e2071da31950c735e`.
  The first sandboxed invocation could not acquire Mix's local TCP lock and
  executed no tests; the recorded runs used the authorized local test environment.
  Composition forwarding, project discovery, resource-import executors and
  placement probes remain pending. Version-2 credential planes are still
  refused by durable runtime composition until those paths join.

- 2026-10-01: CredentialPlane's explicit-binding branch and CredentialHost.open/1
  now share one loader. It validates all references before environment access,
  refuses local durable routes, loads sorted unique credential names once and
  deletes an unselected legacy variable without reading it. Shared names reuse
  custody; separately named credentials retain distinct tokens. Partial missing
  credentials, constructor refusals, constructor exceptions and capability-start
  failure join every returned child's termination before refusing. Constructor
  failures expose a fixed class. Successful processes stay linked to the opener.
  Borrowed version-2 planes retain their exact routes, registry and exclusion
  set with a fresh trace capability, and do not reread reintroduced environment
  values. Trace-counted synthetic tests and existing legacy tests pass nine
  cases on current in 0.5 seconds and on the floor in 0.4 seconds. The invalid
  input test explicitly observes attempted starts outside the starter callback,
  so the loader's exception reduction cannot swallow a failed assertion.
  Complete outputs:
  - `/private/tmp/loopex-m7-durable-bindings-verified-current.log`, SHA-256
    `fc5c1a8e3743fc77130b0a70fed3f45244062ca5199a52e1be777e3777c16b54`.
  - `/private/tmp/loopex-m7-durable-bindings-floor.log`, SHA-256
    `77c022c6a39dae254ae90ddc7e75af2f8b7aa4a7b5ea9cce876a5b9bb556c466`.
  Composition still refuses these new planes. Runtime acceptance, launch-name
  exclusions, daemon ownership and selected-model startup must join together
  before the host entrypoints expose multi-provider durable execution.

- 2026-10-01: The durable adapter accepts the explicit provider-routes branch
  alongside the separate legacy single-token branch. It rejects mixed branches,
  partial registry/capability options, malformed tokens and unsupported provider
  keys. Before starting an invocation, the bridge selects only the committed
  request's provider token and removes the routing table from its invocation
  configuration. A missing route refuses before any child starts. The existing
  excluded credential sender, registry/custody lookup, private bootstrap frame
  and process-retirement proof are unchanged. A real companion fixture receives
  alternating selected credentials with independently distinct lengths and
  proves each child gone; an unbound provider produces no child or credential
  frame. The 30-case configuration/bridge selection passes on current in
  38.5 seconds and on the floor in 66.7 seconds. Complete outputs:
  - `/private/tmp/loopex-m7-durable-route-current.log`, SHA-256
    `617f6045dafbf340a6fb2b6e7e7dbb2d67aa2a1a8b368f5095f6c588a1f80457`.
  - `/private/tmp/loopex-m7-durable-route-floor.log`, SHA-256
    `524f0f8ff9e57d4d01681bdb4db2f4f91b8a0ec6773893362475fc3488fe4163`.
  The shared durable binding loader, version-2 host planes, launch exclusions,
  daemon assembly and host model/configuration wiring remain pending. This
  adapter change does not yet make those host entrypoints accept multiple keys.

- 2026-10-01: The full fast check passes on exact integration commit
  `7c266c4678776908b159bea13927117e1bf40bd7`: all 11 application suites,
  2,905 tests passed and 34 excluded, in 872 seconds. Compilation, formatting,
  structure, documentation ordering, runner/archive fixtures, dependency
  direction and version checks also pass. Complete output:
  `/private/tmp/loopex-m7-7c266c46-fast-check.log`, SHA-256
  `ab4f135d79d664f6bb949b872847e11e3609a53881bdec4ff53c1c66e10b289a`.
  The checkout stayed unchanged throughout the run. Later durable routing work
  is outside this proof and requires its own focused validation.

- 2026-10-01: Ephemeral startup accepts explicit provider bindings and a separate
  maintenance model. It validates every reference, requires the ordinary and
  summarizer routes, and forwards the resolved maintenance map privately.
  Omission retains legacy single-route behavior; a supplied map adds no routes.
  The adapter now owns the one shared reference validator used by composition
  and dispatch. Each committed request selects its own provider reference before
  admission, while only the sensitive caller reads the value. Mixed legacy and
  explicit callback options refuse. Route tables do not enter caller input;
  it receives only the selected reference. Tests cover native TLS calls using
  alternating synthetic keys, a missing selected key despite a populated
  default, credential-free calls, unknown/missing routes, reserved names,
  resolved maintenance startup, public-view exclusion and repeated embedded
  turns through the complete callback and cleanup path.
  The initial focused invocation incorrectly combined applications in one VM.
  Adapter tests passed 22 in 9.9 seconds, but ReqLLM startup state from that
  suite caused 13 composition `req_llm_dotenv_enabled` refusals. The repository's
  required one-application-per-VM execution removes that test-runner
  contamination without changing or relaxing a guard. In a separate current VM,
  all 61 composition cases pass in 23.2 seconds. Separate floor VMs pass the
  same 22 adapter cases in 9.5 seconds and 61 composition cases in 23.7 seconds.
  Retained outputs:
  - Initial mixed run, including the adapter pass and composition failure:
    `/private/tmp/loopex-m7-ephemeral-bindings-current.log`, SHA-256
    `bd99b9315da0dad6c1f825073d614d2dc7b381edc034ffb13fcb91039923f79e`.
  - Current composition:
    `/private/tmp/loopex-m7-ephemeral-bindings-composition-current.log`, SHA-256
    `28b6ee5e2be832912e47441c1b611027b5f4c59bd6604724906ff55838cf6f2e`.
  - Floor adapter: `/private/tmp/loopex-m7-ephemeral-bindings-adapter-floor.log`,
    SHA-256 `d3039116192773abf7b213a18683176a2a50f51c9aa39501cd3c5c72ebb2c439`.
  - Floor composition:
    `/private/tmp/loopex-m7-ephemeral-bindings-composition-floor.log`, SHA-256
    `ab47e9c1402ca3a95c6632cc584287331647f103fe21582839b96245245165fc`.
  Additional managed-callback cases prove mixed legacy/explicit options and a
  missing selected route refuse before admission or child startup. The 17-case
  callback file passes both pairs in 4.4 seconds each:
  - `/private/tmp/loopex-m7-ephemeral-bindings-callback-current.log`, SHA-256
    `212fbd31f233e78e45918fd87219a71be4c0cb4db57539ed2b149847a58a9a88`.
  - `/private/tmp/loopex-m7-ephemeral-bindings-callback-floor.log`, SHA-256
    `f7e073859841d404b6c879a5d17458642e4f7ab445f7be3a4c0037f86dc9d412`.
  Compilation, formatting, documentation ordering across 1,022 covered entries,
  dependency direction and status checks pass.
  Durable custody, daemon routing, host configure/resume and maintenance episode
  dispatch remain pending. These local synthetic calls are not counted paid
  provider attempts or live closure witnesses.

- 2026-10-01: All three durable constructors and ephemeral startup now accept
  explicit `maintenance_instructions`, validate them before owned effects and
  forward the exact version/body input to Core's runtime-local capture. Missing
  or nil remains unconfigured. Ephemeral per-call overrides remain refused.
  Tests exercise all durable constructors, the real ephemeral runtime and
  coordinator, exact Unicode/newline content, the inclusive body ceiling,
  malformed-input refusal before owner allocation and public-view exclusion.
  The four focused files pass 54 cases on the current toolchain in 19.3 seconds
  and 54 on the floor in 19.0 seconds. Their existing deliberate cleanup faults
  retain their diagnostic output. Complete outputs:
  - Current: `/private/tmp/loopex-m7-maintenance-host-forward-current.log`, SHA-256
    `1c8b253eca9b740a33890e7096fc7ac06c227882b32cb32866cedbdc9415b193`.
  - Floor: `/private/tmp/loopex-m7-maintenance-host-forward-floor.log`, SHA-256
    `c09270964b68f0ff125f3f4a5401c26b4b5e2904535c4f07718cfcfc2eaa2469`.
  Provider-binding/custody integration is still required before composition can
  forward the separately selected maintenance model. The shared reference
  instruction block and episode/compaction implementation also remain pending.

- 2026-10-01: Core startup now validates the closed maintenance model and captures
  the exact versioned instruction bytes and digest. Runtime-local settings reach
  each coordinator without entering ordinary session truth or public runtime
  configuration. Startup capacity validation remains distinct from episode
  reasoning eligibility. Composition resolves only an explicitly selected,
  routed, registered thinking-off summarizer, and CLI preparation retains nil
  when none is selected. Streaming HTTP and buffered TLS tests exercise the
  fixed 1,024-token allowance, disabled thinking, absent tools and natural
  summary completion. Current and floor focused checks passed 19 provider,
  12 composition and 14 CLI cases. The broader Core check initially failed one
  of 51 cases because the extracted validator added an unnecessary 512-byte
  model limit. Removing that restriction preserved the existing independent
  2-KiB metadata boundary test; all 51 Core cases then passed on both pairs in
  0.3 seconds each. Initial failed outputs remain retained separately:
  - Current: `/private/tmp/loopex-m7-maintenance-startup-current.log`, SHA-256
    `271ef1debdf4891dfe083a8e9f0e761c30b03293c5fc76eb215d9dd1486148bc`.
  - Floor, including the passing provider/composition/CLI groups:
    `/private/tmp/loopex-m7-maintenance-startup-floor.log`, SHA-256
    `d285019974c9baea3d4f139f3f4f73f25f000fd7a72ecd0fc0f4cee58bc6c035`.
  - Repaired current Core:
    `/private/tmp/loopex-m7-maintenance-startup-repaired-core-current.log`, SHA-256
    `9ee5a827b08ee5eaa10c800b6e1dabea1173d5cbe828a225e6f6b6ffcec08695`.
  - Repaired floor Core:
    `/private/tmp/loopex-m7-maintenance-startup-repaired-core-floor.log`, SHA-256
    `6825255e5e0287467459bded3c6a3947c8f0dcb4a976af4e96dd06c4aec9c320`.
  Durable and ephemeral host startup forwarding, the shared reference instruction
  block, episode capture, dispatch, recovery and checkpoint accounting remain
  pending. This checkpoint does not implement compaction. Warning-free
  compilation, formatting, documentation ordering across 1,020 covered entries,
  dependency direction and status checks pass. The dependency check first
  refused the untracked new module; staging the source satisfied its tracked
  ordinary-file requirement without changing the check.

- 2026-10-01: ProviderBindings now resolves a closed initial declaration through
  complete route validation, pinned capability capture, literal alias resolution,
  exact reasoning/reply mapping and Core's whole-configuration validator.
  ConfigSelection joins the file/flag selection to that boundary with the host's
  already captured instruction block and complete selected definitions. Derived
  ceilings acquire default origins; explicit origins remain unchanged. No
  credential reference, path or host routing value enters the core configuration,
  and neither stage acquires credentials or starts services. Tests cover every
  registered cell, missing routes, malformed bindings, authored metadata,
  manual/output/context limits, unknown windows, instruction/tool system cost,
  literal alias resolution and a prompt file changed after capture. The initial
  CLI fixture run passed 29/31: one fixture omitted its file model's route, and
  another expected an unbound override to survive the existing earlier schema
  guard. Corrected fixtures preserve that guard; production code was unchanged.
  Current focused checks pass 11 composition cases in 5.9 seconds and 31 CLI
  cases in 1.0 second. The floor passes the same 11 in 5.7 seconds and 31 in
  0.9 seconds. Retained floor output:
  `/private/tmp/loopex-m7-host-configuration-preparation-floor.log`, SHA-256
  `4052203445e6a612fcd575e8a68b44e1efb26ddcf0c7f0c3e769180c66816785`.
  This is initial session preparation. Complete maintenance/role preparation,
  effective-value rendering, command entry, startup and configure/resume wiring
  remain pending.

- 2026-10-01: the full fast check passed on
  `14275a2949567b885f3a91b4a47d3d042dd3e376`: all 11 application suites,
  2,880 passed and 34 excluded, in 870 seconds. This proves the integrated
  native bridge and the earlier fixture/config-routing repairs. Complete output:
  `/private/tmp/loopex-m7-14275a29-fast-check.log`, SHA-256
  `752e5ef2c8c5873d7740726e80f0b619ec72ef28443138644f6d6897a4cfd347`.
- 2026-10-01: all nine literal cells now have streaming HTTP evidence for exact
  controls, reply ceilings, literal response identity, public summary eligibility,
  private block retention and open/closed capsules. Each cell's post-terminal
  request groups retained tool results and the next prompt in one user array,
  omits empty assistant completions and uses canonical tool IDs. All seven
  continuation-required cells preserve their own expanded native arrays and
  original IDs in both render modes. Per-cell streaming cases refuse foreign
  identity, raw-content and block-count overflow, and complete-wrapper overflow
  after otherwise successful bounded assembly. These added tests passed before
  ordinary registration: 27 tests in 2.6 seconds. ModelCapabilities now exposes
  precisely the accepted Haiku and Fable reasoning subsets and their literal
  mappings. NativeRequest uses that same mapping function without a catalog
  refresh. Manual budgets refuse at equality without increasing max_tokens;
  Fable none and unknown non-default modes refuse. All nine resolved records
  pass whole-configuration admission within the existing metadata envelope.
  Seven focused files, including both transports and cleanup, pass 76 tests in
  21.1 seconds on the current pair and 76 in 20.9 seconds on the floor pair.
  This completes adapter registration; host startup/configure/resume integration,
  the separate summarizer and counted live witnesses remain pending. Outputs:
  - `/private/tmp/loopex-m7-nine-cell-conformance-current.log`, SHA-256
    `4294a57180b6f94add28c1c244a08ddfe8debca9d2fdb44609f215a7b6741c70`.
  - `/private/tmp/loopex-m7-registered-cells-current.log`, SHA-256
    `83ef6f5dd3ff6f8fe578595e2164b33864327ba9b177551b2db123806d6858bc`.
  - `/private/tmp/loopex-m7-registered-cells-floor.log`, SHA-256
    `ce1554089a10df7ff77dda1c6c85783b642ca140ef82da34fc63662a7cbf0067`.

- 2026-10-01: the buffered Anthropic path now validates its captured cell before
  credential lookup, installs exact native messages/controls at OneShotHTTP1's
  final encoded-request boundary and captures the raw response before SDK
  conversion. The existing invocation tag correlates caller-local request and
  response entries; the cleanup owner still receives only its closed route
  proof. Capture requires a complete native envelope, literal registered model,
  bounded native content and the same stop/call relationship as streaming.
  Supported usage counters remain unknown when missing or malformed. The caller
  returns completion/capsule fields with zero progress deltas and screens every
  newly retained private value for the selected credential. SDK payload capture
  is disabled per call, and raw SDK fixture capture refuses before dispatch.
  Local verified TLS exercises all nine literal cells, open and closed capsules,
  Unicode/text/tool ordering, exact controls/limits, malformed/native-limit/model
  refusals and selected-key echoes in thinking, signatures and redacted blocks.
  Final review also retained raw usage until selected-key screening, so reducing
  a malformed counter to unknown cannot erase a credential echo. The pure and
  actual-TLS regressions for this final correction pass 14 tests in 6.1 seconds
  on the current pair and 14 in 5.8 seconds on the floor pair.
  Ordinary reasoning registration and the live thinking witnesses remain open.
  Finch's own events retain the outgoing request object, independently of SDK
  payload settings. Both native paths now supply a one-use body stream whose
  callback retains only the invocation handle. The streaming capture owns its
  bytes until the first read and clears them on failure; the buffered caller
  consumes its body entry once and removes it on every transport exit. Exact
  content-length preserves the existing wire bytes and framing. Tests inspect
  actual Finch events and serialized callback terms, prove exact transmission
  and refuse a second read. Existing host-owned header observability is unchanged;
  this supplies no secrecy from trusted code executing in the transport process.
  Buffered memory remains bounded by the existing 8,388,608-byte raw collector,
  its transient joined binary and decoded response, the already admitted outgoing
  request, and the 16,384-byte compact/expanded native-content limits. The private
  capture adds only the admitted canonical text/calls/capsule and supported usage;
  it retains no response event log. Caller cleanup removes its capture entries.
  A low-level TLS fixture originally sent an empty Anthropic body without an
  invocation context; its pre-claim refusal exposed a fixture owner waiting only
  for a claim. The fixture now supplies valid native request/response bytes and
  acknowledges teardown before or after claim. The failed 73/74 run is retained
  as failed; its orphaned child was identified and terminated. The repaired exact
  case passes in 2.0 seconds. Floor conformance passes all 74 cases in 18.3 seconds;
  current worker/backpressure/accounting regressions pass 25 in 95.1 seconds and
  host credential-exclusion workflows pass two in 10.8 seconds. All 21 current
  one-shot cases pass in 9.4 seconds after the shared fixture repair. Retained
  outputs:
  - `/private/tmp/loopex-m7-buffered-native-key-screen-current.log`, SHA-256
    `dbc4266a0f718c93052c25286410bc57a70d5263be04d08ea63fc27f9b0b13dc`.
  - `/private/tmp/loopex-m7-buffered-native-key-screen-floor.log`, SHA-256
    `29f8d2032ffe579a30b16f4e4c008b34950907f0d1431a6f0ff76ab4e4889c81`.
  - `/private/tmp/loopex-m7-buffered-native-conformance.log`, SHA-256
    `c996c82672c7d86119eea71131a33437c1e5711da97252f7d58a193d8a1321d9`.
  - `/private/tmp/loopex-m7-buffered-native-floor.log`, SHA-256
    `768d72ec8df13705931747cfc28a30f23c0cd1ce7c2295e09d25bd7ea195a9b6`.
  - `/private/tmp/loopex-m7-buffered-native-one-shot-repaired.log`, SHA-256
    `667ad7ad2b339197d15380752c6b4c3fe06b82a512200341f46e22e9b332a2fc`.
  - `/private/tmp/loopex-m7-private-body-worker-regressions.log`, SHA-256
    `c25bf126d4dbfc2f0e8631267f35f99eb75af7ff7cb6f223be578f9ee5696743`.
  - `/private/tmp/loopex-m7-buffered-native-host-exclusion.log`, SHA-256
    `bb0f287c520bb094a339f2b9a12636a4a62fe63fafe6a5201d47dc0fb7edf147`.

- 2026-10-01: the full fast check of
  `ca63492e008c001046aba0dde159d2818253850e` failed 27 tests across core,
  daemon and CLI; the other eight application suites passed, including all
  369 adapter tests. Retained output:
  `/private/tmp/loopex-m7-ca63492e-fast-check.log`, SHA-256
  `00dd58b8d6af79a24a096ff59c29da83e124b7b63c2172a766b0282706214ece`.
  The historical interaction positive control still contained a v3 settlement;
  nine synthetic native stream builders omitted the initial null stop fields;
  and both new configuration parsers directly named an adapter implementation.
  The raw-byte accounting witness also reached Anthropic's new smaller native
  ceiling before Core admission. Corrections encode the historical control's
  v2 settlement explicitly, complete the native fixtures, route model syntax
  through composition, and exercise the same 65,537-byte Core refusal over the
  existing OpenAI Responses HTTP path. Settlement-depth compaction remains an
  Anthropic HTTP witness. No bound, accounting assertion, cleanup assertion or
  architectural scan was weakened. This failed candidate is retained as failed.
  Focused current-toolchain validation passes the historical reader case in
  4.0 seconds, 29 accounting/configuration/boundary cases in 6.3 seconds,
  30 live CLI cases in 395.2 seconds and three daemon cases in 16.0 seconds.
  The source-built foundation and multi-client cases also passed in the first
  nine-case repair run, whose sole remaining raw-byte failure was fixed and
  re-proved in the accounting run. That exploratory run remains recorded as
  eight passed and one failed, not as a green run. Retained outputs:
  - `/private/tmp/loopex-m7-config-accounting-repaired.log`, SHA-256
    `3761ecf1a854749d167d956fe8f35c2707fc9b9dc794403b573e78db797d01dd`.
  - `/private/tmp/loopex-m7-native-fixtures-live-cli.log`, SHA-256
    `215b9bf248d54112e58a7f2b3485b00219d8e96f498d6577d10dec45c4004846`.
  - `/private/tmp/loopex-m7-native-fixtures-daemon.log`, SHA-256
    `354bc84cb671481972b734cd124c4de7e499dc706745c488dc012e6ea753540f`.
  - `/private/tmp/loopex-m7-fixture-regression-cli.log`, SHA-256
    `a007c6636f6203c87a517d8a7615e80d2c51b53d778234401d8e4bf791ca73a5`.
  The floor pair passes the boundary case separately in 1.6 seconds and all
  28 accounting/configuration cases in 7.3 seconds. Its ExUnit line selector
  excludes the other files when mixed, so those files ran separately.
  Warning-free compilation, formatting, 1,008-entry documentation ordering,
  dependency direction and milestone status checks pass. Floor outputs:
  - `/private/tmp/loopex-m7-config-accounting-floor.log`, SHA-256
    `c83531d10ef48b2035ab9ecad4668328bab13d9a986da3fe057fd4235a20ab5b`.
  - `/private/tmp/loopex-m7-config-accounting-floor-files.log`, SHA-256
    `a8b9b3f810cfde4487b96f614e24ec390e407a9b60004126c5c77fe1dc466b12`.

- 2026-10-01: the durable Anthropic worker now normalizes model/options/context
  before the pinned `Streaming.start_stream/4` handoff and uses invocation-owned
  provider/parser callbacks. The exact callback inventory is `stream_transport/2`,
  `stream_protocol_parser/2`, `parse_stream_protocol/2`, `init_stream_state/1`,
  `decode_stream_event/3`, `flush_stream_state/2` and `attach_stream/4`.
  Native content stays in private capture; only admitted public deltas and the
  actual message-stop marker enter dependency conversion. The private failure
  latch independently wakes the owner, which cancels the exact stream and joins
  its drain. The drain is linked as well as monitored so owner death also stops
  a blocked progress callback. The selected credential enters only the private
  request builder; raw payload telemetry is disabled per invocation, and its
  model contains no capture handle. Capture status formatting excludes private
  state, messages and reasons. Existing protected-companion custody remains the
  production boundary; this adds no host-VM secrecy claim.
  Native stop evidence now produces v3 completion/capsule fields through the
  private codec. Generic rows reject thinking/redacted blocks and preserve
  natural/limit/unknown classification. Converted thinking labels on other
  paths no longer authorize reasoning disclosure. The shared canonical-call
  mapper uses full generations and refuses malformed arguments. Terminal result
  groups and following prompts share one native user array across empty assistant
  completions. Buffered capture, ordinary cell registration and live-provider
  proof remain open.
  The local HTTP cases exercise byte-framed Unicode/tool JSON, redacted blocks,
  exact outgoing limits, response identity, summary eligibility and invalid
  terminal controls, malformed interior input, incomplete original EOF, raw
  comment overflow, blocked-drain cancellation, owner death and telemetry
  exclusion. Companion fixture routes are now selected before the final hook.
  Backpressure fixtures use a 12,288-byte head within the native content ceiling;
  their actual socket-pending, writer-stack, queue/count and cleanup assertions
  remain required. Incomplete native input now fails at parser/flush rather than
  converted completion metadata; typed transport and callback diagnostics retain
  their closed categories.
  Memory accounting for pinned ReqLLM 1.24.0: one cumulative 8,388,608-byte body
  budget covers pending parser input, tool JSON and each transient decoded batch.
  Completed native content is capped at 16,384 JSON bytes/128 blocks. Capture
  keeps no event log, and the drain retains only one delta plus its count. Each
  public fragment passes the Model payload bound; total queued payload and event
  count are bounded by the same raw-body budget, including a batch that exceeds
  the dependency's 500-chunk watermark. The synchronous single Finch producer
  cannot add an unbounded pending-call queue. `ChunkAccumulator` ignores the
  private delta envelope; StreamServer metadata replaces its last delta rather
  than accumulating them, object mode is off, and fixture raw capture is refused.
  Dependency telemetry retains bounded summaries/options and the already bounded
  request; its model has no invocation handle and its options have no selected
  credential. Request/capture/codec values retain their existing independent
  bounds. These bounds include linear term overhead; no byte-exact BEAM heap
  size or new response-header bound is claimed.
  A broad exploratory adapter run from the dirty checkout was stopped after
  identifying fixture-route migrations and clean-source prerequisites. It is
  failed/incomplete evidence, not a fast-check or candidate pass.
  Final focused checks pass 126 tests in 103.4 seconds on the current toolchain,
  including actual companion/backpressure/failure-category cases, and 101
  native/mapping/codec/conformance tests in 12.3 seconds on the floor pair.
  Retained outputs:
  - `/private/tmp/loopex-m7-native-bridge-checkpoint-current.log`, SHA-256
    `92e5b85ff1907ff038bd9f8537e8497453c4497d04d40e670cf5e9ba1620a770`.
  - `/private/tmp/loopex-m7-native-bridge-integrated-floor.log`, SHA-256
    `ae90d3003bd5709c661f25ab6821e08a57b94025a30ea26de461dcbfd20e58c0`.

- 2026-10-01: native request preparation now validates the nine literal captured
  cells, strict manual-budget/output-limit relation and unchanged tool definitions
  before rendering controls and expanded native arrays. Known call names resolve
  through their complete generation; retained arrays are checked against canonical
  text and calls, and tool results use retained native IDs. Unregistered default
  requests retain dependency rendering and have no summary disclosure eligibility.
  The pinned Anthropic builder preserves these controls and ceilings for all nine
  cells and a continued tool exchange. A final invocation hook compares the whole
  Finch request after the global hook, refusing body, route, header or transport
  mutations with a fixed error without logging request material. Only the admitted
  tool beta is allowed, and only when tools are present.
  Focused request/stream/capture checks pass 25 tests in 1.7 seconds on each
  supported toolchain. Retained outputs:
  - `/private/tmp/loopex-m7-native-request-current.log`, SHA-256
    `4f68fef72fb21c18f4312f30ff387343c371e2823133924c883388e4ce87c089`.
  - `/private/tmp/loopex-m7-native-request-floor.log`, SHA-256
    `86f58a470ca55dce97e34802f416a7fc96e84d87bd2a740df0e2c85b3aba4ad8`.
  This prepares the boundary but does not yet join the live transport, buffered
  capture, fatal wakeup or public summary path, or register thinking support.

- 2026-10-01: added the private native stream reducer used to prepare the
  invocation bridge. It admits exact message/block ordering, literal response
  identity, type-correct deltas, concatenated signatures and parsed object
  arguments, preserving empty and redacted blocks. Final cumulative usage
  replaces prior counters; missing/invalid evidence remains unknown. It retains
  assembled blocks and one open block instead of an event log. Failure clears
  captured content and cannot be reversed by later input or flush. Raw HTTP
  bytes, including comments/pings/framing, spend one 8,388,608-byte budget before
  parsing. The native array has an inclusive 16,384-byte JSON cap and 128-block
  limit. Tests pin ServerSentEvents.Parser 1.1.0 and ReqLLM 1.24.0's SSE.flush/1;
  unknown parser states and incomplete original framing refuse instead of
  acquiring completeness from synthetic newlines. Byte-split input reconstructs
  the same native content as buffered capture.
  Native assembly/capture checks pass 15 tests in 0.2 seconds on each supported
  toolchain. Compilation is warning-free; format, documentation ordering and
  dependency direction pass. Retained outputs:
  - `/private/tmp/loopex-m7-native-stream-assembly-current.log`, SHA-256
    `a16c4b78512843bef85dc7ad4b6afcff8f82d27365b7b7a90c799adfa5f5246c`.
  - `/private/tmp/loopex-m7-native-stream-assembly-floor.log`, SHA-256
    `f4a8dd73e158a6e5c7073f3fcc6071abe75c7fe203fe10b21322bf94e50405b1`.
  The invocation-owned wrapper, fatal notification and blocked-drain wakeup,
  final request-hook validation, buffered transport join, dependency queue
  memory proof, public-summary classification and per-cell transport conformance
  remain open. This reducer alone does not change live transport or register
  thinking support.

- 2026-10-01: ordinary open exchanges now stage the closed ADR 0044 envelope
  from committed full settlement records and canonical lineage source positions.
  The shared expander checks both complete-envelope JSON limits, entry/block
  limits, ordered call/result mappings and native/canonical ID collisions.
  Revision-four receipts charge Canonical.encode(E(request)) independently of
  ordinary descriptor totals; replay derives source identities and all cost
  fields instead of accepting self-consistent replacements. V1 requests remain
  nil-only. A three-turn scripted exchange proves stable prefixes, exact source
  digests and capsules, extended mappings, cost arithmetic and next-prompt nil
  continuation. Collision refusal occurs before another tool intent. An owner
  killed after executor receipt commit resumes on a new runtime without its
  original project manifest, preserving the frozen content and avoiding a
  repeated effect. Unexpandable aggregate content produces a replay-verifiable
  unavailable preparation failure before another provider attempt.
  The current affected core run passes 249 tests in 48.6 seconds; the supported
  floor passes 34 continuation/configured-owner tests in 3.1 seconds. Adapter
  mapping/native-content checks pass 20 tests in 3.0 seconds. Warning-free
  compilation, formatting, dependency direction, documentation ordering and
  repository status pass. Retained outputs:
  - `/private/tmp/loopex-m7-continuation-owner-core.log`, SHA-256
    `6c35be6163ae7cd21e3f6a48f033d49d49ca6be0e9414720ac0a48cdc1f1a680`.
  - `/private/tmp/loopex-m7-continuation-owner-floor.log`, SHA-256
    `1e87297ced677377735df67c4b9f5f0fa3ffbd78487de570a0b8030b6c04163a`.
  - `/private/tmp/loopex-m7-continuation-owner-adapter.log`, SHA-256
    `b8909e8a86828918051719331a8df758d56371606a5da5cd9050be5a75ea240f`.
  These are model-port proofs. Native transport, registered thinking cells,
  resource-pack restart vectors, maintenance accounting/headroom and full
  real-provider evidence remain open. The measured size-refusal path for a
  frozen request with optional-provenance blocks awaits the schema decision
  above; no substitute failure or fabricated count has been introduced.

- 2026-10-01: every new ordinary settlement now writes model_attempt_settled_v3,
  including retries, transport errors, unreadable callbacks and validated reply
  compaction. The owner uses the run's frozen continuation requirement for strict
  nine/eleven-member callback admission; canonical successful replies retain ten
  members. Eight-member callbacks and invalid capsules retain accounting_evidence
  none and charge the conservative allowance before policy or executor dispatch.
  Model's reply type declares exact v2/v3 variants with a mandatory nil-or-binary
  response ID. Live fixtures and current-generation shape/size probes are migrated;
  explicit historical v1/v2 fixtures keep eight-member canonical replies. Genuine
  M2 archive readers/writers and their expected v2 tag remain unchanged.
  Required closed capsules retain exact content through before/after-commit holds,
  lost commit reply, atomic publication and runtime restart without another model
  call. These are scripted model-port proofs, not native provider conformance.
  Current core regressions pass 267 tests in 54.6 seconds. Adapter streaming/bridge
  checks pass 56 in 43.0 seconds; composition passes 16 in 19.2 seconds; CLI coding,
  accounting and genuine M2 compatibility pass 13 in 63.1 seconds with two existing
  real-provider exclusions; the reference-client check passes one in 0.5 seconds
  with one real-provider exclusion. Final targeted current checks pass 42 in 4.0
  seconds, excluding 65 unselected protocol cases already covered by the broad
  run. The floor pair passes all 108 writer/protocol/configured checks in 25.7
  seconds. A syntax-tree inventory checks 24 raw reply literals across app/script
  source and finds no omitted response-ID fields. The malformed binary-key reply
  retains its identity failure independently of shape rejection; the dispatched
  rollback script now supplies the mandatory nil field.
  Complete outputs are retained outside the repository:
  - `/private/tmp/loopex-m7-v3-writer-core-final.log`, SHA-256
    `5ae6bc4159e85804596905b7820bfcf30d02de8b82ab7c1064bf44909fd207d6`.
  - `/private/tmp/loopex-m7-v3-writer-adapter.log`, SHA-256
    `1486e5f7f9767ffc37238574112ca535681506c417a27bcc459180881733ec14`.
  - `/private/tmp/loopex-m7-v3-writer-composition.log`, SHA-256
    `63602350ed96634d3c2b1cb475690a80b96eeb16fc2a92e27cfe9e2460a836e0`.
  - `/private/tmp/loopex-m7-v3-writer-cli.log`, SHA-256
    `05cc109743142831317055eb916adfd335fd7996e6752e45f95915859abec4a1`.
  - `/private/tmp/loopex-m7-v3-writer-reference.log`, SHA-256
    `e2077a32a5a9a20ed0d638e2ec0891561ca33aa119688efa9b9f60386d91c5e3`.
  - `/private/tmp/loopex-m7-v3-writer-floor.log`, SHA-256
    `258ccdd0347ea8bf86123b26e20dd5c326c01f92faf372503f7a92bc01d49a0d`.
  - `/private/tmp/loopex-m7-v3-writer-final-focused.log`, SHA-256
    `649a25f3cd2668431c71d2c0c9bbefff2a1b3628582dfa9259ef8b77f9691991`.
  Source-bound request envelopes, native transport, continuation accounting and
  mapping registration remain pending. Current compilation and formatting pass;
  compiled documentation covers 986 entries. This does not replace the full fast
  integration check, real-provider or complete migration/rollback lanes, or resolve
  the separate Task.Supervisor cleanup investigation.
- 2026-10-01: ProviderAttempt's M7 projection admits exact nine-field v2 or
  eleven-field v3 callbacks and returns the ten-field canonical v3 shape.
  Missing provider_response_id, mixed/extra fields, missing required capsules,
  non-natural continuation completion and malformed/oversized capsules refuse
  before the caller receives accounting evidence. V2 normalizes to explicit
  nil continuation/unknown completion only when the captured mapping permits it.
  Capsule model, ordered native IDs, complete text and argument consumption bind
  the owning staged request. The historical two-argument projection and v1/v2
  settlement schemas retain their existing meanings. The v3 settlement decoder
  accepts the exact new reply/error shapes; recovery checks its captured run
  mapping and request, retains paired terminals and rejects all v1/v2 rows after
  the first v3 settlement, including a retry or error-only cutover.
  Focused projection/replay checks pass 17 tests in 0.6 seconds on current and
  floor toolchains. Provider authority/accounting/ceiling/configuration/codec
  regressions pass 120 tests in 25.8 seconds; the retained complete output is
  `/private/tmp/loopex-m7-v3-reply-readers.log`, SHA-256
  `6b1cc4ec4bcf32122d7d32bdee11b514070a97e0f123e6aabeb868e335973a91`.
  Deliberately unproved provider-cleanup faults remain visible in that output;
  passing assertions do not resolve the separate Task.Supervisor T16 follow-up.
  This prepares readers before emission. The live writer still uses v2 and the
  historical callback projection; migrate it and every live fixture together
  before claiming complete v3 settlement or callback integration. Source-bound
  request envelopes, native transport, continuation accounting and ordinary
  reasoning registration remain pending.
- 2026-10-01: shared ContentReferences expansion implements the closed literal,
  text_ref and tool_use_ref union against canonical text and ordered arguments.
  Success requires complete UTF-8 text consumption, each call index exactly once,
  one absent ASCII top-level field and the declared open/closed call relation.
  Nested reference-shaped objects remain opaque. Incremental compact JSON counting
  enforces 16,384 bytes, depth/cardinality bounds and 128 blocks without allocating
  encoded JSON; expanded counting includes the complete capsule and separators.
  The adapter's pure NativeContent capture accepts exact native field sets,
  completed thinking signatures, redacted-thinking data and reference-only
  replies; it re-expands and compares the complete native array before return.
  Duplicate IDs, unknown fields, incomplete blocks and stop/call contradictions
  refuse the entire reply. Core configuration/genesis/expansion checks pass 40
  tests in 0.2 seconds; adapter mapping/catalog/native checks pass 19 in 2.3 seconds.
  Final current and floor Elixir/OTP checks each pass eleven expansion tests in
  0.2 seconds; native capture's numeric-encoder addition passes seven tests in
  0.08 seconds on current and 0.1 seconds on floor. Numeric cases match the
  adapter JSON encoder for floats and integers outside JavaScript's exact range.
  Exact-limit multi-block tests include wrapper/separator costs; 455 bounded
  nested/escape/Unicode variations match the existing compact JSON encoder.
  Current compilation and formatting pass; documentation covers 984 entries.
  This is codec evidence, not transport or ordinary reasoning registration.
  Source-bound aggregate envelopes, versioned reply/settlement integration,
  continuation accounting, bounded native streaming and mapping conformance
  remain pending; provider dispatch still uses the existing path.
- 2026-10-01: the private host-prepared configure path uses ordinary attachment
  routing and serial-owner fences. Duplicate lookup precedes candidate validation
  and exact prospective request measurement; configure dispatches no model or
  executor work. A transient minimum request uses retained lineage, immutable
  tools, candidate instructions/bounds and required resource metadata through the
  ordinary request/receipt/Store sizing path. Only history that can be removed
  reports compaction_required; an oversized empty-history minimum refuses the
  configuration. Neither probe becomes a durable run or an operator prompt.
  Runtime restart preserves the latest configuration and earlier run captures.
  Lost commit replies re-present exact proposal bytes before acknowledgement;
  owner crashes before/after linearization retain one version and the original
  disposition. A proved stale-owner non-commit requires a fresh logical ID under
  ADR 0006. Live configuration/admission checks pass 31 tests in 2.5 seconds;
  configuration, interaction, quiescence and journal-ownership regressions pass
  114 in 19.1 seconds with four prescribed long-bound exclusions. A mistaken
  input-test filename matched no file; the actual input algebra then passes all
  11 tests in 5.8 seconds. The earlier 88-test configuration/input/interaction
  run passes assertions in 18.5 seconds but emits Task.Supervisor
  shutdown_error/noproc diagnostics for Task.Supervised children. That separate
  manager/child cleanup investigation remains open under T16; the OwnerGroup
  fix does not establish its resolution. The supported floor pair passes the
  same 31 live configuration/admission tests in 2.4 seconds. Its cold dependency
  compilation emits existing TOML charlist deprecations; this is a focused test
  result, not a warning-free floor closure check. Current-pair project compilation
  and formatting pass; documentation ordering covers 979 entries.
  Host catalog/route preparation, the
  prepared daemon route, future checkpoint projection and maintenance quiescence
  remain pending, as do public /3-/4 contracts and real-provider conformance.
- 2026-10-01: a new orderly-shutdown regression using production bytes from
  `887b2141800416b2ddb5959030a07d9c05123d1b` fails after completed model work:
  9 of its 32 shutdowns report OwnerGroup shutdown_error/noproc. An empty-work
  probe had passed, so it was replaced with the actual completed-work trigger.
  The runtime-local OwnerGroups manager now uses Erlang's simple_one_for_one
  supervisor, whose parallel dynamic-child termination recovers the linked EXIT
  reason when a late monitor reports noproc. Control keeps pid-based temporary
  groups and the same predecessor-worker barrier; no error filter is added.
  The regression passes after the fix, and deterministic held-worker tests prove
  parallel group shutdown and continued reporting of real worker-supervisor
  faults. Configured runtime/quiesce/provider lifetime checks pass 48 tests in
  7.3 seconds; final owner-group/provider-attempt/agent-loop checks pass 173 in
  46.6 seconds. Ephemeral cleanup/lifecycle checks pass 25 in 15.1 seconds.
  Floor Elixir 1.18.5/OTP 27.3.4 owner-group/configured checks pass 18 in 2.0
  seconds. The shared OTP-29 Hex archive could not load on the floor; isolated
  Hex/rebar tooling under `/private/tmp/loopex-m7-floor-mix` enabled that run.
  These local checks resolve the observed cleanup defect; they do not replace
  M7's prescribed Linux load repetitions or the complete floor closure check.
  Final current-pair shutdown/configured tests pass 18 cases in 2.2 seconds
  with fault-log capture isolated from other test cases. Warning-free compilation
  and documentation ordering pass with 979 covered entries.
- 2026-10-01: configured ordinary staging now checks captured terminal-history
  capability before request construction or provider intent. Unsupported history
  retains an atomic unavailable v2 preparation-refusal/failed-terminal pair with
  cause canonical_history_rendering_unsupported, captured configuration/budgets,
  null scope and null observations. Replay derives the cause from the same retained
  lineage and refuses fabricated numbers, changed causes/configuration, added
  failure members and a missing paired terminal. A compatible fixture mapping
  continues with cancelled results intact. Context, input, interaction and
  configuration regressions pass 101 tests in 18.6 seconds. Other nonnumeric
  preparation causes, measured preparation failures, maintenance/headroom variants,
  real adapter conformance and coordinated wire projections remain pending.
  Final configured-runtime assertions explicitly prove no request or provider
  attempt opens for the refused run: 15 tests pass in 1.7 seconds. Compilation
  is warning-free; documentation ordering covers 978 entries. OwnerGroup
  shutdown_error/noproc diagnostics remain unresolved under T16.
- 2026-10-01: terminal-tool-history configuration preflight passes 45 focused
  conversation/configuration/configured-runtime tests in 1.6 seconds. A later
  run's completion cannot complete an earlier terminal tool turn; empty assistant
  messages do not fabricate a completion. Complete lineage is validated before
  inspecting the captured mapping capability. Recovered live cancelled-question
  history rejects an unsupported candidate, accepts a compatible captured mapping
  and rejects its substitution during replay. The compatible mapping is a fixture,
  not evidence about a real provider. Token/request-record preflight, projected
  checkpoint history, owner integration and ordinary provider-intent gating remain
  open. The existing generic invalid-session-configuration command refusal is
  retained; the named ordinary staging failure still needs its closed projection.
- 2026-10-01: pure configuration admission/replay, update, genesis, configured
  runtime, interaction and input regressions pass 88 tests in 17.9 seconds.
  Accepted configuration rows retain full instruction bytes once; their authored
  changes carry a checked version/digest descriptor, and replay reconstructs the
  original command preimage. Tampered candidates, command identities and
  settled-only refusal categories during active work are rejected. These prove
  reducer preparation only: owner history/request preflight, host resolution,
  maintenance quiescence, live configure and coordinated public wire remain open.
  The run still emits the separately tracked OwnerGroup shutdown_error/noproc
  diagnostics; passing assertions do not resolve that T16 investigation.
- 2026-10-01: the focused second-prompt regression executed one test and failed:
  the next request contains only the new prompt. This is a development red,
  not closure evidence. No provider call was made.
- T01 added subtasks: retain admission order through replay; choose lineage
  validation by the staged record/receipt generation; join results by complete
  run/turn/call identity; preserve old staged requests and old receipt decoders.

- 2026-10-01: conversation unit tests pass (12 tests, 0.08 seconds). The full
  agent-loop file passes 103 of 104 tests (24.7 seconds); the sole failure is
  the retained second-prompt regression. Admission-order recovery and promoted
  follow-up accounting tests pass. Compiled documentation ordering passes.
- Revision-1 normalized IDs bind `Canonical.encode([run_id, turn_number,
  tool_call_id])`; fixed r1/r2 vectors retain the exact 48-hex prefix. Source
  references keep the original run/turn/call identities. Historical projection
  retains its saved call IDs. Request/receipt generation integration remains.
- 2026-10-01: the affected conversation, agent-loop, context, skill, resource
  replay and project-trust suites pass 168 tests in 30.9 seconds. Input-algebra
  passes 11 tests in 5.7 seconds. The original second-prompt regression and a
  runtime-restart regression pass. These are development checks; real-provider
  and closure evidence remain pending.
- New requests bind v2 canonical bytes to revision-4 receipts and normalized
  committed lineage. Retained v1 requests and revision-2/3 receipts retain
  their historical validation. Generation mismatches, omitted/null-cost
  violations and self-consistent substituted history are rejected.
- T01 added subtask: derive missing cancelled/unknown results from committed
  terminal facts before promoting follow-ups; an uncertain effect must remain
  explicit in later context and must not be redispatched.

- 2026-10-01: candidate `34e840c64b865efd915ccbf2675db948d094bf0c` fast
  check failed four tests: two raw-call-ID assertions, the interaction old-reader
  positive control using newly staged v2 bytes, and a Pending-cell test reading
  the filled M6 closure page. All other application suites passed. Full output:
  `/private/tmp/loopex-m7-34e840c6-fast-check.log`,
  `sha256:7769090f45a10180b644872fc8d865fa3c0c6983ba737cbe6c83972b33fdcec2`.
- Corrected assertions verify normalized call/result joins. The actual M3
  reader still evaluates both positive and negative interaction controls, using
  explicitly encoded historical v1 staging and revision-2 receipts. The M6
  scaffold test reads the exact tested candidate `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3`.
  Focused checks pass: core 35 tests in 23.6 seconds and composition 10 tests
  in 10.2 seconds. No historical evidence or reader behavior was changed.

- 2026-10-01: candidate `2d804649ca82ce87b58511bc0739c93e700c7559` fast check passed in
  842 seconds: 11 application suites, 2,638 passed tests. Full output:
  `/private/tmp/loopex-m7-2d804649-fast-check.log`,
  `sha256:47eb0c4b1c6c355e896adda494e82d05f0f6f772a6912df7cbdeaf0222053f7e`.
  Its exact identity is retained separately in
  `/private/tmp/loopex-m7-2d804649-fast-check.sha`. This is current-toolchain
  development integration evidence; the M7 closure matrix remains pending.

- 2026-10-01: shared `SessionGenesis.resolve/2` and `normalize/1` now own
  v2 creation/replay validation. They retain normalized legacy transaction bytes,
  require captured cleanup and closed inputs, and refuse non-plain data and
  normalized items above 65,536 bytes. Creation preserves its legacy malformed
  option and structural refusal taxonomy. Focused genesis/lifecycle/cancellation/
  timer tests pass 37 cases (31.6 seconds; one standard long-bound exclusion);
  runtime/detailed-result/fault/conversation tests pass 119 cases (24.8 seconds),
  and ephemeral API tests pass 15 cases (7.5 seconds). Compiled documentation
  ordering passes with 925 covered entries. The coordinated v3 decoder/writer,
  configuration and exact-genesis live facade remain unchecked.

- 2026-10-01: literal artifact-read revision 1 binds both complete generation
  triples to retained canonical preimages. Four released reference revisions
  share the legacy null capability; the planned 1.1.0 range definition has an
  explicit binding. Unknown read generations, duplicate selections and modified
  bindings refuse. Focused capability/genesis tests pass 12 cases in 0.04 seconds;
  compiled documentation ordering passes with 930 covered entries. Executor
  registration, live range retrieval and v3 genesis binding remain pending.

- 2026-10-01: pure instruction capture/render validation now implements ADR 0042's
  closed four-member input, ASCII version grammar, byte-counted UTF-8 section
  bounds and exact blank-line rendering. Captured section bytes retain the
  rendered SHA-256; replay validation rejects substitutions and extra members.
  Legacy staging uses the same immutable fallback bytes. Instruction/conversation/
  context tests pass 136 cases in 25.3 seconds; compiled documentation ordering
  passes with 936 covered entries. Host configuration, complete system costs and
  configuration-bound receipt provenance remain pending.

- 2026-10-01: the shared decoder now admits v3's complete closed genesis and
  derives its artifact capability from the selected generation. Name bindings
  must bijectively match retained tool definitions. Pure replay retains initial
  configuration, selection and policy-defer mode; v2 keeps its original bytes
  and no inferred selection/configuration. The configuration validator checks
  captured instructions, declared model/output limits, known/unknown/explicit
  input-budget origins, bounded capability metadata and closed provider mapping.
  The generic default descriptor cannot enable another reasoning level.
  System admission counts exact message and model-facing tool-schema costs.
  Decoder/instruction/capability tests pass 32 cases in 0.09 seconds;
  decoder/runtime/conversation/context tests pass 153 cases in 25.3 seconds.
  A corrected metadata-boundary fixture measures its actual canonical preimage;
  tightened generic-mapping and replay tests pass 21 cases in 0.1 seconds.
  Compiled documentation ordering passes with 938 covered entries. Live v3
  creation, provider mapping conformance, frozen run/configuration binding and
  configuration-aware request/receipt staging remain pending.

- 2026-10-01: host-private exact-genesis creation now retains supplied v2/v3
  bytes and normalized original options. Historical duplicates start no owner
  and bypass changed startup defaults/registrations; fresh v3 creation checks
  admitted definitions/model route and kernel request construction. New
  prompt_admitted_v3 and configured model_request_committed_v2/resource v2
  records bind the admitted configuration version. Follow-up promotion inherits
  the captured configuration. Requests use exact captured instruction text,
  model, reply allowance, provider mapping and immutable tools. Revision-4
  instruction provenance is checked against the owning configuration, including
  a self-consistent renamed-source negative case. Captured policy-defer refusal
  denies without an interaction or executor effect. Ordinary measured numeric
  context_admission_refused_v2 retains its own estimator, scope, configuration
  and hard limits; v1 keeps its original rules. Maintenance/headroom/nonnumeric
  refusal variants remain pending with compaction. Runtime/genesis/conversation/
  context tests pass 158 cases in 25.5 seconds; configured/context tests pass
  32 cases in 2.1 seconds, interaction coverage passes 27 cases in 12.3 seconds,
  and configured/detailed-result checks pass 15 cases in 0.6 seconds. Compiled
  documentation ordering passes with 941 covered entries. Full fast integration
  verification is next; reference-host composition, public schemas, provider
  conformance and the closure matrix remain pending.

- 2026-10-01: candidate `d46c8d10881e6ba811b6c1d5204c9545aa785d37` fast
  check passed in 852 seconds: 11 application suites, 2,679 passed tests and
  33 standard exclusions. Full output:
  `/private/tmp/loopex-m7-d46c8d10-fast-check.log`,
  `sha256:36f2a0b3fd02dd092f36a77b44695158066e69aa1ec528032385cc40b35cfc45`.
  Exact identity is retained separately in
  `/private/tmp/loopex-m7-d46c8d10-fast-check.sha`. This verifies the current
  toolchain development candidate; provider conformance, floor-toolchain checks,
  independent-client proof and the M7 closure matrix remain pending.

- 2026-10-01: reference-host `SessionInstructions` captures default, explicit
  base/appendix and role sections with ADR 0042's distinct versions. The existing
  protocol JSON encoder renders only closed workspace/platform/tool-profile
  facts, plus sorted enabled roles and their catalog digest when present.
  Exact escape/Unicode bytes and their independently calculated SHA-256 are
  pinned in tests; the complete escaped environment admits 4,096 bytes and
  refuses one byte more. The existing composition regular-file reader limits
  each selected section to its byte ceiling plus one, validates opened identity,
  and refuses nonregular or replaced files. Captures retain no paths and survive
  subsequent file edits. Focused host-instruction/ask-grammar tests pass 15 cases
  in 0.08 seconds; warning-free compilation and compiled documentation ordering
  pass with 945 covered entries. Configuration parsing, session-creation wiring,
  complete chat-profile system-cost targets and provider demonstrations remain
  pending. No full integration check is claimed for this new checkpoint.

- 2026-10-01: host `ConfigJson` uses OTP 27's standard-library callbacks rather
  than adding a dependency or another syntax parser. It retains ordered object
  members until duplicate validation, emits RFC 6901 pointers, preserves full
  integer precision, and gives fraction/exponent syntax an internal noninteger
  marker for schema refusal. Byte/UTF-8 checks precede parsing; exception details
  and authored values never enter errors. Exact 256-KiB, nesting, surrogate,
  escaped-duplicate and trailing-byte vectors pass on the current toolchain and
  directly under Elixir 1.18.5/OTP 27 (8 tests, 0.04 seconds). This is focused
  floor evidence, not the floor integration or closure matrix.
- Shared `ProviderBindings` validates the complete closed route map against the
  adapter's compiled catalog and refuses operational slots before custody or
  environment effects. It retains references and derives sorted unique launch
  exclusions, including the legacy key. Existing Ollama admits credential-free
  references; credentialed routes require named slots. Focused binding/durable
  option checks pass 21 cases in 6.2 seconds; JSON/instruction/ask-grammar checks
  pass 23 cases in 0.07 seconds. Warning-free compilation, formatting and compiled
  documentation ordering pass with 950 covered entries. File schema, CLI
  inspection, actual custody loading, durable route dispatch and full integration
  verification of these new bytes remain pending.

- 2026-10-01: `ConfigSchema` validates every authored version-1 object before
  overrides: required bounds/policy/routes, closed optional fields, role and
  delegation references, explicit context ceilings and bounded trace settings.
  Turn/token spending bounds preserve integers above uint64; deadlines, cleanup
  and context values retain their existing uint64 domains. Disabled delegation
  and tracing still validate supplied values. Policy names reuse the existing
  ask registry. Trace selectors resolve only exact trusted application-manifest
  modules and the two application wildcards; existing lookalike atoms confer no
  membership, unknown input creates no atom, and metadata reads start no app.
- `ConfigFile` reads one selected regular file through the existing bounded
  reader, validates JSON/schema before resolution, and retains authored/resolved
  profiles separately. Config-relative paths preserve literal tilde/environment
  text and symlink-sensitive parent components; resolved paths also obey the
  4,096-byte ceiling. Prompt files, credentials and configured services are not
  opened by this stage. Focused schema/file/selector/JSON/instruction/ask-grammar
  checks pass 50 cases in 0.1 seconds. Warning-free compilation, formatting and
  compiled documentation ordering pass with 956 covered entries. Model-window
  and reasoning-support resolution, complete effective-profile validation,
  command grammar/inspection and live creation remain pending. This checkpoint
  has no new full integration or closure-matrix result.

- 2026-10-01: `ConfigOptions` parses the three accepted command forms and the
  complete override inventory. Config is required; show also requires effective.
  Inspection refuses every trace flag and resume. Chat rejects duplicate scalar
  flags and conflicting trace booleans; repeated skill/module selections retain
  order and their accepted item ceilings. No provider flag, implicit model,
  positional prompt or new authority default is introduced. Models/policy/trace
  selectors reuse the admitted registries. Decimal values preserve exact large
  turn/token spending integers while deadline/context/cleanup fields retain
  uint64 and trace fields retain the existing ceilings. Structural errors precede
  value checks and errors never echo authored values. Focused options/schema/
  ask-grammar tests pass 32 cases in 0.08 seconds; all connected configuration
  prerequisite files pass 59 cases in 0.1 seconds. Warning-free compilation,
  formatting and compiled documentation ordering pass with 958 covered entries.
  Effective-profile merging, command dispatch/inspection and live chat remain
  pending; no full integration result is claimed for these new bytes.

- 2026-10-01: `ConfigSelection` composes new-session declarations after checking
  the authored and resolved file schemas. Explicit flags win over the supplied
  LOOPEX_HOME state root, then file values, then harmless literal defaults.
  Flag/environment paths are invocation-relative and preserve literal tilde/env
  text; selected arrays replace file arrays and remove obsolete indexed origins.
  Every selected leaf retains flag/env/file#pointer/default provenance. No
  policy/provider/spending default or committed origin is invented; absent
  context budgets remain unresolved and maintenance never inherits a model.
  No-helpers narrows delegation without replacing authored role/allowance data.
  Resume refuses this new-session composition path, pending committed-profile
  preparation. Invalid authored values cannot be repaired by flags. Focused
  selection/options/file tests pass 26 cases in 0.1 seconds; all connected
  configuration prerequisite files pass 70 cases in 0.2 seconds. Warning-free
  compilation, formatting and compiled documentation ordering pass with 960
  covered entries. Model-capability/reasoning admission, authored/effective
  prompt capture and whole-request preflight, redacted inspection, command entry
  and live chat remain pending. No new full integration result is claimed.

- 2026-10-01: adapter `ModelCapabilities` reads the pinned embedded LLMDB
  snapshot directly and verifies its checksum and exact identity before
  capturing bounded context/output limits. Mutable catalog filters, overlays
  and cold loading do not select inspection metadata. The literal Haiku alias
  selects its dated identity; other aliases remain unregistered. Unknown limits
  stay nil, and the reasoning subset remains empty pending deterministic
  mapping conformance. Four focused tests pass in 2.2 seconds, covering three
  known model limits, alias behavior, unknown limits, source bindings and
  malformed specifications. Provider dispatch and whole-profile admission remain
  pending; no provider call or full integration result is claimed.

- 2026-10-01: `SessionConfiguration.resolve/4` prepares a complete initial
  configuration from closed explicit host selections, captured capabilities,
  provider mapping and all selected definitions. Known windows subtract the
  reply reserve once; unknown windows retain 8,192 input tokens independently
  of reserve. Explicit ceilings remain explicit even when equal to defaults.
  The existing complete validator enforces output/window limits, the strict
  combined instruction/tool-schema cost and bounded retained metadata. The v3
  suite passes 20 tests in 0.1 seconds, including six resolution cases and exact
  genesis rejoin. Warning-free compilation, formatting and compiled documentation
  ordering pass with 963 covered entries. Reference-host preparation/inspection
  and live chat remain pending; this is focused development evidence, not a full
  integration result.

- 2026-10-01: `ToolDefinition` admits only the exact reviewed `loopex.ask`
  interaction definition under format v2. Absent class retains effect semantics,
  format v1 and unchanged canonical fields. Interaction declarations are never
  narrowed or completed. The retained vector pins full definition, canonical
  preimage and digest
  `d8cfe746ca4834f2ceabcfb5fa717fa8f53ba06461ee3ae91499fdfad25e138e`.
  Closed question arguments enforce UTF-8 byte limits, optional nonempty
  choice lists and distinct labels before policy. The coordinator rejects the
  executor path for interaction definitions and classifies model-question policy
  defer as policy_unavailable without a nested interaction. Policy allow still
  returns interaction_unsupported until pending/answer/terminal truth is joined;
  no successful model-question workflow is claimed. Protocol definition tests
  pass 14 cases in 0.09 seconds; configured-runtime and registry tests pass 15
  cases in 0.7 seconds. Warning-free compilation, formatting and documentation
  ordering pass with 965 covered entries. Runtime test output also contains
  supervisor shutdown_error/noproc diagnostics, retained as a T16 follow-up;
  passing assertions do not establish cleanup-diagnostic correctness. No provider
  call or full integration result is claimed.

- 2026-10-01: model-question policy allow now commits a producer-specific pending
  request, bound to the exact original call, argument digest, derived question
  and earlier run deadline. A single response row admits the command, settles
  the interaction and original result, releases the slot and advances work.
  Text, choice and decline remain distinct branches; expiry and abort settle
  without a policy reevaluation or executor job. Legacy policy rows cannot
  resolve model questions, and standalone result/intent rows cannot bypass an
  open model question. Pending replay rejects substituted arguments, request
  members, producer, call identity, turn and expiry.
  Configured-runtime, policy-interaction and v3-genesis tests pass 52 cases in
  12.4 seconds, including an exact 8,192-byte UTF-8 answer, duplicate/conflicting
  and stale responses, expiry-boundary admission and atomic abort settlement.
  The broader loop, cancellation, input-algebra and journal suites pass 161
  cases in 72.6 seconds. Final response-identity event assertions and legacy
  interaction checks pass 32 cases in 12.4 seconds. Warning-free compilation,
  formatting and documentation ordering pass with 968 covered entries.
  Supervisor shutdown_error/noproc diagnostics remain an
  unresolved T16 follow-up. Crash injection, private/public wire vectors and
  one-call responder integration remain pending; no provider or full integration
  result is claimed.

- 2026-10-01: four owner-crash scenarios hold the actual Store immediately before
  or after model-question pending and response commits. Killing the coordinator
  and resuming the same session preserves the committed pending identity and
  expiry, emits one answer and original tool result, and dispatches only the
  next model turn. Retained committed proposal payloads compare byte-for-byte;
  pure replay ends with the same answer and no open slot. No executor job runs.
  The pre-response-commit case proves the old transaction's terminal stale-owner
  non-commit and immutable-ID conflict, then settles with a fresh command ID as
  accepted ADR 0006 requires. The post-response-commit case replays the original
  command acceptance without another settlement. Configured-session tests pass
  13 cases in 1.5 seconds. This is in-memory Store fault injection and live owner
  succession; local-store process restart, ambiguous commit injection and wire
  vectors remain separate obligations. Cleanup diagnostics remain open under T16.

- 2026-10-01: pending-question and response commits each encounter an injected
  after-linearization reply loss. The owner resolves the same immutable proposal
  before acknowledgement or further work; retained payloads equal the original
  proposals, question/answer events each occur once, and provider dispatch is
  unchanged while the transactions are held. A composition test stops and
  reopens the real disk-backed local Store twice, first with a pending question
  and then with its settled choice answer. Pending identity, expiry, choices,
  command acceptance and the exact chosen label survive; no executor job runs
  and the already completed model turn never repeats. Both suites share the
  same captured-v3-genesis fixture rather than separate configuration examples.
  Configured-runtime, legacy interaction and v3-genesis checks pass 54 cases in
  13.0 seconds; local-store restart passes one case in 0.2 seconds. Formatting,
  warning-free compilation and patch checks pass. This is focused development
  evidence, not a VM/OS restart, real-provider or full integration result.
  T16 cleanup diagnostics and T09 decoder/public-event vectors remain pending.

- 2026-10-01: `Session.Answer` centralizes the closed choice/text/decline response
  union. Core command normalization and producer-specific answer validation use
  it while retaining old flat choice admission and normalized choice-command
  digests. Literal answer schema and 20 language-neutral vectors cover opaque
  identities, UTF-8 text, decline, mixed/unknown members, padding and malformed
  identity strings. Exact decoded identity and UTF-8 byte limits are checked by
  both implementations; encoded identities are bounded before decoding. The
  independent Node decoder deliberately matches the inherited base64 decoder's
  unused-bit behavior. Five answer tests including the pinned Node payload
  runner pass in 0.07 seconds; configured questions, legacy policy answers and
  input-algebra checks pass 45 cases in 17.9 seconds. Compilation, formatting
  and documentation ordering pass with 972 covered entries. No live server
  generation or method changed: accepted M7 requires one coordinated switch
  containing complete configuration, compaction, bounds and question schemas.
  These are payload checks, not live transport, authority or privacy-canary proof.

- 2026-10-01: `SessionConfiguration.update/5` prepares the complete next candidate
  from committed configuration, a nonempty closed mutable subset and separate
  host-resolved capability/mapping facts. Internal version, metadata, tools and
  maintenance fields cannot be authored. Derived input budgets recompute from
  the new captured window and reserve; explicit ceilings remain explicit even
  when equal to defaults. Unknown windows retain the independent 8,192 input
  fallback, and legacy system origin retains 1,000. Complete validation checks
  captured instructions, all immutable tool schemas, known limits, metadata and
  reasoning compatibility before returning a candidate. Version overflow and
  invalid or oversized updates refuse without changing the committed input.
  Update, v3-genesis and configured-runtime tests pass 42 cases in 1.6 seconds;
  final bounded-update/genesis checks pass 28 cases in 0.1 seconds. Owner settled
  admission, exact history/request preflight, atomic record/replay and live
  configure remain pending. No catalog lookup, model call or compaction occurs
  during pure preparation.

## T00 — Prepare the specifications and test fixtures

### Original checklist

- [ ] Inventory every affected record, API, tool generation, adapter and protocol.
- [ ] Pin schema definitions, digests, compatibility vectors and provider mappings.
- [ ] Create the M7 fixture manifest with exact prompts, budgets, allowed changes and objective results.
- [ ] Assign every operator step and negative scenario to a named test or demonstration.
- [ ] Prepare the indexed closure-evidence scaffold with results marked Pending.
- [-] Retain the exact historical binaries and session roots needed for migration and rollback.
- [ ] Verify manifest completeness, invalid-manifest rejection and actual instruction/tool-schema costs.

### Added implementation subtasks

- [x] Add a read-only numbered checklist reporter that separates original and added counts, validates T00–T19 ordering and preserves the supplied 186-item original denominator.
- [x] Map the 22 accepted contract families to implementation owners and retained/new generations.
- [ ] Join that family inventory to exact payload schemas, path inventories and decoder vectors.
- [x] Pin legacy and planned M7 read-definition canonical preimages/digests and the revision-1 literal artifact-read capability table.
- [x] Create the four fixed base workspace roots and independent repair, feature, review and long-conversation oracles; prove both feature-default branches and positive/negative oracle controls on both toolchains.

<a id="t01-conversation-continuity"></a>
## T01 — Preserve conversation across prompts and restarts

### Original checklist

- [x] First add a failing test reproducing the current loss of earlier conversation.
- [x] Project the complete committed conversation into subsequent model requests.
- [x] Join tool calls and results using their run, turn and call identities.
- [x] Normalize provider-facing call IDs and reject collisions or incomplete joins.
- [x] Reset each run’s accounting without deleting conversation or recovery facts.
- [x] Preserve already staged requests unchanged.
- [x] Test multiple prompts, follow-ups, tools, cancellation, failed runs, restart and uncertain commits.

### Verification evidence

T01's final original item is proved by the following live-runtime cases, with
pure projection/replay tests supplementing them:

- Multiple prompts and tools: `agent_loop_test.exs` checks the second actual
  model request's complete ordered prompt, assistant and tool history.
- Follow-ups: the promoted-follow-up case retains the predecessor's history
  while its new run starts with zero charged tokens.
- Cancellation: `configured_session_test.exs` aborts a pending model question
  and checks that the next actual request retains its cancelled tool result.
- Failed runs: the new agent-loop case commits a tool exchange, fails the next
  model call after transient text, then checks the following prompt retains
  the exchange and excludes that uncommitted text. Live and recovered lineage
  are identical.
- Restart: both legacy and captured-genesis cases stop the runtime and stage
  later prompts from retained history; the configured case also preserves
  exact captured instructions, settings and tools.
- Uncertain commits: the new cases inject `commit_unknown` before persistence
  and after persistence but before the Store reply. Retrying the same prompt
  retains two total runs and exactly one later model request. The recovered
  conversation contains each prompt and answer once.

The complete `agent_loop_test.exs`, `conversation_test.exs` and
`configured_session_test.exs` pass 151 tests on both supported pairs on
2026-10-01. Current takes 26.9 seconds and floor takes 27.0 seconds. These
credential-free checks complete the original T01 testing item; the real-provider
second-prompt witness and milestone closure checks remain open.

- Current output: `/private/tmp/loopex-m7-t01-continuity-current.log`, SHA-256
  `a3fe73a479845861f7e0c53aa087e64c5435352ec21912b3584b901c1bf534f5`.
- Floor output: `/private/tmp/loopex-m7-t01-continuity-floor.log`, SHA-256
  `d2b576cf58dba3c0d3154f9dc6c4ed2e5337085f5a5f4b3cdbc7d40592043969`.

## T02 — Handle large tool output and bounded artifact reads

### Original checklist

- [x] Prepare bounded excerpts while retaining complete original results.
- [x] Implement capability checks from the exact frozen tool definitions and literal capability table.
- [x] Keep replay independent of current host-registry availability.
- [x] Validate artifact ownership and arguments in the session owner before policy admission; add resolved executor data after approval.
- [x] Implement 4-KiB range reads, encoded-result limits, offsets, progress and EOF.
- [x] Add bounded preparation, aggregate excerpt allocation and job-owned transfer accounting.
- [x] Preserve legacy inline behavior where the complete request fits.
- [x] Test escaping, Unicode, forged references, cross-session access, digest mismatch, exhaustion, cancellation and recovery.
- [x] Audit the existing attachment-budget baseline without silently taking on deferred M8 work.

### Added implementation subtasks

- [x] Run verified preparation through the public transfer store after durable reservation; join exact workers before reference/terminal commits and prove uncertain commits, recovery, cancellation, run-cutoff precedence and bounded adapter failures on both toolchains.

- [x] Retain bounded source preparation failure facts and independently derive unavailable refusal-v2/terminal causes; prove no extra source charge or deadline reset and reject unsupported history before reservation.

- [x] Reserve versioned preparation source credit and fixed deadline, commit exact prepared references without recharging, prove replay/membership/immutable projection and forbid staging under an outstanding reservation. Live retention, failure facts and cancellation remain pending.

- [x] Select oversized unfrozen inline sources using complete encoded message cost and reconstruct their exact receipt digest, record byte cost and five-label provenance through replay before durable preparation reservation.

- [x] Implement and test pure exact-generation derivation and retained-binding validation.
- [x] Enforce the literal read-generation table during runtime/registry loading and executor startup; select executor tools by exact ID/version and retain the frozen capability through restart with an empty host registry. Artifact range execution and prepared-reference replay remain pending.
- [x] Resolve committed-receipt artifact membership and closed range arguments before policy, keep policy/deferred identity on original arguments, and bind approved job resolution to the exact retained source. Prove cross-session refusal, uncertain receipt commits, restart and altered-source replay refusal; prepared-reference membership remains pending.
- [x] Reproduce and repair source-descriptor leakage on snapshot creation failure; close snapshot descriptors on permission/unlink failure and verify existing transfer behavior on both supported toolchains.
- [x] Enforce the accepted job-owned cancellation/deadline and cumulative-work bounds when integrating range execution; the attachment implementation does not yet provide these guarantees.
- [x] Implement pure UTF-8 range-result encoding and prove maximal progress under the complete encoded conversation-message ceiling, including escaped content and metadata, through the real lineage projector.
- [x] Implement the maintainer-selected optional job-range callback in the local store, including canonical job validation, closed resolved data, stored provenance, shared capacity, whole-object verification, work reservation, deadline watchdog and descriptor cleanup.
- [x] Join the job-range callback to exact 1.1.0 executor dispatch, unsupported-adapter refusal, range encoding and settlement; prove repeated dispatch does not reopen a completed job and exercise cancellation through the real executor.

- [x] Join receipt-owned ranges through the real session owner, local journal, executor and artifact store; prove restart with an empty registry, immutable object retrieval after workspace changes, and exact range projection into later prompts. Include the required artifact-object source label in the encoded cap.
- [x] Wire the reference host's captured M7 tool selection to read 1.1.0 and provide its job transfer owner even when the public attachment transfer family is disabled.
- [x] Implement pure receipt-content excerpt formatting with the complete 2,048-byte message cap, maximal UTF-8 prefixes, fixed binary descriptions, source digest/ranges and named metadata refusal; verify both supported toolchains.
- [x] Join excerpt formatting to ordinary staging and independently validated replay with retained projection provenance, unchanged historical requests and frozen native prefixes; allocate the shared raw-prefix allowance against both required header variants.
- [x] Complete bounded reference-preparation episodes and prepared-reference membership, then make above-cap inline sources eligible; join the accepted earlier spill rule and pin the remaining new tool generations.
- [x] Resolve the early-spill projection context contract, bind it to exact jobs, pin remaining read/search generations and prove full capture/spill/replay behavior without altering legacy jobs.

### Verification evidence

Receipt-owned excerpts now reach ordinary request staging. Configured private
staging records carry the closed `lineage_projection` revision-1 map with a
shared allowance and ordered source ranges. ADR 0042's revision-4 context
receipts retain exactly 17 or 18 outer keys, as appropriate; the projection is
not an extra receipt member. Review caught that placement error in the initial
implementation before commit; the final tests pin both fixed receipt shapes. Replay reconstructs the expected message and range
from committed result content and artifact membership. Historical unprojected
requests remain readable before the first projected staging record; subsequent rows
cannot drop or null the projection field. Both reader paths reject altered
range offsets, content digests or artifact uses independently of unchanged
request bytes, receipt totals and record sizes.

Required allocation measures allowance zero against both empty resource-header
variants and searches 0..2048 using complete request/receipt admission. Optional
project and resource blocks are admitted afterward. Native exchanges preserve
messages and range provenance from their latest settled request; only newly
appended eligible results use the new allowance. Configuration sizing passes its
explicit retained-history or empty-history candidate through the same projector.
A first implementation accidentally read only admitted run history there; the
existing configuration test caught the omission and the corrected path passes.

The real local-store/executor workflow now completes a file read, two successive
4-KiB artifact reads and a final prompt under its original 8,192-token budget,
including both restart placements and immutable original receipts. This removes
the earlier third-range overflow. An additional live test lowers a captured
context budget and proves that the next larger shared allowance exceeds it.
Native reuse retains an earlier nonempty excerpt when the next result is
projected at zero. Resource integration withholds an oversized optional skill
while retaining the selected required allowance and replayable provenance.

The final broad Core selection passes 198 cases in 28.7 seconds on current and
28.8 seconds on floor. The added exact receipt-shape assertions pass in the
19-case current admission/resource selection in 1.7 seconds and are included in
the floor broad run. Four real session workflows pass in 1.1 seconds on each
pair: two range/restart placements and legacy read 1.0.0 under both v2 and v3
genesis. Both legacy cases preserve their complete above-cap receipt content
with deleted artifact objects and an empty host registry after restart. They
create no new artifact directory or excerpt provenance and replay successfully.
This proves the original legacy-inline compatibility item.

- Current Core: `/private/tmp/loopex-m7-excerpt-staging-record-core-current.log`,
  SHA-256 `4648203883f7bf4a1ec9c12bbe82eb337eccafa1e46ddb0a6f0fa110c6744f0f`.
- Floor Core: `/private/tmp/loopex-m7-excerpt-staging-record-core-floor.log`,
  SHA-256 `eee1c2f8f46235704927a0db4c685c9e99ed021db99f5d9ee3af876061445a28`.
- Current receipt shapes: `/private/tmp/loopex-m7-excerpt-staging-record-shape-current.log`,
  SHA-256 `79c6bef752578544fd568ef46ce14a0ff9f01a93df61ae9be8feb5a3da853eac`.
- Current real sessions: `/private/tmp/loopex-m7-excerpt-staging-record-session-verified-current.log`,
  SHA-256 `1f54d602b39d944ff487f23145b7aaacfe0038d9d86348d2f3349a7ad7bfad7d`.
- Floor real sessions: `/private/tmp/loopex-m7-excerpt-staging-record-session-verified-floor.log`,
  SHA-256 `110a823ce665d77a93671270023314d7c5208a5ed688a58472d38387612e0e2a`.
- Structural checks: `/private/tmp/loopex-m7-excerpt-staging-record-structure.log`,
  SHA-256 `06f0927de989fdf8b1383b7d2c9a6bbd3562c0de97286663adf43ef3d7e52580`.
  The full integration-candidate fast check remains pending at commit time.
- Initial configuration regression, retained as a failure:
  `/private/tmp/loopex-m7-excerpt-integration-core-first.log`,
  SHA-256 `852d693e8f88d84579302023700764183e8780e4b69bacf9a9566913c4b9c560`.
- Initial legacy-fixture compilation failure, repaired before the four-case run:
  `/private/tmp/loopex-m7-excerpt-staging-record-session-final-current.log`,
  SHA-256 `97d4dcce4286de45b4ea551b0f087bde01ad59e73416147261c541f9069847cb`.

This closes the added staging/replay subtask, not the original bounded-excerpt
outcome. Above-cap inline results without usable references remain fixed until
the preparation episode is implemented. No preparation write, early-spill rule,
compaction behavior, new tool generation or closure claim is included here.

The pure ToolResultExcerpt formatter accepts an existing full artifact reference
and a raw-prefix allowance from zero through 2,048. It measures both JSON layers
with the actual call identity and preserves the terminal outcome. The notice
labels receipt-content offsets separately from object identity. The returned
source range hashes the original content once after prefix selection. Invalid
UTF-8 uses a fixed description; metadata that cannot fit returns
`artifact_metadata_unrepresentable`. No artifact write or read occurs.

Seven formatter cases cover exact metadata, zero allowance, source saturation,
all five terminal outcomes, binary content, invalid input and metadata overflow.
The maximality cases independently try the next complete codepoint across ASCII,
multibyte and heavily escaped sources at ten allowances. Together with the
existing conversation suite, 22 tests pass in 0.09 seconds on current and 0.1
seconds on floor. This completes an added formatting subtask only. The original
bounded-excerpt item remains open while reference preparation is incomplete.

- Current: `/private/tmp/loopex-m7-excerpt-formatter-final-current.log`,
  SHA-256 `3adefc2f08d96bc8d54d1f1ca62f74fc3aa7fdc2044f121931877301818a05cb`.
- Floor: `/private/tmp/loopex-m7-excerpt-formatter-final-floor.log`,
  SHA-256 `948ed307d916c6d9ec6a0e4e310c68f8e4899b0982eae87437fced96e1e273a8`.
- Structural checks pass: `/private/tmp/loopex-m7-excerpt-formatter-structure.log`,
  SHA-256 `aca28af75467bb93edec4b7b67341791f89fbba9b41900f82af60a7bfe61a515`.
  These focused checks do not replace the pending full integration-candidate run.

Configured chat now selects the exact read 1.1.0 definition from composition's
inventory before deriving and retaining its artifact capability. Nonempty durable
constructor selections admit both read generations. The existing Core exact
ID/version selection pins legacy activation to read 1.0.0, so admission of the
new version does not rewrite old defaults. Empty selections remain empty.
The captured-chat test proves real v3 creation and restart with that selection.
The CLI continues to depend on composition rather than a concrete executor.

The durable composition always starts one existing Transfers owner and supplies
it to its executor's artifact handle. The current active-tool list cannot decide
whether this owner is needed: a resumed session may hold a different frozen read
generation. The public attachment family still receives a runtime artifact store
only when `artifact_transfers: true`. Both uses share capacity when enabled. The
new always-started process follows the existing composition owner, partial-start
cleanup and interrupt chain; no new ownership layer or option was introduced.

Tests now inspect all eight single-credential composition edges rather than only
the first four, retain reverse-order partial cleanup, inject transfer-start
failure, and await actual transfer DOWN after independent-owner runtime stop.
The dual-credential constructor joins all nine edges. All 128 legacy active-tool
subsets still reach each constructor with read 1.0.0 selected exactly, while
configured chat pins the accepted 1.1.0 digest. This completes the added host
wiring subtask without closing another original T02 item.

The current toolchain passes 53 composition cases in 30.8 seconds, nine additional
kernel-composition cases in 0.5 seconds, and 96 CLI cases in 26.4 seconds. The floor
passes the same 62 composition cases in 30.9 seconds and 96 CLI cases in 26.0
seconds. Applications and toolchains run sequentially in separate VMs.

- Current composition: `/private/tmp/loopex-m7-host-range-final-composition-current.log`,
  SHA-256 `5436bf63bf726cc610a3301b71fa23505404147a84b664d41c067138edf0c24c`.
- Current kernel composition: `/private/tmp/loopex-m7-host-range-kernel-current.log`,
  SHA-256 `c2c718afdacae58bc82b9368f92b9e12efe01b80a592323731edc6b731d63e54`.
- Current CLI: `/private/tmp/loopex-m7-host-range-cli-final-current.log`,
  SHA-256 `adb44129bb811678cc5190508860706356d0a5f1d90ab6f4e2320e4dcd22bb75`.
- Floor composition: `/private/tmp/loopex-m7-host-range-composition-floor.log`,
  SHA-256 `dcfee510ec52cec9b7ea8d5cd3258dadee94b94cff47ccd245002f7802e57fc9`.
- Floor CLI: `/private/tmp/loopex-m7-host-range-cli-floor.log`,
  SHA-256 `972c6762b5c3df2beb218ab07a624db0428bc3c4309403b90a9956c81c69a5cf`.

Earlier runs exposed stale startup-edge expectations and a cleanup witness that
sampled the transfer before its independent owner finished stopping it; the
witness now joins its monitor. Captured creation then refused because the runtime
had not admitted 1.1.0; admitting both versions through existing selection
semantics resolved that defect. The CLI architecture check rejected a direct
executor reference in chat preparation; using composition's inventory preserved
the boundary. These failures remain retained and do not count as passes.

- Initial placement failures: `/private/tmp/loopex-m7-host-range-placement-current.log`,
  SHA-256 `3845d16575dbc25da608c8f897919e1bcc12e92e746a6cdf130b8cd131e6d9cf`.
- Missing runtime admission: `/private/tmp/loopex-m7-host-range-chat-current.log`,
  SHA-256 `715b5e2ca7b5b82a7616aac9868356b3300649ae812ff9fb8e0eaa1f74384a18`.
- CLI boundary failure: `/private/tmp/loopex-m7-host-range-cli-regression-current.log`,
  SHA-256 `57542a51b8beb9001ff6ac6b13cbc25d88fe4a436193455dbdf75c97b73746b9`.


The full receipt-owned range path now runs through a real session coordinator,
local journal, local executor and local artifact store. A scripted model reads a
32-KiB workspace file, the host obtains its committed public use reference, and
a later prompt requests 4,096 bytes at offset 20,000, beyond the original inline
prefix. Two witnesses restart the runtime, journal and executor either before
retrieval or after it. Both resume with an empty host registry and a changed
workspace file. The original object supplies the exact bytes, the job binds the
preceding receipt's digest/version, replay restores the same membership, and the
next ordinary prompt preserves the complete range message. No retrieval result
adds a new artifact.

Review against ADR 0041 found the explicit range encoder omitted its required
`excerpt_source: artifact_object` member. The member is now part of the encoded
result and its complete-message measurement. Existing maximality, escaping,
UTF-8, progress, first/final/empty and refusal tests pass with it. This closes the
original 4-KiB range-read item; prepared references, excerpt allocation and
reference-host startup selection remain open.

Twelve composition cases pass in 1.8 seconds on the current toolchain and 1.9
seconds on the floor; seven encoder cases pass in 0.1 seconds on each. The
application suites run in separate VMs.

- Current composition: `/private/tmp/loopex-m7-range-session-current.log`,
  SHA-256 `362131df6ef32f23cf147ae80b5768b3e1bd357d5df13c266c9039b2bac31390`.
- Floor composition: `/private/tmp/loopex-m7-range-session-floor.log`,
  SHA-256 `e43bb91971b298c8a04d437cffeca0b3f3d3f259cdb556c058d218e2ee6da642`.
- Current encoder: `/private/tmp/loopex-m7-range-source-current.log`,
  SHA-256 `c2ff6bc5e22a9c4bd4367e3b69fb64555fe6a214aaec4d936eb54412f8865188`.
- Floor encoder: `/private/tmp/loopex-m7-range-source-floor.log`,
  SHA-256 `3b591d3939b94e7839747c51f7617d07ec081f97a8c435d549627a81b7b8238d`.

The initial fixture supplied a framed newline to the strict payload decoder;
the prompt now contains only the JSON payload. A later exploratory third range
completed its executor job but its following model request correctly refused
at 8,327 estimated tokens against the unchanged 8,192-token limit. The earlier
large result is still inline: this is evidence of unfinished excerpt projection,
not a reason to raise the limit. The restart witnesses isolate retrieval and
history preservation with a terminal follow-up instead; the longer workflow
remains an obligation of excerpt/compaction integration.

- Initial framing failure: `/private/tmp/loopex-m7-range-session-first.log`,
  SHA-256 `405dd2ddfaf54130aff345431f1e1e60ce8fae415bb13ce5fc033f14ac645a21`.
- Decoded failure evidence: `/private/tmp/loopex-m7-range-session-diagnostic.log`,
  SHA-256 `c1e65d65d0ec82e3a16310d075cc66567adfa73f1b1885a90ba05df806a9a1ba`.
- Third-range failure: `/private/tmp/loopex-m7-range-session-framing.log`,
  SHA-256 `21a9f10cff8ed6fcc057e3ed602678e09ffb707efc27e38fe60410d6a13ac676`.
- Retained numeric refusal: `/private/tmp/loopex-m7-range-session-restart-diagnostic.log`,
  SHA-256 `cda6055347159ac112f7ef96f0edde9b4b4467880287a87eefeb4ede91b19224`.


The local executor now serves the pinned read 1.1.0 definition alongside 1.0.0,
selects dispatch and retained-receipt readers by both ID and version, and keeps
the legacy default selection. The new path branch is closed and retains ordinary
workspace reads. Artifact requests use only the optional job-range callback;
adapters without it refuse without falling back to whole-object fetch. Encoded
range results return directly with no recursive artifact spill.

Range cancellation registers a temporary job-specific message alias after the
reader is monitored and before it starts. The caller closes that alias before
draining requests, so a late sender cannot cancel a subsequent job in the same
caller. Cancellation kills and observes the exact reader and guardian under one
cleanup episode. The existing settlement path answers `cleaned` only after the
confirmed receipt is retained and open authority removed. Deadline failure says
no range was returned; it does not claim that no storage bytes were read.

Ten composition tests join the real local executor and artifact store. They
cover escaped/UTF-8 windows and EOF, legacy adapters without the callback,
invalid grants and closed arguments, both path generations, cancellation after
verified IO and while transfer admission is queued, deadline expiry, a reused
caller with an expired cancellation alias, and restart/repeated dispatch after
the original object is deleted. Successful, cancelled and deadline-failed jobs
each invoke the range callback once. These witnesses complete two added T02
subtasks. Original T02 items remain open where excerpt preparation, prepared
reference membership or the composed session-owner workflow is still missing.


Final range-executor verification passes all 165 focused cases on each supported
toolchain, with the composition and executor applications run in separate VMs.
The long-bound and real-provider lanes remain separate required release proof.

- Current integration, 10 cases in 1.5 seconds:
  `/private/tmp/loopex-m7-range-executor-verified-current.log`, SHA-256
  `7f71c6e849cf18f1b4e6c14112aa10d540b065bce6709c3df09cc2d0cb2a7e28`.
- Current executor regression, 155 cases in 117.2 seconds:
  `/private/tmp/loopex-m7-range-executor-verified-regression-current.log`, SHA-256
  `9061061fa977b499654dc25e5827cd3f2012b7056ce103198e6f87f43bf0b730`.
- Floor integration, 10 cases in 1.5 seconds:
  `/private/tmp/loopex-m7-range-executor-verified-floor.log`, SHA-256
  `1d938bf4eb2dd050303a64acd791e00e3c217766afc52ee1232389705ad6e4ba`.
- Floor executor regression, 155 cases in 118.7 seconds:
  `/private/tmp/loopex-m7-range-executor-verified-regression-floor.log`, SHA-256
  `1882bfb41263287da448c9eea207ebe6e7dee5df9dde0f54d20f82ad857edf0a`.

The first integration run exposed missing filesystem cancellation routing and a
fixture that changed arguments under a reused job ID. Cancellation
was implemented and the malformed-arguments fixture now uses a distinct job ID.
The first broader run passed 154/155 cases; its structural assertion expected a
four-argument guardian call. It now recognizes the added cancellation argument
while still requiring `effect_owner/0` in the fourth position. Neither failed
run counts as passing evidence.

- First integration failure: `/private/tmp/loopex-m7-range-executor-first.log`,
  SHA-256 `ca1cdb49e8ab2adc8c5e53e7b4166477e71ebcd05224d4fff9ebfa496715173f`.
- Initial executor regression failure: `/private/tmp/loopex-m7-range-executor-regression-current.log`,
  SHA-256 `040f1d80db604ff69378af75c202a599c248be88dbd075383e0b8d77bce28e09`.

On 2026-10-01, the maintainer answered the storage-boundary decision with
“Separate optional job-range callback (recommended).” The presented choice was
`ArtifactStore.read_job_range(handle, validated_job)`, performing one verified
window with job deadline/cancellation, shared four-transfer capacity, bounded
work accounting and cleanup before return. Adapters lacking the callback refuse
job range reads; the existing attachment triple stays compatible. The alternative
was versioning and extending that triple with job context. This records the
current maintainer decision authorizing the new cross-application callback.
The local implementation is described below; executor integration remains pending.

The optional port callback returns only the requested raw bytes, shortened at
EOF, after cleanup. It runs in the executor's disposable I/O process, which may
be terminated to enforce a bound. `Runtime.ArtifactRead.job_range/1` independently
validates the canonical job and closed 1.1.0 resolution before storage. The local
adapter revalidates the full object/use binding and matches all five provenance
labels against the resolved source and current session. The session owner still
owns proof of journal membership; this callback does not reconstruct the journal.

The transfer owner reserves one of its four shared slots and monitors the job
caller. All file I/O stays in that caller; a linked watchdog owns no descriptors.
The watchdog can terminate a caller blocked in I/O or waiting for admission,
enforces the earlier monotonic/wall cutoff, bounds opening at 60 seconds and
reading at five seconds, and stops the caller if the transfer owner disappears.
The one-shot window's lifetime is consequently shorter than the ten-minute
transfer ceiling. Successful return follows source/use/snapshot closure,
capacity release and observed watchdog termination. Caller death releases its
slot through the monitor. Existing attachment operations retain their API.

Before storage, the callback reserves the greater of 1 MiB and the full source
read plus snapshot write plus requested emission. It refuses objects above
64 MiB or reservations above the 1-GiB job allowance. The debit begins at 1 MiB
and grows monotonically with observed reads, writes and emission. A failed write
conservatively charges its attempted length once. The local verifier also rejects
insufficient open-work allowance before opening the object. The callback opens
one window and has no reopen loop; the executor's repeated-dispatch proof remains
an integration obligation rather than a claim about direct adapter calls.

The shared verifier now validates the local 64-character hexadecimal locator
before constructing a path. A negative case supplies a valid canonical use whose
locator names an existing non-object file; the local namespace refuses it.
Use-record reads are bounded by the existing canonical-use ceiling, reject
trailing bytes, and reject compressed terms before decoding. Existing canonical
use bytes remain unchanged.

The real-storage witnesses cover first/last/empty ranges, corruption outside the
requested range, session/source mismatch, malformed resolved jobs, capacity in
both directions, queue-time deadline expiry without late reservation, and
open-work refusal before source I/O. Scoped tracing observes actual source/use/
snapshot descriptors closed while the caller remains alive, plus exactly one
source pass and snapshot write on success and corruption, with emitted bytes
charged only on success. The complete Store suite passed 89 tests on each
toolchain before the final locator case and monotonic-debit refinement. Final
focused transfer tests and Core artifact tests cover those final changes; this
is not yet a complete executor or closure proof.

Final transfer tests pass 41 cases in 1.9 seconds on each toolchain; Core
artifact tests pass 14 in 0.8 seconds on each. Retained outputs:

- Final current transfers: `/private/tmp/loopex-m7-job-range-boundary-current.log`,
  SHA-256 `cb07936c62a545ff9cbcf2bdb085910bc0a2ca28b2c6fe01696a26c29734a6c9`.
- Final floor transfers: `/private/tmp/loopex-m7-job-range-boundary-floor.log`,
  SHA-256 `4d66e3b7a14906106957fa261498949867066274b47131d0b9049f6211231042`.
- Current Core: `/private/tmp/loopex-m7-job-range-core-current.log`, SHA-256
  `c53cdbe53a35e7ff5b018cd6191dc4928089a7017765c94b098ba1edfe7ab3ed`.
- Floor Core: `/private/tmp/loopex-m7-job-range-core-floor.log`, SHA-256
  `bf4177db653357efd2e6a9c8a8a03c0e9f147635bc5abd156ec03fd0d7de552c`.
- Earlier complete current Store suite, 11.3 seconds:
  `/private/tmp/loopex-m7-job-range-store-current.log`, SHA-256
  `655d69c123586448b596ba852327ea973998c565c9da55d29357a09baed911f5`.
- Earlier complete floor Store suite, 11.1 seconds:
  `/private/tmp/loopex-m7-job-range-store-floor.log`, SHA-256
  `2b0152cb9d85ed30229d25fc4fcba0a5ba5ce5935c6a2b8b1567bd560085371f`.

The first seven-case run exposed an extra `artifact_unreadable` wrapper around
the new oversized-use refusal. The adapter now preserves the existing
`artifact_integrity_failed` classification and keeps actual I/O errors distinct.
That failed output is retained at `/private/tmp/loopex-m7-job-range-first.log`,
SHA-256 `230c66ceab158e1cfc330da5efffab27289989fed65dc07ff78a5937e088327d`.

`Executor.Local.ArtifactRange` now encodes an already verified window, without
storage access or a claim of membership/integrity validation. It retains the
original full reference, actual offset/count, next offset and EOF. Malformed
UTF-8 and starts inside a codepoint refuse; a partial trailing codepoint shortens
only before object EOF. If no whole character fits, it refuses instead of
returning zero progress. Offset at EOF permits an empty result. A binary search
over codepoint boundaries chooses the largest prefix fitting the encoded limit.

Sizing includes the actual conversation tool-message shape, including its
second JSON escaping of the inner range content. Revision 1's fixed 51-byte
normalized call ID permits exact measurement without putting a fabricated ID
into executor output. A real `Conversation.lineage_entries/1` witness uses a
long original provider ID, retains the range bytes exactly and proves the final
message matches that measurement. Additional cases cover escaping, UTF-8,
metadata exhaustion, invalid windows, final ranges and maximality across seven
limits. This prepares encoding; it does not yet enable the 1.1.0 executor tool
or complete the original range-read checkbox.

All seven range-encoding tests pass in 0.09 seconds on each supported toolchain.
Retained outputs:

- Current: `/private/tmp/loopex-m7-range-projection-current.log`, SHA-256
  `a5a85d11d33bec3fac3c37c02870ba8c67a1e629e5450726cb9802fe4501f0e2`.
- Floor: `/private/tmp/loopex-m7-range-projection-floor.log`, SHA-256
  `68ef29af9d964c47bc74555be1ca5ba58444a14fb49bb57bf8da8d6d74b0cfdd`.

The attachment baseline audit follows `Runtime.EventDispatcher` through
`Store.Local.Artifacts` into `Store.Local.Transfers`. The dispatcher counts two
transfers per attachment, and the shared store owner counts four live transfers.
It does not implement a connection-wide cumulative work ledger. This agrees
with the existing disclosure in
[runtime and embedding](../developer/runtime-and-embedding.md#technical-embedding-transfers).
The local verifier checks the 64-MiB object limit, hashes the whole object into
an unlinked snapshot, checks an elapsed open deadline between copy blocks, and
subtracts source reads plus snapshot writes from its per-open budget. That
budget is checked on the next iteration rather than reserved before storage.
The read path bounds emitted chunks but does not enforce the advertised
five-second read deadline. Neither adapter forwarding nor its transfer owner
binds open/read work to an executor job's deadline or cancellation.

These findings do not prove ADR 0041's job profile. Its one-window ownership,
shared runtime capacity, shortened deadlines, pre-storage reservation, minimum
open debit and cumulative job allowance remain implementation obligations.
Connection-wide attachment remediation remains outside this T02 audit; no
protocol, connection budget or attachment ownership behavior changes here.

The audit also reproduced a cleanup defect: replacing the snapshot directory
with a regular file makes snapshot creation fail after the source opens. The
new serial regression captures that descriptor and reads it in its owning
process after the failure acknowledgement. Before the fix it returned a source
byte; afterward it returns `einval`, with the owner still alive and no retained
transfer. Source opening now scopes cleanup over snapshot creation and copying.
Snapshot permission/unlink failures also close the opened snapshot descriptor
and attempt to remove its path. The latter branches are inspected cleanup paths;
the deterministic fault witness exercises snapshot creation failure.

Both complete transfer test files pass 30 tests in 1.5 seconds on each supported
toolchain. Retained outputs:

- Initial failing regression: `/private/tmp/loopex-m7-transfer-cleanup-before.log`,
  SHA-256 `f323d15cfcf0dbe34aa7e80dbc2a55689aa6a22449a8b67de4e252362c5556ce`.
- Current: `/private/tmp/loopex-m7-transfer-cleanup-current.log`, SHA-256
  `ada62ea8a3b5c5d303bf4ef77b183f4fa10c9b86196a729d9fc57056b7514314`.
- Floor: `/private/tmp/loopex-m7-transfer-cleanup-floor.log`, SHA-256
  `523119e0701cfa20b6855f3232951a53ef3bd1a837969cd372a7bf3576d3bbde`.

Receipt admission now reconstructs a private use index from committed executor
receipts. The index stores the full reference and its earliest source identity;
conflicting reference bytes make a use unusable. The source digest is the
canonical digest of the complete private receipt-record payload, alongside its
journal position and original run/operation/attempt/call identities. This is a
derived cache, with no new receipt fields or object reads. Ordinary path arguments
and artifact ranges have separate closed branches for the exact M7 read generation.
Unknown/injected/cross-session uses, invalid bounds and offsets beyond object size
produce the same failed `invalid_tool_arguments` disposition before policy.
Offset equal to object size remains admissible for the executor's EOF handling.

Policy and deferred interaction identity retain the original model arguments.
After allow, the journaled executor job receives `resolved_artifact`; replay
recomputes it from preceding committed sources and frozen definitions. A
self-consistent job digest cannot substitute the source. Receipt commit-unknown
on either side of persistence retains one reference, and a held uncommitted
receipt admits no subsequent read policy or job. Restart reconstructs membership
with an empty host registry. These tests use a scripted executor to prove owner
admission; real range IO, transfer accounting and prepared-reference records are
still pending and the original ownership/recovery items remain unchecked.

Seven new cases plus the affected artifact, agent-loop, interaction and configured
session suites pass 165 tests on each supported pair, in 38.5 seconds on current
and 38.7 seconds on floor.

- Current admission/regressions:
  `/private/tmp/loopex-m7-t02-artifact-admission-regressions-current.log`, SHA-256
  `57321d9da5d4a4a0fefc299669318e28c760fa0f37cd3643cc0e59b4a22afa80`.
- Floor admission/regressions:
  `/private/tmp/loopex-m7-t02-artifact-admission-regressions-floor.log`, SHA-256
  `ba8fd9afb57b534732335a060ed3de2039b4f657a6901bd2cf4c0c08eb15a9eb`.
- Initial five-case admission proof, 0.7 seconds:
  `/private/tmp/loopex-m7-t02-artifact-admission-current.log`, SHA-256
  `1fc7dfee0dfdeff15191a060cd1c7bb689614bd979307c830ee34ae0d7481747`.

Runtime startup and reference registry loading refuse changed read versions,
descriptions and budgets. Both pinned read generations coexist in the runtime
registry and resolve individually. The local executor checks its compiled
definitions against the same literal table before starting; job resolution
matches ID and version together. A valid host grant cannot make an unavailable
read version execute as the legacy generation. The configured-session restart
test stages three prompts across two runtimes with the exact M7 read definition;
the second runtime has no registered read tool, while recovered genesis retains
the original capability digest and staged definitions.

For the generation-check change at `1c3670de5cd51057dde2be23c173a5a42ab26a1b`,
the current Core suite passes 785 tests with its five existing long-duration
exclusions in 158.4 seconds. The 86 affected Core tests pass on the floor pair
in 3.8 seconds. Local-executor/coding-tool tests pass 148 cases on both pairs,
in 114.5 seconds on current and 116.5 seconds on floor.

- Current Core: `/private/tmp/loopex-m7-t02-core-fixed-current.log`, SHA-256
  `297e08c4f0960c94139fc581b191d63f0e8d1529c4eaf44c23d58e5bc2c3d1ba`.
- Floor Core: `/private/tmp/loopex-m7-t02-core-floor.log`, SHA-256
  `941753f9293a8f8655f68b07d3133536ac9c4c0748cd8b1ca63bdd9b452e570c`.
- Current executor: `/private/tmp/loopex-m7-t02-read-executor-current.log`, SHA-256
  `b8019ca4cfc0d8905cf90673e60cf0b659400721e9fd224cedd5139d96484fca`.
- Floor executor: `/private/tmp/loopex-m7-t02-read-executor-floor.log`, SHA-256
  `f0345548b40d5897efd9be1a5dc7637081b4fc1782d55306cc9d1d01f0f9a5f6`.

The first Core run failed six tests. Five used a stale reference read fixture
with a 65,536-byte output budget instead of the pinned 16,384-byte value. The
fixture now matches the literal generation without changing its exact size or
token assertions; its obsolete startup fallback no longer turns a refusal into
a bogus runtime reference. The sixth test depended on suppressed SASL reports
and raw rather than translated supervisor text. It now enables that report class
within the serial test, restores the original filter configuration and still
requires the actual child-failure report and reason. No production logger policy
or check was relaxed.

- Initial Core failure: `/private/tmp/loopex-m7-t02-core-current.log`, SHA-256
  `46233f458a3036707c926c07eb575a66f0fbe99f1e453f6a716fabdedd5d7136`.
- Focused repair proof, 26 cases in 2.1 seconds:
  `/private/tmp/loopex-m7-t02-regression-repairs-current.log`, SHA-256
  `26a26f4e237d3a44279837b66221c6b9f5e4cef31837d10891bb7cc7cb5707f0`.
- Initial registry test expected an internal refusal instead of the established
  public `invalid_runtime_options` response:
  `/private/tmp/loopex-m7-t02-read-registration-current.log`, SHA-256
  `e66f11bae7f1c59c0ab32d44524f4590e4b4018ffb634ceeb4d5d5a95e01fbf6`.
  Corrected 32-case run passes in 0.5 seconds:
  `/private/tmp/loopex-m7-t02-read-registration-fixed-current.log`, SHA-256
  `37e9f867e0ac1c0efe0af5a3fc12aa287ac6ad7b0ca6d03ca06fdc3c0afbbdbf`.

## T03 — Implement host-composed instructions

### Original checklist

- [x] Replace core’s fixed instructions with the accepted host instruction map and rendering.
- [x] Keep project and skill resources separately typed and admitted.
- [x] Capture workspace/environment facts and exact selected tool schemas.
- [x] Enforce the configured system ceiling and complete serialized-request limit.
- [x] Implement receipt revision 4, including continuation costs and source/configuration binding.
- [-] Preserve old receipt decoding.
- [x] Test admitted, declined, changed and oversized instructions, long paths, restart and exact staged bytes.
- [ ] Prove instructions cannot widen policy or helper authority.

### Added implementation subtasks

- [x] Implement pure closed instruction capture, exact rendering and retained-digest validation; preserve legacy fallback bytes through the shared renderer.
- [x] Stage captured v3 instructions with configuration-bound revision-4 provenance and exact system/tool costs; reject substituted configuration/source identities on replay.
- [x] Implement reference-host default/explicit/role capture, bounded regular-file reads and exact JSON environment byte/digest vectors; prove captured facts and immutable schemas in live chat staging. Public command startup and role-helper joins remain pending.

- [x] Prove through live v3 owners and replay that exact host/role instruction sections cannot override a denying policy or enable unselected write/task calls; retain a successful admitted read as a positive control. Actual helper-adapter authority and nesting proof remain open.

- [ ] Retire the v2-only session instruction fallback after current-format genesis migration, while retaining the reference host's authored default capture.

## T04 — Implement configuration, genesis and provider routing

### Original checklist

- [x] Implement the shared pure genesis resolver and validator.
- [x] Support exact-genesis creation, finding duplicates before expanding changed defaults.
- [x] Implement the closed configuration-file schema and command-line grammar.
- [x] Implement file/flag precedence, validation and effective-value display.
- [x] Require explicit conversation bounds in the file, including when flags override them.
- [ ] Retain committed session settings, tool selections, roles and delegation declarations.
- [ ] Allow maintenance settings to change new episodes while preserving already admitted episodes.
- [ ] Implement named provider and credential bindings through the existing custody boundaries.
- [ ] Abandon prepared owners on every post-preparation refusal; retain uncertain cleanup honestly.
- [ ] Test malformed files, duplicate keys, overrides, resume conflicts, missing bindings, changed catalogs and cleanup failures.
- [x] Prove configuration inspection reads no credentials and starts no runtime or provider call.

### Added implementation subtasks

- [x] Prepare durable ask's complete current v3 genesis before placement and credential custody, retain canonical model/instructions/derived capacity and exact selected tools through the public create facade, keep concrete adapter imports in composition, and prove real Local Store create/reopen/resume, capture refusal, tool profiles, resource and cleanup cases on both supported pairs. Retain failed complete CLI outputs and their focused repairs; other host creation paths and Core v2 removal remain open.

- [x] Prepare complete current ephemeral genesis before owner activation, join the accepted instructions/reasoning/system-ceiling options and derived context origins, share reference instruction capture with chat/inspection, and forward exact genesis through the private facade actor with one retained selected-tool inventory. Prove exact repeated HTTP staging, route privacy, admission negatives, question/call-owner lifetime and cleanup through the complete composition suite and affected CLI cases on both supported pairs without changing production limits or test time bounds. Other host creation paths and Core v2 removal remain open.

- [x] Migrate the thin embedded reference client and its deterministic/real-provider fixtures to exact current v3 host genesis; remove options-only creation from this client, retain captured model/instructions/bounds and immutable tools, update configuration-bound record readers, and prove exact retention, malformed/superseded refusal, duplicate creation and the complete credential-free effect/restart/recovery suite on both supported pairs. Other host creation paths and Core v2 removal remain open.

- [x] Expose the approved public prepared configure facade with separate authored input and resolved candidate; prove live admission, replay, refusal, unknown commits, restart and malformed routing on both supported toolchains.
- [x] Share the v2 resolver/decoder between creation and replay; pin unchanged transaction bytes and exact normalized byte boundaries.
- [x] Extend that same resolver/decoder with v3 configuration, immutable tool selection and literal artifact-read derivation.
- [x] Validate closed captured configuration, combined metadata byte limits, budget origins and complete system-class tool costs; retain v3 settings through pure replay.
- [x] Resolve complete initial configurations through that validator, deriving known/unknown context budgets and retaining explicit/default origins.
- [x] Integrate v3 creation and configuration-aware live owner staging, including frozen request/receipt identities.
- [x] Implement bounded JSON syntax decoding with exact integers, redacted errors and duplicate-key JSON pointers; prove callbacks under both supported toolchains.
- [x] Implement shared pure provider-binding/reference validation and sorted launch exclusions from the adapter's compiled catalog; environment resolution/custody/startup integration remains pending.
- [x] Validate closed authored-file objects, required conversation bounds, role/route/delegation relationships, explicit context ceilings and trace limit domains before overrides.
- [x] Load bounded selected regular config files, retaining authored/resolved profiles with config-relative literal paths and resolved byte bounds; prompt-file and effective-profile admission remain later stages.
- [x] Resolve trace selectors through fixed trusted application-module manifests without input atom creation or application startup; owning trace startup/drain/teardown integration remains pending.
- [x] Parse the complete chat/config-inspection flag grammar with duplicate/conflict refusal, bounded array overrides, exact numeric domains and shared registries; effective-profile and command-entry integration remains pending.
- [x] Compose new-session file/flag/LOOPEX_HOME precedence and harmless literal defaults with complete value origins and array replacement; capability/instruction admission and redacted effective display remain pending.
- [x] Join selected new-session declarations, captured instructions and tool definitions to credential-free route/mapping resolution and whole-configuration admission, preserving effective budget origins.
- [x] Admit the durable adapter's closed token-route branch and select the committed provider before child startup; prove selected private bootstrap and unbound-route refusal.
- [x] Share explicit durable credential loading between direct and borrowing plane constructors, with complete-name validation, deduplicated reads, joined partial-start cleanup and fresh borrowed trace capabilities.
- [x] Carry configured launch exclusions through executor job and drain ownership, preserving legacy receipts; prove first-image exclusion after reinsertion and real job/helper propagation.
- [x] Validate and forward captured exclusions inside project Git discovery, resource-import executors and placement probes, including lock release; reject the conflicting LC_ALL credential slot before loading.
- [x] Admit direct and borrowed version-2 planes in durable runtime composition, validating every token route and resolving explicit maintenance selection before owned effects; prove all three constructor lifecycles and partial-loading cleanup.
- [x] Forward immutable exclusions to Store writer probes, executor launches and provider companions; preserve private model options and unchanged marker, job and receipt formats.
- [x] Wire daemon bootstrap through shared binding validation/loading, multi-custody ownership and cleanup, model/maintenance forwarding and scoped placement acquisition/release.
- [x] Extend the offline CLI credential cache and shared startup to borrow explicit routes, refuse rebinding and scope discovery/placement exclusions; verify existing recovery workflows on both toolchains.
- [x] Forward explicit foreground-server provider/model/maintenance options with preflight refusal and real subprocess startup/EOF cleanup on both toolchains.
- [ ] Finish provider bindings and captured exclusions through chat, daemon-command and remaining ask/helper entrypoints, including discovery and helper preparation.

- [x] Join config validate/show to the actual command entry, resolving every saved role and whole parent genesis before a redacted effective report; prove aliases, exact quantities, origins, child costs, cold credential-free startup and Unicode output on both supported toolchains. Public chat startup and committed-resume reporting remain open.

## T05 — Update records, protocols and independent clients

### Original checklist

- [ ] Implement every new record/request generation before emitting it.
- [ ] Add foreground protocol /3 and daemon protocol /4.
- [ ] Produce complete payload-schema manifests and reproducible digests.
- [ ] Update both servers and the independent Node clients together.
- [ ] Update daemon mutation, capacity, lease and succession inventories.
- [ ] Implement bounded snapshots and events with consistent replay cursors.
- [ ] Preserve numeric domains without JavaScript rounding or narrowing.
- [ ] Test negotiation order, malformed offers, digest mismatches, old clients, authority checks and replay.
- [ ] Verify private thinking, credentials and host-only data never enter public projections.
- [ ] Run the required independent-client workflows.

### Added implementation subtasks

- [x] Pin the complete revision-3 snapshot and both producers' closed pending-question projection in shared Elixir and independent Node codecs with fully embedded nested schema definitions, literal identities, every-member/privacy refusals, exact quantities, full identity/text byte boundaries and cross-view owner/cursor/configuration relations. Prove the complete protocol suite including Node on both pairs. Current-only genesis, actual publication, both coordinated manifests/servers and live clients remain separate open joins.

- [x] Reduce immutable genesis configuration, committed configuration changes and checkpoint provenance at the exact public cursor with bounded current/anchor state; validate closed projections, settled version advancement, actual maintenance capture, prior checkpoint and inherited omissions, and compare replay against private configuration/checkpoint identity. Preserve model-question producer/kind in pending and historical attachments through every existing choice/text/decline vector on both toolchains. Expanded public snapshot and coordinated wire/Node joins remain open.

- [x] Pin the complete closed configuration/change and checkpoint projections in shared Elixir codecs, literal schemas/vectors and independent Node decoders; preserve exact domains, all original-source variants, actual owners and full identity/text byte limits. Join native serial-owner validation and prove configuration, checkpoint, replay and Store uncertainty on both supported pairs. Coordinated wire emission, snapshot reduction and live negotiated workflows remain open.

- [x] Share the closed episode/command/result compact completion through the serial writer, both transport event projections and independent Node decoders; pin the complete nested schema and literal variants, and reduce one last completion at every paged cursor with exact identity/usage and private-field/overlap refusal on both supported pairs. Publishing last_compact in the coordinated public snapshot and live negotiated workflow proof remain open.

- [x] Derive durable changed maintenance views in the shared serial reducer for proposal/recovery, with journal-position event identities, closed capture projection and no unchanged-stage/succession duplicates; join both transport projections and independent connection validators, prove privacy/tamper rejection and once-only admission/terminal views through all three Store fault phases on both supported pairs. Snapshot, manifest/negotiation and live independent workflow joins remain open.

- [x] Pin the approved closed maintenance-view payload in a shared Elixir codec, independent Node decoder and literal schema/vectors; verify both owner bound domains, unbounded exact run/configuration quantities, null inactivity, closed/privacy refusals and complete opaque/UTF-8 byte boundaries on both supported toolchains. Live emission, snapshot reduction, negotiated generation-3/4 workflows and Store uncertainty proofs remain separate open work.

- [ ] Implement the approved closed `context.maintenance_changed` event and active-maintenance snapshot view; authenticate both actual owners and retained admission bounds, emit only changed safe projections in serial-owner transactions, reduce snapshots at the same public cursor, and prove closed numeric/opaque domains, privacy canaries, paged/mid-transaction anchors, duplicate/succession and all three Store uncertainty phases with both independent Node workflows.

- [x] Implement the approved closed checkpoint-owner schema, shared Elixir codec and independent Node decoder/vectors; project both actual owner kinds through foreground and daemon events using opaque identity bytes and refuse superseded aliases. Prove 36 literal cases and complete identity boundaries on both toolchains; complete generation-3/4 manifests, snapshots and live negotiated workflows remain open.

- [x] Pin the accepted standalone compact-result schema and literal vectors, and implement an independent Node consumer; prove every closed failure branch, arbitrary exact usage, threshold/accounting relations, opaque checkpoint boundaries and unchanged legacy schema identities on both supported toolchains. Coordinated generation-3/4 contracts and live maintenance remain open.

## T06 — Build the first complete chat workflow

### Original checklist

- [x] Add loopex chat through the existing session/runtime facade.
- [ ] Join explicit configuration, continuity and instructions.
- [ ] Support prompts, status, wait, abort, bounded output and truthful shutdown.
- [ ] Prove two prompts and restart through the built command.
- [ ] Preserve existing ask, durable-run and embedded workflows.
- [ ] Test startup refusal, admission failure, output and cleanup.
- [ ] Later retain the required attended multi-prompt proof.

### Added implementation subtasks

- [x] Join the public chat entrypoint to exact creation, session tracking, prepared resume, guarded signals, effective report and existing input/output driver; share ask diagnostic joins and prove actual built startup/quit plus scripted continuity/restart/refusal/cleanup behavior on both pairs. Built multi-prompt/provider, attended, maintenance and helper proof remains open.


- [x] Join prepared resume to exact retained policy identity/revision and all admitted model routes; abandon refusals without credentials/catalog lookup and prove matching/conflicting pending/answered questions, zero dispatch and untouched facts on both toolchains.

- [x] Expose the approved exact-create/provenance public facade reads; retire older-generation positive-read scaffolding and prove unchanged Store bytes and zero activation through current-genesis Memory/Local recovery on both supported pairs.

- [x] Resolve and implement the public prepared startup facts and exact-create/provenance facade decision; prove holder fences, retained pending policy/model/workspace identity, exact-byte refusal and zero pre-activation dispatch.
- [x] Implement the approved new-chat physical workspace binding; require it for current-format chat resume and prove retained identity conflicts, symlink retargeting and physical replacement before activation. The superseded legacy-unbound exception and older-root migration are retired.

- [x] Join the private chat driver to a live Core session; prove two-prompt continuity, acknowledgement ordering, wait backpressure, exact question answers, pipe/interactive refusal, captured invocation bounds and queued-run inheritance, lost acknowledgement observation, blocked input/admission cancellation, actor loss, unknown-cleanup retention and closing after outer cleanup on both supported toolchains. Public command startup, status/maintenance joins, tracing, installed signals and resume remain pending.
- [x] Resolve the prepared-recovery configuration-read boundary, then expose its exact retained host capture under capability ownership and prove refusal/fencing without activation or dispatch.

- [x] Expose the accepted committed configuration allowlist and current active-run bounds through existing local session status; prove initial/configured/restarted values, unresolved legacy and settled nulls, private-data exclusion, arbitrary turn/token counts, the exact staged absolute cutoff and the unchanged historical wire allowlist on both supported toolchains. Authored absolute ceilings, new generation snapshots and live chat integration remain pending.
- [x] Prepare exact new-chat configuration, instructions and immutable tools before credentials; wire opt-in question definitions through durable constructors and prove prepared genesis creation/restart on both toolchains.
- [x] Expose maintainer-selected exact prepared genesis through the public creation facade; preserve legacy omission, conflict identity, malformed-input refusal and shared v2/v3 validation, and prove real durable chat creation/restart on both supported toolchains.
- [x] Separate resume file preflight from capability-held ordinary-session configuration preparation; preserve exact retained settings and committed origins, compare explicit flags, abandon on returned refusal, retain cleanup uncertainty and prove restart/latest configure/route/instruction/credential behavior on both pairs. Public startup, workspace/pending-policy checks, legacy migration and helper bindings remain pending.

## T07 — Implement automatic and explicit compaction

### Original checklist

- [x] Select complete eligible conversation groups.
- [x] Protect open exchanges and their complete native prefixes from compaction or re-rendering.
- [x] Have the owner select and encode bounded source excerpts; have the model produce the summary.
- [x] Capture maintenance model, route, instructions, deadlines, origin and targets before dispatch.
- [x] Distinguish missing summarizer configuration from invalid configuration.
- [x] Require complete natural termination, valid output, size limits and progress before committing a checkpoint.
- [x] Implement bounded attempts, refusal records, terminal ordering and standalone compact results.
- [x] Resolve uncertain checkpoint commits before publication and charge usage once.
- [x] Test oversized oldest/newest groups, small problematic groups, trailing inputs, omitted content, length stops and non-progress.
- [x] Inject crashes around preparation, staging, settlement, checkpoint and publication.
- [ ] Prove automatic compaction, explicit compaction and restart preserve the required facts.

<a id="t07-original-item-evidence"></a>
### Original item evidence — 2026-10-04

The original item numbers below preserve their order above. This audit proves
implementation and focused component behavior at `1259d0df`; it does not claim
the still-open real-provider, live protocol, persistent-fault or closure lanes.

| Original item | Evidence or remaining proof |
| --- | --- |
| 1, complete eligible groups | [Original-record grouping](../../apps/loopex/test/compaction_record_sources_test.exs), [whole-session selection](../../apps/loopex/test/standalone_compact_projection_test.exs) and the live owner cases retain indivisible tool groups and terminal inputs. |
| 2, open/native protection | The same grouping/projection cases and [live recovery](../../apps/loopex/test/maintenance_episode_recovery_test.exs) retain whole open exchanges and exact native-prefix sources. |
| 3, bounded owner source and model summary | [Source selection](../../apps/loopex/test/compaction_source_test.exs) independently pins encoded bytes, excerpts, disjoint UTF-8 ends and quota order. [Live automatic recovery](../../apps/loopex/test/maintenance_episode_recovery_test.exs) and [standalone owner](../../apps/loopex/test/standalone_compact_owner_test.exs) dispatch the selected source through the actual Model port and commit its admitted summary. |
| 4, frozen dispatch capture | [Episode admission](../../apps/loopex/test/maintenance_episode_admission_test.exs) authenticates every captured field and targets. Live owner/recovery cases retain model, configuration, request, prior checkpoint and absolute cutoff through changed defaults, held workers and succession. |
| 5, absent versus invalid selection | [Maintenance configuration](../../apps/loopex/test/maintenance_configuration_test.exs) rejects malformed supplied settings before startup. Automatic and standalone live cases report absent/unsupported summarizers before attempts without inheriting ordinary defaults. |
| 6, complete natural bounded progress | [Summary admission](../../apps/loopex/test/compaction_summary_test.exs) rejects limit/unknown termination, extra fields, duplicate keys, tools, continuation and encoded cap overflow. [Whole-record checkpoint staging](../../apps/loopex/test/maintenance_request_staging_test.exs) and standalone projection prove strict progress or captured rendering repair before checkpoint commitment. |
| 7, attempts/refusal/terminal/result | [Provider attempts](../../apps/loopex/test/maintenance_provider_attempt_test.exs), request staging and both live owners prove bounded physical retry, exhausted/partial endings, leading episode-terminal ordering and exact five-member standalone result without a synthetic run. |
| 8, unknown checkpoint and once-only usage | Live automatic pending/committed checkpoint cases cover before-linearization, after-linearization-before-result and recovery-representation uncertainty. Standalone owner cases hold actual checkpoint/completion transactions, join the provider callback, kill/recover the owner and prove one checkpoint, settlement, event and charge without redispatch. These use the fault-injecting Store fixture, not a disk-fault claim. |
| 9, required problematic content | Source and request staging cases cover oldest whole-unit excerpts, oversized protected tails, small prefixes followed by oversized units, queued/trailing input, inherited omission, non-progress and length-stop refusal. Standalone projection/owner cases cover the same bounded-source and result paths. |
| 10, complete crash campaign | Live Core process/fault-injecting Store phases and real cutoff joins pass. [Physical Local Store crash cases](../../apps/loopex_composition/test/maintenance_store_restart_test.exs) kill the actual Store for both ownership modes at preparation, staging, settlement, checkpoint and publication across all three declared uncertainty phases, reopen the log and recover through the public facade. Precise preceding/committed record checks prove each cut. Raw records/outbox, once-only usage/checkpoints, conservative ambiguous failure, safe continuation, stale-writer recovery and process joins pass on both pairs. The campaign also exposed and repaired false run-owned cleanup confirmation after inherited open attempts; strict replay rejects forged confirmation. |
| 11, open complete preservation proof | Live automatic/standalone owner succession retains raw facts, checkpoints, usage, deadlines and result identity. [Physical Local Store restart](../../apps/loopex_composition/test/maintenance_store_restart_test.exs) now proves exact log/raw prefixes, checkpoint/configuration/usage/deadline replay, standalone result identity and continued summary projection with no redispatch. Complete current live-surface preservation still needs its integrated proof; real-provider long conversation remains an M7 closure obligation. |

### Added implementation subtasks

- [x] Complete the real Local Store maintenance crash matrix for automatic and standalone ownership at preparation, staging, settlement, checkpoint and publication across before-linearization, after-linearization-before-result and exact recovery re-presentation; prove precise durable cuts, atomic outbox, raw prefixes, conservative ambiguous spending/no redispatch, safe summary continuation, stale-writer recovery, exact results and process joins on both toolchains.

- [x] Repair run-owned maintenance cleanup confirmation for inherited unsettled provider attempts using their authenticated owner epoch and retained termination evidence, without changing result keys, persistence fields, parent outcome or usage; pin owner-loss/abort/deadline uncertainty, retain confirmed completed-reply/source cleanup and reject forged claims under strict replay on both toolchains.

- [x] Prove automatic and standalone compaction through a real Local Store close/reopen and public resume, retaining exact raw records/events/log bytes, checkpoint/configuration/deadline/usage state, standalone command replay and the next ordinary summary projection without redispatch or duplicate charges; join all runtime, Store and fixture actors on both supported toolchain pairs. The physical crash campaign closes separately above; current-surface preservation remains open.

- [x] Implement the approved maintenance_reply_reserve_unavailable v2 preparation refusal when positive remaining run tokens cannot fit the fixed summary reserve; preserve actual budget/turn exhaustion precedence, actual usage, zero summary dispatch and atomic episode/refusal/run ending, and prove exact replay, forged-cause refusal, boundary vectors and live recovery on both supported pairs.

- [x] Join standalone captured source preparation and guarded provider dispatch to the existing actual-command owner path; prove zero-attempt measured/named refusals, reported/conservative spending, exact not-dispatched retry, source/provider joins, prepared-expiry pause and all three request/failed-settlement uncertainty phases on both toolchains, without a synthetic run or new checkpoint schema. Successful checkpoint continuation/results, snapshots and full standalone workflow remain open.

- [x] Measure standalone pending checkpoint substitution through exact command-owned whole-record probes, authenticate original coverage and source omission, require strict size progress or hard-fitting rendering progress, and replay non-progress completion without a second settlement or charge; prove abort/deadline/clock/range refusal and every cancellable traversal stop on both toolchains. Checkpoint emission and live integration remain open.

- [x] Charge standalone settlements against captured episode allowances, retain exact reported/conservative usage and bounded not-dispatched retry, and complete failed attempts with the leading episode terminal plus settlement/completion pair; prove summary refusal, unreadable replies, owner-loss cleanup, cancellation/deadline precedence, post-settlement endings, duplicate results, strict replay and bounded private coverage on both toolchains. Live dispatch, checkpoints, snapshots and complete cleanup remain open.

- [x] Reuse captured whole-session source selection, exact source/receipt sizing and the adjacent maintenance request/open pair for standalone commands; retain the immutable cutoff and actual command identity, add no run accounting/deadline, and prove excerpt selection, strict replay, cancellation and bounded private coverage on both toolchains. Live dispatch, settlement and checkpoint completion remain open.


- [x] Join standalone initial capture and unchanged/zero-attempt failure completion to the live owner; capture one cutoff, join exact pure workers before adoption, preserve prepared-resume pause, commit admitted-episode terminal/completion together, and prove abort, worker loss, deadline, bounded reader, duplicate results and all three capture/completion uncertainty phases on both toolchains. Provider dispatch, spent/checkpoint results, snapshots and complete cleanup remain open.

- [x] Join standalone captured source selection, request/permit staging, provider dispatch, settlement/spending, checkpoint continuation and final completion to one live workflow using the actual compact identity; prove restart, unknown commits, immutable captures and bounded cleanup without a synthetic run.
- [x] Finish standalone pre-dispatch bound completion for initial source, retries and further prefixes after a useful checkpoint; derive captured attempt/token capacity, preserve actual usage and partial checkpoint, prevent another dispatch, and prove truthful terminal/replay and cleanup at the remaining reserve boundaries.

- [x] Retain unchanged standalone completion and its exact event in one replay-checked proposal without an episode, return the completed five-member result on duplicate lookup while preserving admission observation, release the pending slot, validate bounded private coverage, and prove strict result/history/event/cancellation refusal on both toolchains. Live owner scheduling, Store uncertainty, snapshots and failed/cancelled completion remain open.

- [x] Implement standalone episode admission/replay capture with command-owned bounds and absolute deadline, unchanged empty-history planning, retained settings before new host/clock lookup, original rendering-offender identity and exact journal-version capture; prove malformed/rehashed capture refusal, succession, cancellation and bounded private-history coverage on both toolchains. Live owner admission, dispatch and completion remain open.

- [x] Measure standalone canonical context with the exact shared Store fixed point and hard-limit precedence, select explicit terminal-unit release with retained checkpoints, and pin the last original rendering offender; prove current/floor numeric, structural, cancellation, provenance and empty-history cases. Durable capture and live execution remain open.

- [x] Admit and replay the standalone compact command without a clock, prompt or run; retain closed explicit bounds and exact episode identity, duplicate-first mutation fences and abort binding, traverse bounded private history, and prove all three live Store uncertainty phases plus paused owner succession on both toolchains. Standalone episode capture, execution, completion, snapshot and cleanup integration remain open.

- [x] Read and select whole-session canonical history without an invented run; reuse checkpoint substitution and the shared request/receipt builder with current committed settings, reject unfinished work, steer and fresh optional intake, and prove original-record provenance, indivisible tool groups, terminal inputs, native-prefix equality and configuration restart on both toolchains. Whole-record measurement, episode capture and live standalone execution remain open.

- [x] Enforce captured thinking headroom throughout new ordinary staging, excerpt/optional allocation, tail selection and checkpoint completion; retain exact episode targets and v2 refusals, reject forged current replay, keep open exchanges under hard ceilings with immutable prefixes, and prove live target-aware preparation, initial no-dispatch refusal, optional withholding and open-exchange reserve spending on both toolchains. Rendering-trigger capture, standalone compaction and real-provider evidence remain open.

- [x] Hold initial and later maintenance source workers through their captured live production cutoffs without clock or timer replacement; join the exact worker, retain the preparation-failure versus committed run-deadline distinction, preserve checkpoints/raw facts/usage and prove one ending with no dispatch on both toolchains. Keep these cases in the existing long-bound release lane.

- [x] Hold the exact initial and later maintenance source worker across durable owner succession; join the worker and predecessor, prove the paused successor commits only its claim while preserving the frozen episode, checkpoint and usage, then complete one new summary/checkpoint/ordinary continuation through the public activation path on both toolchains. Live cutoff and standalone compact remain open.

- [x] Join lost maintenance source workers before committing the existing unavailable episode/refusal/parent ending; validate the eligible phase and retained clock on replay, prove initial and later source preparation across all three Store uncertainty phases plus held-worker cancellation on both toolchains, and preserve checkpoints, usage and raw facts without redispatch. Live cutoff, supersession and standalone compact remain open.

- [x] Commit and replay the exact maintenance-scope numeric v2 refusal when frozen summarizer instructions reach the captured system ceiling before source traversal; prove one system descriptor and live automatic no-dispatch recovery on both supported toolchains.

- [x] Retain an exact numeric v2 refusal for an irreducible protected ordinary tail at initial or later source preparation, including prior checkpoint, frozen inputs, derived first deadline and live owner replay on both supported toolchains; preserve source-worker fault and other preparation endings as open work.

- [x] Commit an irreducible bounded-source excerpt as the accepted named episode/refusal/parent ending before provider intent; rederive the frozen source and retained clock on replay, and prove a live automatic no-dispatch ending on both supported toolchains. Worker-fault joins remain open.

- [x] Admit a live automatic ordinary-limit episode from the measured v2 token/record-byte refusal only when a complete older unit can be released; capture the host summarizer and cutoff before source work, finish a real summary/checkpoint/ordinary continuation, and prove missing-summarizer and irreducible-current-prompt endings without provider or executor work on both supported pairs. Thinking/headroom, post-admission refusal faults and standalone compact remain open.

- [x] Join captured ordinary-tail source selection to a supervised pure-proposal worker and exact request/open commitment after its DOWN; dispatch newly adopted maintenance requests through their retained closed Control binding and existing provider cleanup, keeping raw summary deltas private. Prove first preparation and further-prefix continuation across all three staging uncertainty phases with prepared pause, exact fenced-owner succession, captured configuration/deadline/prior checkpoint, guarded callback replacement, once-only usage and no executor jobs on both toolchains. Automatic triggers, irreducible refusals, source-worker fault joins and real-provider evidence remain open.

- [x] Add and independently replay the run-owned four-physical-attempt exhaustion proposal, preserving useful partial checkpoints, original facts and once-only spending while retaining the last minimum ordinary numeric refusal and exact episode/refusal/parent ordering. Prove abort/deadline precedence and reject changed measurements, clocks and stripped episode identity on both toolchains. Prove all three live Store uncertainty phases with prepared pause, exact fenced-owner succession, one adjacent ending, unchanged partial checkpoints/raw facts, no redispatch or recharge and exact coordinator/control joins on both pairs. New summary dispatch and real persistent Store/provider fault witnesses remain open.

- [x] Extend run-owned ordinary-limit requests and checkpoints across contiguous new raw prefixes with the exact prior checkpoint, cumulative original-record digest, separate consumed range, inherited omission, fixed capture/deadline, ordinal/operation separation, usage-once accounting and physical four-attempt limit; prove fitted-cycle refusal, later non-progress retaining the prior checkpoint, tamper rejection and bounded private traversal on both toolchains. Live dispatch and exhausted-episode endings remain open.

- [x] Retain and independently replay a measured non-progress episode/refusal/parent ending, authenticate the last minimum ordinary projection and exact terminal ordering, preserve settled usage and raw facts, prove abort/deadline/capacity precedence and all three live uncertainty phases without redispatch, and traverse bounded private history on both supported toolchains.

- [x] Commit and replay a useful first ordinary-limit checkpoint with its event, exact original coverage, settled summary provenance and unchanged raw facts; substitute only covered source identities, retain the unsummarized tail, release fitted completion without a parent terminal or duplicate charge, reject partial success and forged fields, and traverse checkpoint/completion in bounded private history on both supported toolchains. Later prefixes and standalone compact remain open. Extend the live owner to finish pending/committed first checkpoints through all three uncertainty phases, retain once-only usage before one captured ordinary dispatch, and preserve checkpoint identity across abort/deadline while refusing spent parent bounds. Exact owner joins and bounded private coverage pass both supported pairs.

- [x] Select a contiguous retained tail from validated complete units, releasing terminal units oldest-first, preserving protected and frozen units, releasing all eligible units for explicit origin, and growing only unreleased tails within the 2,048-token preference and whole-request fit callback. Prove irreducible refusal, rendering refusal, exact preference, mandatory oversized tail, interruption and fixed-input measurement for empty history on both toolchains. The owner now shares exact configured request/receipt construction with the q=0 ordinary-limit probe. Thinking targets, captured rendering offender, prior-checkpoint substitution and live automatic triggering remain open.

- [x] Join maintenance settlement to durable episode accounting and strict replay, retaining natural bounded summaries pending checkpoints, atomically ending invalid/incomplete or lost attempts, enforcing one exact not-dispatched retry and captured parent capacity, preserving the first abort/deadline and late usage evidence, and proving depth compaction, duplicate/interrupted endings and successor recovery on both supported toolchains. Join the live owner recovery path for lost attempts and retained summary failures, with all three commit-uncertainty phases, exact joins, no redispatch and unchanged conversation. New summary dispatch/cleanup, checkpoint transactions and later prefixes remain open.

- [x] Join owner-selected maintenance sources to exact whole-record receipt preflight and consecutive request/attempt-open replay, binding captured original-record provenance, strict system and input limits, resource headers, clocks and protected units. Verify streaming projection, rejection of partial/substituted history and complete-original integrity on both toolchains. Tail policy, automatic triggering, live dispatch, settlement, checkpoints and standalone compact remain open.

- [x] Add distinct closed maintenance v3 settlement and deadline vocabulary, preserving shared transport/accounting/retry rules, preventing ordinary tool continuation, binding retained reply digests, and joining exact permit retirement plus bounded effect-history validation; prove all boundaries on both toolchains. Live episode spending, summary/checkpoint admission and recovery remain open.

- [x] Retain replay-derived complete original-record digests/costs/positions for existing conversation sources, preserving queued input admission, deferred settlement pairs, executor receipt evidence, terminal-derived results and question response provenance; prove live/replay equality and private-original changes invisible to canonical messages on both supported toolchains. Ordered range digest and live maintenance staging remain open.

- [x] Extend the existing provider-attempt open vocabulary, closed permit bindings, exact-position one-use Control send and effect-history coverage for distinct maintenance episode/summary identities; prove fabricated/mixed/changed identities, stale positions, deadlines, repeat sends and process joins on both toolchains. Episode/request reducer, four-attempt accounting and actual maintenance dispatch remain open.

- [x] Commit run-owned episode terminal prefixes atomically with existing endings; validate the closed result, parent-bound observations, retained preparation clock, adjacency and complete replay; join live expired preparation and undispatched-abort recovery, including exact uncertainty/owner-exit/successor proof on both toolchains. Live triggering, summary attempt accounting, checkpoint faults and standalone endings remain open.

- [x] Implement durable automatic ordinary-limit episode admission and replay with frozen maintenance configuration, parent/staging identity, spending bounds, zero counters, fixed preparation cutoff, ordinary-staging and run-terminal fences; prove owner succession, missing/unsupported settings, overflow, overlap refusal and rehashed tampering on both toolchains. Live owner triggering, dispatch, terminal and checkpoint integration remain open.

- [x] Validate explicit Core maintenance model/instruction startup settings and privately forward exact captured instruction bytes to session owners.
- [x] Validate and forward explicit maintenance instructions through all durable constructors and ephemeral startup before owned effects, preserving per-call refusal.
- [x] Resolve the separately configured host summarizer and prove its fixed-budget thinking-off native request and natural completion through both transports.
- [x] Build replay-derived indivisible compaction units with same-run inputs, terminal trailing inputs, current/unfinished protection and frozen native-prefix source protection; prove idle release and exact grouping after real journal recovery.
- [x] Stream exact source-v2 complete/excerpt encodings with bounded candidate/end buffers, full-list digest/count, fixed UTF-8-safe quota order, prior checkpoint reuse and traversal cancellation/deadline checks; pin independent byte, cap and numeric vectors.
- [x] Admit whole maintenance callbacks, retain canonical usage on incomplete/invalid summaries, require natural completion first, and share closed summary/carry-forward validation with prior checkpoint reuse; prove escaping, size, shape and callback-generation boundaries.
- [x] Select bounded complete source prefixes through owner-supplied whole-request preflight, enforce the revision-3 small-prefix/next-unit rule without fallback, and prove whole-unit coverage, exact threshold, quota order and cancellation before later reads.
- [x] Capture owner-computed checkpoint summary provenance with inherited omission, share strict prior-data admission and pin exact canonical user rendering/source identity plus all nine native mappings in both transport modes on both toolchains. Prove exact first-checkpoint pending substitution and strict byte/token progress through shared ordinary staging, captured steer, owner succession, partial hard-limit progress, cancellation and deadline precedence; successful commitment and prior-checkpoint continuation remain open.
- [x] Construct the accepted canonical thinking-off maintenance request from exact captured instructions and prepared source, with no tools/continuation and a fixed 1,024-token reserve; prove distinct configuration refusals, identity integrity and actual registered local-HTTP request bytes on both toolchains.

## T08 — Implement model selection and private thinking continuation

### Original checklist

- [x] Implement committed per-run model/reasoning configuration and the permitted configure fields.
- [x] Implement the exact adapter replies, canonical replies and monotonic settlement generations.
- [x] Implement bounded in-capsule reference expansion, with no artifact substitution or external lookup.
- [x] Preserve expanded native blocks, strings, ordering, IDs and parsed arguments.
- [ ] Implement continuation accounting, reserves and compaction headroom targets.
- [ ] Implement all nine accepted thinking cells and the separately configured summarizer.
- [x] Build the native transport bridge: validate final requests after hooks, capture before conversion, and preserve admitted controls and ceilings.
- [x] Bound raw streaming/parser buffers; implement fatal-error latching, flushing and wakeup.
- [x] Test the bridge against a local HTTP server before integrating live-provider proofs.
- [ ] Test model switching, crashes, cancellation, malformed replies, overflow, usage accounting and privacy.
- [ ] Complete the seven thinking-round subcases, nine bound subcases and cancellation witness, including their prescribed subsequent prompts.

### Added implementation subtasks

- [x] Prepare closed whole-candidate mutable updates with bounded inputs, monotonic versions and retained explicit/derived budget origins.
- [x] Prepare atomic configuration admission/replay with exact command identity, single-copy instructions, retained earlier run captures and public event allowlists.
- [x] Gate prepared configuration admission/replay on captured terminal-tool-history capability, preserving empty-completion and cross-run semantics.
- [x] Gate ordinary configured provider intent on terminal-history capability and retain the unavailable v2 preparation-failure pair without fabricated observations.
- [x] Join prepared ordinary candidates to settled owner admission, exact retained-history preflight, atomic commit and replay.
- [x] Prove configuration restart, commit-unknown re-presentation and owner crashes before/after linearization through the live runtime.
- [x] Join host configure resolution to the ordered chat driver through the public prepared facade; retain only confirmed candidates and prove busy/history refusal, exact unknown observation, canonical aliases and changed live model allowances on both toolchains.
- [ ] Join host resolution and prepared daemon routing; extend configuration preflight to committed checkpoints and maintenance quiescence.
- [x] Capture bounded limits and source bindings from the exact pinned packaged catalog without mutable lookup; preserve unknown limits and the literal accepted alias.
- [x] Register all nine literal reasoning cells after deterministic native request/response, bound, disclosure and terminal-history conformance; share exact mappings with transport validation.
- [x] Join registered reasoning subsets and exact mapping resolution to whole-profile preparation.
- [x] Prepare exact v2/v3 callback projection, source-bound v3 settlement readers and monotonic historical-prefix recovery before writer migration.
- [x] Emit v3 for every new ordinary settlement, migrate exact callback fixtures, and prove whole-record accounting, required-capsule admission and historical schemas through live recovery.
- [x] Implement pure exact native-array capture and reconstruction through the shared expander, with closed fields and stop/call relations.
- [x] Build and validate bounded aggregate request envelopes from full committed settlements and lineage positions, including source/configuration replay checks.
- [x] Charge the complete expanded ordinary envelope in revision-four receipts and independently verify every retained cost field.
- [x] Preserve frozen project input through owner recovery, reject native-ID collisions before tools, and retain replayable aggregate-overflow preparation failures.
- [x] Resolve and implement the numeric refusal schema for frozen project/resource input; prove its exact bounds and replay.
- [x] Prove frozen resource-pack input and steer ordering across continuation/restart boundaries, with exact required-result ordering, retained receipt equality, single steer consumption and no redispatch after actual owner loss.
- [x] Implement bounded native event assembly and pinned SSE parse/flush validation with permanent failure, exact content reconstruction and cumulative usage evidence.
- [x] Render captured native requests and seal the final Finch request; prove exact tools, controls and ceilings against the pinned builder and hook order.
- [x] Join native capture and request sealing to the durable worker, with strict reply fields and an owned, monitored drain.
- [x] Prove local HTTP framing, private/public projection, blocked-drain failure, owner death and telemetry exclusion.
- [x] Share full-generation canonical call rendering and refuse malformed argument repair across ordinary and native request paths.
- [x] Join buffered native capture/rendering to OneShotHTTP1 with invocation-correlated private state, complete native identity/usage checks and selected-key screening.
- [x] Keep native request bytes out of Finch metadata through bounded one-use body streams without changing wire framing or response delivery.

## T09 — Implement model-originated questions

### Original checklist

- [x] Register the exact question-tool generation without changing old effect definitions.
- [x] Admit questions through policy; no executor grant or job is created.
- [x] Implement producer identity, options, text answers, decline and expiry.
- [x] Atomically settle the interaction, original tool result, response identity and next action.
- [x] Preserve the existing policy-defer lifecycle.
- [x] Test denial, deferred policy, large answers, overflow, duplicate/stale responses, cancellation and expiry.
- [x] Test crashes before and after pending-question and response commits.
- [x] Prove recovery retains the actual pending question identity.

### Added implementation subtasks

- [x] Pin exact runtime public model-question event fields, including conditional choice identity and expiry, in an explicitly unserved standalone payload schema on both supported toolchains.

- [x] Remove pre-1.0 model-question response/settlement v1 replay and effect-index readers, reject those exact retired kinds, and retain current v2 answer/expiry/cancellation recovery on both supported toolchains.

- [x] Fence recovered answered-policy reevaluation with the existing prepared-run pause; prove matching and changed policy facts stay unchanged with no in-flight worker before activation, then positively observe reevaluation and its exact worker join after activation on both toolchains.

- [x] Pin its format-v2 canonical preimage/digest and enforce exact schema/byte/choice limits before policy.
- [x] Separate interaction tools from executor dispatch and reject nested policy defer.
- [x] Replace the interim policy-allow refusal with committed model-question pending and producer-specific terminal transitions.
- [x] Prove pure recovery retains the actual committed pending question identity.
- [x] Prove live owner restart retains that identity and settles it once.
- [x] Prove commit-unknown re-presentation retains exact pending and response bytes.
- [x] Prove local-store process restart retains the pending question and final answer.
- [x] Pin independent pending/response identity and digest preimages and reject all missing, extra, substituted and consistently rehashed malformed records through real-owner replay on both supported pairs.
- [ ] Pin pending/response decoder vectors and public question event schemas.
- [x] Pin the shared closed answer schema/union and independent Elixir/Node payload vectors.
- [ ] Join that answer schema and decoder to the complete M7 /3-/4 contracts and both authorized mutation paths.

## T10 — Complete chat controls, pipes and tracing

### Original checklist

- [ ] Implement steer, follow-up, answers, decline, wait, interrupt, configure, compact and exit commands.
- [ ] Implement the exact pipe grammar and closed control records.
- [ ] Enforce record limits, bounded input admission, the 256-KiB output queue and control-drain deadline.
- [x] Implement the unknown-admission resolver using the original transaction identity and proposal.
- [ ] Preserve input ordering while admission is uncertain; do not submit duplicate commands or fenced aborts.
- [ ] Make EOF, incomplete fragments, earlier failures and uncertain cleanup produce the specified outcomes.
- [ ] Implement tracing through flags and files, including enable/disable and owner cleanup.
- [ ] Add the independently draining diagnostic consumer with drop and unconfirmed-delivery accounting.
- [ ] Test PTYs, fragmented pipes, actual question IDs, barriers, slow readers, EOF and signals.
- [ ] Test tracing isolation, redaction, stalled stderr and ask’s JSON output separation.

### Added implementation subtasks

- [x] Resolve and implement the owner-only effective-settings report admission decision; preserve shared diagnostic queue/writer/cleanup bounds and prove redaction, exact values/origins, byte refusal and loss accounting.

- [x] Join ordered status to public session/trace reads and the confirmed host capture; implement closed nested status and standalone compact-result codecs with exact quantities, private-data refusal, byte limits, stale-cache refusal and blocked-read cancellation proof on both toolchains. Public host entry, live maintenance observations and coordinated independent consumer/schema proof remain open.

- [x] Join prepared chat installation to the existing acknowledged holder and manager guard; prove holder-only activation/abandonment, driver-owned abort fencing, exact duplicate preservation and fail-closed transport loss on both toolchains. Public host startup checks and composition remain pending.

- [x] Route installed process signals through the existing chat driver without competing aborts; retain exact installer/manager/reference ownership, late-install retirement, host/driver loss and truthful late-interrupt closing exits, proving actual OS signals in separate VMs and legacy prepared recovery on both toolchains. Public host composition and prepared activation handoff remain pending.

- [x] Stage driver attachment/status readiness without input or event reads; reuse exact holders for run, validate captured cleanup grace before startup, preserve one cutoff through early/blocked/second interruption and actor loss, and prove actual prepared recovery on both toolchains. Installed signal routing and outer host startup remain pending.

- [x] Resolve the concrete terminal-only chat outcome schema through the maintainer decision; retain the accepted run-only/null/uncertainty meanings and existing ask/event bytes, then implement the shared codec, closed terminal wait/closing constructors and independent vectors. Status and driver integration remain in the original checklist.


- [x] Implement bounded single-line framing and explicit chat-action parsing, with wait-line backpressure, exact JSON answers and malformed-input refusal on both toolchains; driver admission remains pending.
- [x] Implement the bounded independently draining output writer and escaped transcript lines; prove progress eviction, control deadlines and joined worker cleanup on both toolchains. Closed records and driver integration remain pending.
- [x] Expose attachment-based command observation with a closed result, replay-derived admitted/refused facts, stable structured-refusal codes and committed run identity; preserve opaque IDs and prove missing/recreated identities remain pending without owner Store callbacks.
- [x] Retain the original unknown proposal and exact OwnerLane transaction, return uncertainty immediately, and resolve only through owner-owned 100-ms worker ticks under one fixed first-unknown backstop; prove before/after persistence, exact bytes, non-commit and joined owner/deadline cleanup.
- [x] Defer internal worker results and owner timers in arrival order while admission is unresolved; prove model/executor evidence, real run deadline ordering, abort cleanup before deferred scheduling and actual backstop release into the existing mutation fence on both toolchains.
- [x] Encode closed input, question and error records with exact branch fields, producer-specific choices, opaque identities and the inclusive 65,536-byte cap; prove hostile content cannot forge a second record, legacy oversize refuses without truncation and output drains unchanged on both toolchains. Wait, status, closing and driver integration remain pending.
- [x] Implement the shared independently draining diagnostic consumer with a 256-entry pending queue, one supervised writer, separate trace/ordinary delivery/drop/unconfirmed counters and captured cleanup bounds; prove observed mailbox growth separately, redaction, stalled/broken IO and owner/drain/supervisor loss on both toolchains. Host startup and trace integration remain pending.
- [x] Share trusted-module selector resolution between CLI and composition, and validate the accepted closed host trace map into diagnostics-only runtime configuration; prove disabled-field validation, exact lowered ceilings, no atom creation or application startup, and unchanged CLI configuration behavior on both toolchains. Owning startup/teardown remains pending.
- [x] Join explicit trace flags to both ask profiles, activate durable tracing before session creation and forward ephemeral startup selection; prove disabled validation, startup refusal, diagnostic actor joins, lost cleanup proof, stalled stderr, real local HTTP JSON separation and a separate-VM trace-enabled OS signal on both toolchains. Chat/file/daemon integration remains pending.

## T11 — Implement specialized read-only helpers

### Original checklist

- [ ] Implement saved roles with exact instructions, models, credentials and finite allowances.
- [ ] Register the opt-in helper tool and immutable read-only tool selection.
- [x] Add the required read-only runtime/store provenance and effect-intent queries.
- [ ] Implement exact create-result lookup and retain genesis before child creation.
- [ ] Implement parent bindings, catalogs, allowance ledgers, stop records and receipt routing.
- [ ] Implement bounded private codecs, framing checks, writer fencing and reserved completion space.
- [ ] Enforce one unresolved helper per parent while allowing independent parents to progress.
- [ ] Charge attempted reservations conservatively; only the specified pre-effect refusals consume nothing.
- [ ] Implement bounded startup classification of all committed creates, including helpers-disabled startup.
- [ ] Guard existing attachments and settled child sessions against ordinary host mutations.
- [ ] Validate cache coverage, remove refused registrations and handle interrupted publication.
- [ ] Recover completed results and stop unfinished helpers; recovery must never create or re-prompt them.
- [ ] Test read-only authority, nesting refusal, budgets, concurrent parents, cancellation and exhausted-call reopening.
- [ ] Inject faults at every binding, reserve, create, prompt, stop, settlement, receipt and cache boundary.
- [ ] Prove both role demonstrations with unchanged child workspaces and separate/combined usage.

### Added implementation subtasks

- [x] Implement ADR 0046's bounded current-genesis private object codec shared by parent and child retention; prove exact plain ETF/base64/hash representation, owning schema validation, unsafe/compressed/trailing refusal, no input atom creation, encoded-size limits and actual current/floor cross-reading without re-encoding equality.

- [x] Implement accepted exact-genesis read-only create-result lookup; preserve the legacy query, refuse sentinel substitution before exact creation, and prove changed defaults, absent current registrations, distinct uncertainty and actual local log reopen through both shipped Stores on both supported pairs.
- [x] Implement accepted bounded creation-provenance point/page queries and optional Store callback with replay-derived per-runtime ordinals; prove complete captured cuts, later creates, exact/changed repetitions, unsupported history, damaged indexes, closed/duplicate-safe decoding, unavailable callbacks, no activation/writes and local log reopen on both supported pairs.
- [x] Decode bounded private effect-intent and terminal projections using existing reducer codecs; prove actual dispatched jobs and owner-created records, closed fields, canonical bytes/digests, scope, receipt-versus-core-refusal disposition, null-call unknowns, historical deadlines and malformed/oversized refusals on both supported pairs. The following subtask implements paging; startup classification remains open.

- [x] Implement accepted bounded stateless effect-intent pages and resume-token verification through Runtime Control; prove captured cuts, literal empty-history tokens, both real Stores and reopen, v3 question histories, distinct refusals, no writes/activation and joined reader cleanup on both supported toolchains.

- [x] Define the fixed opt-in helper generation and closed UTF-8 argument limits shared by inspection and later registration; prove immutable read-only declarations and unchanged ordinary tool registration on both supported toolchains. The helper is not registered or executable yet.

## T12 — Complete ephemeral support

### Original checklist

- [x] Forward accepted instruction, model, reasoning, provider-binding, maintenance, question and trace options.
- [x] Preserve reusable embedded sessions and buffered transport.
- [x] Keep questions opt-in and preserve old tool selections.
- [x] Implement tagged choice, text and decline answers.
- [x] Consume the question responder only in the one-call API; reject unsupported combinations.
- [x] Run one monitored responder worker outside the serial owner.
- [x] Join responder termination before another question or successful cleanup.
- [x] Test blocked, invalid, failed and late callbacks, cancellation, expiry and cleanup uncertainty.
- [ ] Preserve the existing credential and transport-cleanup guarantees.
- [ ] Complete the attended ephemeral-question witness.

Items 1 and 2 map to the audited startup, public model/question/trace and
buffered-wire cases recorded under [Current work](#current-work). Exact current
candidate integration and focused floor proofs are retained there; items 9 and
10 keep their separate credential-cleanup and attended obligations.

### Added implementation subtasks

- [x] Version tool-event identity records under the approved session/run/turn/call recipe; preserve exact historical IDs and unchanged public members, prove repeated raw IDs and question/effect continuation, and run the committed integration candidate's full check.

- [x] Integrate one-call-only callback consumption, owner-registered temporary workers, fixed call/expiry/join cutoffs and single-reader continuation; prove serial exact joins, stale identities, ordinary abort, caller death and cleanup uncertainty through actual Core/local HTTP on both supported pairs.


- [x] Implement the bounded model-question DTO and grant-gated temporary responder worker with exact answer validation, sanitized failures and supervisor-owned process joins; live one-call owner integration remains open.

- [x] Integrate the accepted optional trace map into ephemeral preflight, granted private-actor registration, post-capability-binding activation and bounded teardown; extend startup/loss fault proofs to the diagnostic drain, private writer supervisor and active IO worker, and preserve absent/disabled startup behavior.

- [x] Join explicit provider bindings to startup and committed-model dispatch, preserve caller-only credential resolution, and forward separately resolved maintenance models to Core.

- [x] Extend the existing ephemeral serial answer slot and pending projection for tagged model text/choice/decline, preserving legacy policy choices; prove maximum text, producer/kind refusal, unchanged pending observations, actual Core/HTTP continuation without executor intents and subsequent prompts on both toolchains. Public question opt-in and responder integration remain open.
- [x] Add Boolean public questions startup selection, refuse an empty enabled tool profile and per-call overrides, migrate actual text/choice/decline HTTP witnesses to the public facade and preserve absent-responder ordinary allow/defer decisions and cleanup on both supported toolchains.
- [x] Extend the Policy port with an optional contextual decide/2 callback, exact startup reference validation and private module-only telemetry; prove legacy behavior, fail-closed callbacks, actual owner dispatch and abort cleanup on both toolchains.
- [x] Implement the maintainer-selected contextual Policy amendment for one-shot absent-responder admission; prove denial before interaction admission without changing ordinary policy decisions.

## T13 — Complete coding fixtures and operator instructions

### Original checklist

- [x] Implement the repair fixture and its independent sum assertions.
- [x] Implement the feature fixture requiring the nil-encoding question.
- [x] Implement the review fixture with the exact duplicate-fee finding and call chain.
- [ ] Implement the long fixture preserving the required facts through compaction and restart.
- [ ] Implement the trusted fixture wrapper and exact approved test-command policy.
- [ ] Let the agent run approved tests; independently rerun immutable oracles and inspect allowed changes.
- [ ] Pin and execute the maintainer-selected external repository task.
- [ ] Make every V1–V13 instruction runnable, with one owner and evidence slot per step/subcase.
- [ ] Complete the specified human-attended steps with a named operator.
- [ ] Collect previous executions without adding extra model attempts.

### Added implementation subtasks

- [x] Pin the retained four coding fixtures in a closed source catalog with literal prompts, bounds, digests/modes, allowed changes, objective results and required model actions; protect complete workspace and immutable oracle inventories around actual deterministic oracle runs on both toolchains.
- [x] Freeze each fixture catalog entry to its exact changed/created path policy; reject well-formed edits that broaden or remove the retained task allowance, with failing-before and both-toolchain proofs.
- [x] Implement the private pinned fixture policy capture with exact argv, physical workspace and external file identity checks; deny alternate shell commands and mutable paths without broadening the ordinary registry.
- [x] Join that capture to ordinary chat startup and prepared resume, retain closed harness settings/status provenance, prove pending-question identity refusal and actual committed/independent repair-oracle execution with owner cleanup on both toolchains.
- [x] Prove both feature defaults through committed nil-mode questions and exact operator answers before effects, with real executor receipts, independent immutable oracle reruns, preserved explicit modes and owner cleanup on both toolchains.

## T14 — Implement attempts tracking and evidence validation

### Original checklist

- [ ] Implement the canonical, hash-chained attempts index and fsync-before-dispatch.
- [ ] Implement single-writer ownership and safe evidence handoff between machines.
- [ ] Implement all attempt states, verdict classes and legal transitions.
- [ ] Handle missing, corrupted or incomplete evidence as unavailable.
- [ ] Implement pre-dispatch-only continuation without redispatching completed work.
- [ ] Implement suspended-lane abandonment and committed index-head barriers.
- [ ] Enforce causal corrections and independent outage review; a new SHA alone permits no reroll.
- [ ] Add the M7 evidence validator to the existing two check commands.
- [ ] Implement M7 lane selectors while preserving all legacy cases.
- [ ] Test truncation, forks, duplicate writers, interrupted handoff, resume, abandonment, redaction and every verdict route.

### Added implementation subtasks

- [x] Implement the accepted private attempts-index canonical envelope and complete-chain framing; reuse sorted JSON and duplicate-aware decoding, pin an independent exact-byte/hash vector, refuse malformed/noncanonical/oversized/forked records and preserve unresolved truncated tails on both supported toolchains. Event admission, writer ownership, fsync and runner dispatch integration remain open.

## T15 — Prove migration and rollback

### Original checklist

- [-] Upgrade exact settled and unresolved M6 roots without changing staged requests.
- [x] Prove unknown effects are not redispatched.
- [-] Observe the actual historical reader against disposable new-format roots.
- [-] Preserve the existing v0.2.0↔v0.3.0 rollback proof.
- [-] Add the separate v0.3.0↔M7 proof.
- [ ] Implement access-prevention and complete backup-restore instructions.
- [ ] Restore into an empty root and compare complete manifests.
- [ ] Restore workspace state separately from runtime state.
- [-] Join automated rollback artifacts to attended restore inspection without rerunning the case.

Item 2 maps to `EndToEndRecoveryTest`'s actual effect/restart cases, exact receipt
reconciliation and removed-receipt outcome_unknown control. The current
candidate integration and floor proof, source hashes and output digests are
retained under [Current work](#current-work). Backup/restore obligations remain
open.

### Added implementation subtasks

- [x] Migrate current model adapters, fixtures, conformance callers and reply types to exact eleven-field v3 callbacks; remove the nine-field callback fallback and old two-argument canonical projection, preserving current ten-field replies, v3 settlement, raw-admission order, exact echoes, captured requirements and once-only accounting on both supported toolchains.

- [x] Remove the historical lineage-projection cutover cache and fallback; require the captured current artifact projection from the first request, preserve current null-projection sessions, and prove unchanged restart plus null/missing-first/missing-later/fully-removed provenance refusal and adjacent artifact/maintenance/accounting behavior on both supported toolchains.
- [x] Remove model-request v1 and receipt revision 2/3 readers, old per-run conversation query and lineage bypass; migrate current resource/source-binding fixtures and prove self-consistent retired-version refusal, exact unchanged bounds and current recovery on both toolchains.
- [x] Remove provider settlement v1/v2 readers, legacy accounting branches, cutover state and exclusive historical-reader interaction fixtures; prove current v3 verdict/accounting/source/terminal/restart and effect-query obligations on both toolchains.
- [x] Remove the obsolete M2 accounting probe and exclusive old-reader foundation scaffolding; retain both-pair proof of current embedding, CLI, artifact and recovery workflows.
- [x] Remove the historical cross-version archive lane, its exclusive helpers and fixtures; refuse its retired selector before staging and prove current build/redaction/manifest checks on both supported toolchains.
- [x] Retire shipped 1.0 read/search definitions, their capability/vector/dispatch support and default-selection shim; migrate current callers and fixtures, prove exact current identities, all tool subsets, retired-version refusal, inline/spill/range restart and unchanged path/budget/context/cleanup obligations on both supported pairs.
- [ ] Remove superseded record/API/protocol readers, tool generations, host fallbacks and compatibility-only fixtures; migrate current callers and retain one current contract at each boundary.
- [ ] Prove current-format backup/restore and recovery with complete manifests, separate workspace state and exact nonredispatch of unresolved effects.

## T16 — Complete integration and regression checks

### Original checklist

- [x] Move M7 to In progress when product work begins.
- [ ] Keep outcome rows linked to actual tests and evidence.
- [ ] Update operator/developer documentation, indexes, compatibility guidance, README, roadmap and changelog.
- [ ] Update verification guidance to the accepted M7 procedures.
- [ ] Run focused unit, property, conformance, fault, security, protocol and CLI tests during development.
- [ ] Run the fast check once per clean integration candidate.
- [ ] Run required selected real-provider, Node, daemon, long-bound and cross-UID lanes.
- [ ] Run changed process-boundary cases thirty times under the prescribed pinned Linux load.
- [ ] Independently review integration changes and fix confirmed defects without weakening checks.

### Added implementation subtasks

- [x] Repair the c45af182 binding-read regressions by targeting the actual provider-attempt-open row rather than a shared one-record page size; prove exact session/position observation, elapsed-deadline refusal, timeout reader DOWN, Control-loss cleanup and unchanged positive/supersession/effect cases on both supported pairs without changing any production bound.
- [x] Repair the c45af182 packaged-host failures with independent exact current host-instruction/environment and dated-alias response oracles; remove static undefined-host API calls from the separately compiled driver and prove every real escript/plain-OTP route, catalog control, application-startup and ambient dotenv negative on both pairs, retaining failed evidence and unchanged isolation/cleanup limits.

- [x] Verify the combined standalone-capacity and quiesce startup-order/binding repairs in one full fast check from the clean committed a160e5b0 candidate; retain the exact SHA, complete terminal output, measured durations and digest, while preserving the untraced failed-parent schedule and separate cleanup investigation as open obligations.

- [x] Reproduce and repair quiesce cancellation closure when a fence startup notice has not arrived; accept only Control's DOWN/absence-backed acknowledgement for an unannounced worker, refuse a foreign binding without falsely acknowledging absence, retain independent exact local DOWN for announced workers, prove expired/suspended-worker cases before and after the fix, and verify the complete quiesce file plus the unchanged real production fence cutoff on both supported pairs. Keep combined full integration and the original untraced failure schedule distinct.

- [ ] Investigate and repair the full 520ff308 integration failure in the sixty-three blocked quiesce fences sharing one cutoff with a settled sibling; retain the failed exact-candidate output, establish the cause through bounded runtime observability and actual process lifetimes, preserve the shared cutoff, sibling progress, fence accounting and cleanup assertions, and verify both supported pairs.

- [x] Verify the combined caller-monitor cleanup and maintenance reply-reserve amendment from one clean committed integration candidate; retain exact SHA, full fast-check output and selected Node release workflow, preserve failed evidence and keep the separate concurrent owner-stop diagnostic open.


- [x] Apply the approved single captured 1,000-ms CLI stalled-stderr writer-start cutoff and exact writer/device joins; fix the exposed foreign-monitor DOWN consumption by matching the captured PID/reference in the receive guard, preserve production queue/drop/drain/cleanup limits and JSON separation, retain failed proof and prove the affected workflow and shared chat cleanup on both supported pairs.

- [x] Verify the combined current-only callback and helper-fixture-discovery integration from a clean committed candidate, once per candidate; retain exact SHA, complete terminal output, measured duration and digest, preserving failed discovery and maintenance candidates and the focused buffered predecessor.

- [x] Declare the support-only retained-genesis fixture in composition's existing discovery ignore list; preserve every codec/admission case, automatic test-load patterns and warnings-as-errors, retain the failed exact-candidate integration and verify the unchanged focused case count on both supported pairs.

- [x] Run the standalone-dispatch and artifact-retention repair integration candidate once from a clean committed checkout; retain its exact SHA, complete terminal output, both measured durations and SHA-256, while preserving the failed parent's evidence.

- [x] Separate artifact-retention fixture prerequisites with the existing exact executor progress gate before the unchanged retention/commit waits; preserve original worker joins, source accounting, unknown-commit proofs and actual run/preparation cutoffs, retain the failed integration and controlled prerequisite comparison, and verify the complete artifact and surrounding files on both supported toolchains.

- [x] Reject premature interaction expiry by rechecking the retained wall-clock cutoff and re-arming against the same instant; reproduce the owner-exit defect before the fix and strengthen the existing live deadline test without changing its real two-second bound, completion cutoff, single settlement/ending, replay or no-redispatch proof.

- [x] Investigate and repair the CLI signal fixture's leaked process trees observed at the 2026-10-02 restart checkpoint; prove exact wrapper/VM joins for normal, interrupted and failing fixture exits without relying on manual cleanup.

- [x] Run the public-chat host and shared diagnostic-lifetime integration candidate once from a clean committed checkout; retain exact SHA, complete terminal output, measured duration and digest.


- [x] Run the prepared-policy scheduling and current-only request/receipt integration candidate once from a clean committed checkout; retain exact SHA, complete terminal output, measured duration and digest.

- [x] Run the combined owner-only settings-report and current-only settlement integration candidate once from a clean committed checkout; retain exact SHA, complete terminal output, measured duration and digest.
- [x] Run the full fast check once on the clean committed current-only tool and prepared-chat binding checkpoint; retain exact SHA, terminal output, measured duration and SHA-256 without claiming later changes are covered.
- [x] Migrate remaining executor/composition fixtures to current tool identities and remove their retired-generation positive cases; preserve retention, receipt, preflight and settlement bounds.
- [x] Replace the trace rate-window comparison with fresh physical delivery from each prompt under the original receive allowance; preserve session identity and exact actor joins.
- [x] Preserve the CLI exact-limit receipt/Store proof while checking the current bounded model projection.
- [x] Verify the integrated repair once on a new clean committed checkpoint and retain its complete output, exact SHA, measured duration and digest.
- [x] Run the full fast check once on the clean committed pre-1.0 retirement and chat-output synchronization checkpoint; retain exact SHA and terminal output/digest without claiming later public/startup reads are covered.

- [x] Acquire the owner-exit chat fixture writer synchronously before inducing loss; preserve exact DOWN reasons and receive deadlines, retaining failed parent evidence and both-pair focused proof.

- [x] Run the full fast check once on the clean committed guarded-activation and ordered-status candidate; retain exact SHA, complete output and terminal digest without reusing earlier integration proof.

- [x] Run the full fast check once on the clean committed resume/startup/signal integration candidate; retain its exact SHA, complete output and final result without reusing the earlier repair-only proof.

- [x] Confirm diagnostic writer dispatch through same-sender owner status before the existing blocked-device receive; retain the failed committed integration observation and prove unchanged pressure/accounting/receive/cleanup assertions on both supported pairs.
- [x] Pin the complete approved read/search generation registry in composition tests while proving legacy selections for all 128 tool subsets and optional question registration on both supported pairs; retain the failed integration parent.
- [x] Establish chat writer/worker monitors at their targets before faults sent to other processes; preserve exact killed/normal reasons and original DOWN waits, retaining failed integration evidence and both-pair output/driver proof.
- [x] Run the full fast check once on the clean committed repair candidate after the failed 41091199 integration run; retain its exact SHA, complete output and final result.


- [x] Restore the reference composition size gate by consolidating preflight in the existing DurableOptions owner; preserve validation precedence and constructor behavior on both toolchains.
- [x] Encode the historical interaction positive control with its reader's v2 settlement format while retaining refusal of new interaction records.
- [x] Route configuration model validation through composition and preserve the command-surface dependency scan.
- [x] Complete native stream fixtures across CLI/daemon workflows and retain real-HTTP Core byte-refusal and settlement-depth accounting witnesses.
- [x] Investigate and fix OwnerGroup supervisor shutdown_error/noproc diagnostics observed in configured-runtime test cleanup; retain failing-before and process-lifetime evidence independently of passing assertions.
- [x] Repair the complete owned-process inventories in credential-plane and runtime-owner fault tests; include the transfer-owner crash and prove all eight children stop on both toolchains.
- [x] Make the owner-group supervisor-report test establish and restore its Logger application lifetime; prove the original failure-report assertions from isolated Core on both toolchains.
- [x] Update the direct SessionRoot startup protocol proof for granted diagnostics and trace activation; preserve exact acknowledgements, wrong-reference refusal and original time bounds on both toolchains.
- [x] Establish an actual blocked diagnostic writer before mailbox pressure; preserve the 6,000-message observation, exact queue/writer/drop accounting and unchanged receive/cleanup timeouts on both toolchains.
- [x] Remove the spawned-host startup scheduling assumption from the abrupt chat-writer-loss fixture; retain unchanged receive timeouts and prove both exact writer and linked IO-worker killed DOWNs on both toolchains.
- [x] Order diagnostic shutdown through its private supervisor before collecting writer/supervisor joins; prove a failing-before suspended-supervisor fault and unchanged delivery accounting, grace, existing loss/deadline assertions, ephemeral trace and real CLI signal/JSON behavior on both supported toolchains.
- [x] Resolve the diagnostic owner/drain-loss test bound through the requested maintainer decision; apply and record an accepted captured-grace proof or retain the original waits and investigate, then verify the complete file on both pairs and run a new committed integration candidate once.
- [x] Repair the provider-child supervisor-loss fixture's monitor/fault ordering; preserve exact killed termination and original assertion bounds, retaining the failed committed integration output and both-toolchain proof.
- [x] Diagnose and repair the provider-launcher interrupted-wait namespace-failure terminal observation missing the captured 2,100-ms cutoff on e5; preserve the required bound and retain actual OS lifetime evidence.
- [x] Resolve the repeated provider-call public-event identity decision; implement the accepted compatibility path and prove old replay, repeated calls, cancellation, reconciliation and mutation uncertainty without rewriting retained events.
- [x] Adapt the composition authority inventory to the approved contextual question adapter; retain the failed no-callback assertion and verify absent/nil host refusal plus denied bare/contextual decisions for every shipped tool generation on both toolchains.
- [ ] Investigate Task.Supervisor and OwnerGroup shutdown_error/noproc diagnostics for Task.Supervised and coordinator children in configuration/input/interaction cleanup; retain reproduction and actual task-lifetime evidence, including the coordinator-child report in the maintenance-view full Core run.
- [x] Investigate and fix the AllowAll notice table ETS-transfer diagnostic emitted to `:init` during host-policy tests; retain a failing-before short-lived caller witness, exact DOWN and concurrent once-per-VM proof on both toolchains.

## T17 — Assemble and test the closure candidate

### Original checklist

- [ ] Provision both supported toolchains, pinned Node, provider bindings and the legacy Ollama witness.
- [ ] Provision Linux cross-UID support, descriptor limits, retained evidence storage and attendance.
- [ ] Finish all source, fixtures and documentation before committing the tested candidate.
- [ ] Move the candidate to In review with complete proof mappings and Pending evidence slots.
- [ ] Verify main is an ancestor.
- [ ] Count the existing current-toolchain fast check; run the floor-toolchain check.
- [ ] Run the full logical release matrix in its fixed order.
- [ ] Complete every M7 case, subcase and operator evidence join.
- [ ] Retain outputs, manifests, usage, sizes, durations, failures and independent review with digests.
- [ ] Present the exact candidate for the maintainer’s closure decision.

## T18 — Close M7 and merge back into main

### Original checklist

- [ ] Obtain explicit closure approval on the tested candidate and evidence.
- [ ] Create the administrative direct child confined to the five permitted paths and regions.
- [ ] Record both tested and administrative identities correctly.
- [ ] Verify confinement and status transitions.
- [ ] Fast-forward main to the administrative closure commit under the maintainer’s integration authority.
- [ ] Push and verify the resulting repository state.
- [ ] Clean up landed worker branches/worktrees; retain m7 through implementation and decide its disposition after closure.

## T19 — Prepare and publish the separately authorized release

### Original checklist

- [ ] Select the release label before testing any version-dependent source changes.
- [ ] On the administrative SHA, prove confinement, documentation structure and documentation meaning.
- [ ] Compare tested and administrative source archives using the required complete manifests.
- [ ] Validate modes, paths, source identities and permitted exclusions.
- [ ] Create the authorized annotated tag at the administrative SHA.
- [ ] Push the authorized tag/publication and verify its target.
- [ ] Reuse unchanged-source closure evidence; do not rerun the suite or provider matrix.

## T00 contract inventory

Accepted contracts mapped to implementation owners. This inventory records
required joins; exact payload vectors and fixture manifests remain separate
unchecked T00 obligations. New readers/writers must rejoin these contracts
before a provider demonstration.

| Boundary | Authority | Retained/new generation | Implementation owners | Status |
| --- | --- | --- | --- | --- |
| Conversation and result joins | ADR 0041 | Run/turn/call identity; admitted lineage order; revision-1 normalized IDs | Conversation; SessionState; SessionCoordinator | Implemented; broader boundary vectors remain |
| Tool-output preparation | ADR 0041 | Immutable receipt plus versioned prepared-reference/preparation-state facts and exact source digests | SessionState; SessionCoordinator; ArtifactStore; local executor | Implemented; exact-source preparation, frozen job context, early spill, literal generations and real prepared-range restart proved on both pairs; one actual 60-second cutoff per pair retained above |
| Artifact read capability | ADR 0041 | loopex.artifact_read.v1 binding from literal tool-generation table; resolved executor arguments | ToolDefinition; SessionGenesis; local read tool; SessionCoordinator | Implemented and proved through exact literal capabilities, owner membership, bounded job transfers and empty-registry restart |
| Instruction envelope | ADR 0042 | Closed version/base/environment/appendix map, exact rendered bytes/digest | SessionGenesis; configuration reducer; host composition | Pending |
| Context receipts | ADRs 0042–0044 | Current-only revision 4; mandatory continuation_cost and frozen source bindings; retired revisions 2/3 refuse | SessionCoordinator; SessionState; ContextAdmission | Ordinary nil/non-nil continuation costs and source/configuration bindings implemented; maintenance bindings pending |
| Context refusals and failures | ADR 0043 | Old context_admission_refused_v1 preserved; v2 configurable ceiling and new failure union | ContextAdmission; SessionState; protocol projections | Ordinary measured numeric v2 and unavailable terminal-history preparation failures implemented; other causes, maintenance/headroom and wire projections pending |
| Initial session truth | ADRs 0044/0046 | Read v2/v3 genesis; write coordinated closed v3 configuration/tool-selection/policy-defer payload | Runtime.Control; SessionGenesis; SessionState; Store conformance | Pure decoder/replay and host-private v3 creation implemented; reference-host writer and migration proof pending |
| Exact create and provenance | ADR 0046 | Pure resolve/normalize; exact-genesis create/lookup; read-only creation provenance and stable ordinals | Runtime facade; Control; Store adapters/conformance | Pure helpers, live exact create, exact lookup and provenance queries implemented; helper host integration pending |
| Atomic configuration | ADR 0044 | Settled configure command; immutable selection; captured version/model/bounds/metadata/mapping | SessionState; SessionCoordinator; composition; protocol | Pure preparation and live ordinary atomic admission/replay, retained-history sizing, restart and commit-boundary faults implemented; host resolution, prepared daemon routing, checkpoint projection and maintenance quiescence pending |
| Model request | ADR 0044 | Current-only v2 local-reference continuation with generic expansion; retired v1 refuses | Model; SessionState; SessionCoordinator; model adapters | Source-bound staging, bounded expansion, self-consistent retired-version refusal, committed-lineage validation and streamed/buffered native rendering implemented |
| Model reply and settlement | ADR 0044 | Bounded reply v3; current-only model_attempt_settled_v3; retired v1/v2 readers and cutover state; atomic reply/continuation/accounting | Model; ProviderAttempt; SessionState; adapters | Capsule expansion, native capture, strict callback projection and source-bound v3 readers/writer implemented with migrated callback fixtures; source-bound request envelopes and ordinary expanded accounting implemented; durable and buffered native emission implemented; maintenance accounting pending |
| Thinking mappings | ADR 0044 | Fixed nine registered cells, native block fidelity, frozen-prefix exchange and canonical conversion | ReqLLM mapping/transport; SessionCoordinator | Nine ordinary adapter mappings registered with both native transports, per-cell streaming/bound/disclosure and canonical terminal-history conformance; host integration, separate summarizer and live witnesses pending |
| Maintenance and compaction | ADR 0043/0044 | Captured maintenance configuration, immutable checkpoint and strategy revision 3, source_excerpted | SessionState; SessionCoordinator; ContextAdmission; host startup | Core startup capture and durable/ephemeral instruction forwarding implemented; model routing, episode capture, checkpoint and compaction pending |
| Question lifecycle | ADR 0045 | model_tool/policy_defer producer; bounded choice/text/decline; atomic disposition/result | Interaction; SessionState; SessionCoordinator; host responder | Durable Core lifecycle/replay, public ephemeral questions and joined one-call responder implemented; wire and attended evidence pending |
| Helper durable ownership | ADR 0046 | Bounded role/catalog bindings; reservation/allowance/monotonic-stop facts; derived job-index v1 | Host helper adapter; Runtime queries; Store; local executor | Pending |
| Host provider bindings | ADR 0048 | Explicit admitted routes and credential references through existing custody boundaries | Composition; ReqLLM provider route/custody; helper adapter | Shared reference/exclusion validation, ephemeral startup/dispatch, durable token selection and direct/borrowed/daemon custody startup implemented; CLI and helper integration pending |
| Host configuration grammar | ADR 0049 | Closed file/flag grammar, exact precedence, role selections, safe inspect and trace options | CLI; composition options; host renderer | Bounded JSON decoder, authored schema, relative file paths, trusted trace selectors, flag parser, new-session precedence/origins and initial capability/instruction admission implemented; complete role/maintenance preparation, command entry and redacted inspection pending |
| Foreground and daemon wire | ADR 0044 coordinated contract | Foreground /3 and daemon /4; complete schema digests/vectors and negotiation | Protocol; AppServer; daemon servers; independent Node clients | Pending |
| Public projection | ADRs 0043–0046/0049 | Versioned snapshots/events; bounded numbers/cursors; allowlisted configuration and maintenance | SessionState; protocol; AppServer; daemon; clients | Pending |
| Ephemeral entry points | ADRs 0042–0045/0048/0049 | Combined closed startup options; one-call responder consumed locally; joined termination | Ephemeral.Options/Preflight/Bootstrap/SessionOwner; facade | Joined question callback, provider bindings and trace implemented; full option forwarding and attended/provider closure evidence pending |
| Execution evidence | M7 technical acceptance contract | Fixed fixture/operator manifest; Pending scaffold; hash-chained single-writer attempts and fsync barriers | mix loopex.m7_evidence; release runner; PTY driver; evidence files | Pending |
| Upgrade and rollback | M7 compatibility contract | Exact retained M6 artifact/root fixtures; retain old rollback pair and add distinct M7 pair | rollback lane/scripts; Store recovery; operator instructions | Pending |
