# M7 restart checkpoint

Part of the [evidence index](README.md). This is a resume record, not an
acceptance, milestone closure or verification waiver.

## Concept

The maintainer requested a safe pause for restart on 2026-10-05. Resume the
existing M7 implementation goal on branch `m7`; do not use `m8`. Read this file,
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

## Technical depth

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

Integrated source is `8885e0dbacfc4a37cb873080d615869587132ea4`;
subsequent `m7` commits record evidence and work ownership only. The commit
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
