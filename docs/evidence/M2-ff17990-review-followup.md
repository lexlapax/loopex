# M2 source-baseline review follow-up

Part of the [evidence index](README.md).

## Concept

The proposed source baseline
`ff17990453426e129cf0b3f1895ae936f64ff875` is not cleared for integration.
The executable checks passed, but the retained evidence does not cover that
source and several repairs introduced unresolved ownership decisions.

This record reconstructs the maintainer-supplied review summary against the
repository on 2026-09-06. The original temporary review file was unavailable.
It is not a recovered copy of that report, an independent acceptance review,
or an acceptance disposition. Line references below name the reviewed source;
later repairs may move them.

The reviewer subsequently restored the original report. The complete-report
reconciliation below supplements that reconstruction; it does not replace the
original independent verdict or treat a repair as independently accepted.

The existing repair authorization remains the task scope. Historical override
21 continues to describe its original range; this follow-up neither extends
its accepted baseline nor authorizes integration, publication, or a version tag.

### Repair directions and remaining decisions

| Decision | Recommended direction | Alternative and consequence |
| --- | --- | --- |
| Provider credentials and diagnostics | Make protection explicitly host-owned. The subsequent proposal direction selects one separate provider process per invocation, leaving parent logging and shared ReqLLM group leaders untouched. Missing protection refuses admission; replacement cannot retry an uncertain call. | Same-VM protection couples shared ReqLLM users to a diagnostic lifetime policy that still needs proof. Process isolation adds framing, startup, companion build/configuration, cancellation, and real-provider evidence. A dependency change would need owned task supervision and safe diagnostics, not just a new supervisor option. |
| Prepared recovery handoff | Make the lifetime participant explicit on the public transfer boundary, retaining the ordinary two-argument call. Remove unused dynamic handler replacement and refuse duplicate initial installation atomically. | Ordinary transfer with a CLI-only guard is smaller, but cannot independently observe idle coordinator death through today's facade. That option must explicitly narrow immediate dependent-holder cleanup. Keeping replacement retains a state machine with no command caller and requires bounded, behaviorally proved draining. |
| Compacted provider accounting | Preserve ADR 0018's distinction. Malformed or pre-validation unreadable replies use estimated remaining allowance. A validated reply compacted only because its settlement cannot fit preserves reported usage. Introduce versioned retained provenance so replay can validate which case occurred and the exact retained usage. | Estimating every unreadable result is smaller but supersedes ADR 0018 combination 5 and loses known reported figures. Retaining today's permissive validator leaves the accounting claim without retained provenance. |

On 2026-09-06 the maintainer approved the initial host-owned protection,
explicit handoff, and provenance directions for preparing decision proposals.
The later provider-process selection is recorded below. Neither confirmation
accepts an ADR, extends override 21, or authorizes integration or publication.
That proposal-stage authority is historical. The exact contracts were subsequently
accepted on 2026-09-07 as recorded below.

The accepted decisions now fix the contracts, compatibility, recovery, and
rollback. Their implementation and behavioral evidence remain work to perform;
acceptance is not a claim that provider isolation or either other repair runs.

The maintainer owns these decisions. The recommended directions preserve the
existing provider dependency and ordinary transfer call while replacing hidden
ownership with explicit configuration and a named handoff. That limits new
integration machinery, but embedders must opt into protection and the CLI must
use the explicit handoff. New accounting provenance requires versioned
read/write and legacy-history rules; rollback must not let an older reader
silently consume records it cannot validate. Each chosen contract needs its
compatibility inventory, conformance tests, and exact-SHA review updated.
Changing an accepted ADR or locked gate, if the selected option requires it,
must use its governed transaction; this evidence note changes neither.

The concrete proposals are [ADR 0019](../adr/0019-host-owned-provider-protection.md#concept),
[ADR 0020](../adr/0020-explicit-prepared-handoff.md#concept), and
[ADR 0021](../adr/0021-compacted-provider-accounting-provenance.md#concept).
All three were accepted at proposal `b7f97092f7b6d6661e66bc775fd88195b92b67a0`
by the [standalone disposition](../developer/agent-context-map.md#disposition-adrs-0019-0021-2026-09-07),
recorded in transition `63511ca264ef99e8b93367a9cd671165525e4d4f`.
ADR 0021 makes one operator cost explicit: an old unreadable-plus-reported settlement
has no recoverable usage provenance, so the new reader refuses that session
rather than rewriting accounting. These proposals supply no executed conformance
claim. No product, accepted ADR, plan, gate, or lifecycle bytes move with them.

<a id="provider-protection-choice"></a>
### Provider protection: selected proposal direction

Host ownership alone did not settle diagnostic lifetime. The pinned ReqLLM
implementation starts streaming work under a shared task supervisor and emits
raw inspected failures. Worker death and trace delivery do not prove that OTP's
asynchronous logging queues have drained. A credential registry's failure must
not make unrelated host logging unavailable, but discarding its protection too
soon can expose delayed reports. The reference is trusted same-VM code, not a
sandbox against other host code.

| Option | Operator consequence | Stability, modularity, extensibility, and transaction cost |
| --- | --- | --- |
| Separate host-owned provider process — recommended | Host logger stays untouched. Provider-process loss refuses or conservatively settles that attempt; replacement can serve later work after exact cleanup. | Stronger process/diagnostic boundary and replaceable host composition, but adds bounded versioned framing, credential handoff, launch/package layout, child crash-output containment, and cleanup evidence. Same OS account is not an OS sandbox. ADR 0019 must settle those contracts before implementation; integration requires new process/live-provider and exact-source evidence. |
| Explicit same-VM protected diagnostic lifetime | Suppress raw provider diagnostics using stable non-secret origin identity; retain that policy beyond calls. A non-replaceable protection origin lost during the VM's lifetime requires VM restart, or a separately bounded retired-origin policy requires restart when its capacity is exhausted. | Smaller provider-call change but couples every shared ReqLLM user to one host diagnostic policy. Requires complete origin classification across task, supervisor, and application-exit reports, plus group-leader/application-lifecycle proof. Registry and ordinary provider-supervisor restart must not require poisoning unrelated logs. This is additional behavior, not implied by host opt-in; it needs disposition and exact OTP-floor/current evidence before an acceptance-ready proposal. |
| Change the provider dependency boundary | Keep in-process embedding only if owned task placement and safe diagnostics can be proved end to end. | Changes dependency/floor and adapter conformance evidence; a supervisor option alone does not contain generic OTP reports. This is a separate dependency decision, not a smaller undocumented repair. |

The source investigation inspected ReqLLM's pinned streaming client and installed
OTP 29 Logger, logger proxy, process/supervisor reports, and application cleanup.
Application-exit reports can originate outside the provider's group leader;
ordinary task or process metadata alone is not a complete classifier. The
same-VM option is therefore a design direction requiring that proof, not a
claim that a pure filter is already sufficient. No secret-retaining tombstone
collection or node-wide logging blackout is accepted by this record.

Any option changing an already locked provider role or evidence artifact must
enumerate that change and use the holder's Closed-gate generation transaction;
being locked does not remove that option. Supplemental repair checks can be
added without silently changing the lock. The two other proposals can progress
independently, but final integration evidence waits for provider protection.
The remaining effort is at least a proposal/review round and an implementation/
evidence round; no calendar completion or clean outcome is claimed in advance.

On 2026-09-07 the maintainer answered "Go" to developing the separate-provider-
process proposal. This authorizes drafting ADR 0019, not accepting its exact
contracts or implementing them. The resulting pair selects one non-distributed
provider BEAM per invocation, a private companion escript in the existing
adapter application, and explicit host launch paths. It introduces a proposed
65,536-byte credential limit for private post-bootstrap handoff; the current
adapter has no such product ceiling, and the harness's limit is not its basis.
No key enters the launch environment. The Model callback, Core permit,
accounting authority, and application count remain unchanged by the proposal.
The pair also makes direct callers migrate to an options-taking helper, gives
standalone calls an explicit cleanup period, and keeps guard control on a pipe
separate from the single-use local data socket. These are proposed contracts,
not silently completed repairs.

The companion's startup and cleanup, faithful bounded reply transport, actual
credential containment, and packaged floor/current behavior are first-implementation
evidence obligations, not properties this documentation pass has executed.
Internal source review informed the proposals. The maintainer has now accepted
all three; an independent exact-diff review found the acceptance transition clean.
It examined no product implementation and cleared none for integration.

## Technical depth

### Reconstructed blocking findings

| Item | Evidence at the reviewed source | Required follow-through |
| --- | --- | --- |
| Source and retained evidence disagree | [Recorded limitations](M2-recorded-limitations.md#fourth-audit-release-repair), lines 824–825 and 881–888, ends the authorized baseline at `bf534bc`. There are 27 subsequent commits through `ff17990`, including evidence-only child `60b721d`, and 11,158 added lines. [Post-closure attestations](M2-post-closure-attestations.md), lines 3–9 and 27–35, bind `34069a0`; lines 42–44 state account lookup was not performed. | After product decisions and repairs, retain new evidence for final source `S`, including provider-account verification. An evidence-only child `E` must name `S` and the actual repair range. Obtain independent review of `E` and its evidence-only edge before integration disposition. |
| Adapter takes VM-wide authority at startup | `credential_filter.ex:137` installs a primary Logger filter and changes the shared ReqLLM supervisors' group leaders. Lines 119–131 stop unrelated logs when protection is unavailable; lines 321–327 preserve a poisoned state on restart. The credential-plane test at line 364 requires this behavior. | Select explicit host ownership, a separate process, or a dependency-level solution. Do not relabel the current global side effects as runtime-local. |
| Managed provider guardian can outlive every retainer | `req_llm.ex:810` waits only for correlated stop after the callback result. The callback monitor was already removed. Losing the retaining Core guard leaves the guardian and credential lease alive. | Return the retaining guard from private resource registration and monitor that guard through active work and the post-result wait. Retainer death stops descendants and releases the lease without inventing a stop acknowledgement. Callback completion must still preserve normal correlated cleanup. |
| CLI selects a hidden Core ownership protocol | `interrupt.ex:608` writes a process-dictionary marker; `session_coordinator.ex:233` uses it to select different transfer behavior. `interrupt.ex:790` holds a global installation lock across unbounded predecessor waits at lines 857 and 976. Production CLI calls install once per command. | Select an explicit handoff contract and dispose of unused replacement behavior. Initial installation still needs atomic duplicate prevention; `gen_event.add_handler` does not guarantee unique handler identity. |
| Compaction accounting is misstated and cannot be validated | The limitation record at lines 871–879 misstates ADR 0018. Its technical combination 5, lines 280–284, retains validated reported usage on settlement compaction. `ProviderAttempt` lines 608–646 accept either accounting source and any reported pair for every unreadable result. The table fixture at protocol-test lines 5315–5321 explicitly admits unrelated reported figures. | Record the exact chosen accounting and versioning decision; fix producer, replay validation, and tests together. Preserve historical source records and immutable accepted envelopes. |
| Several tests overclaim their observation | Executor tests inspect regex/source order; prepared recovery tests compare lexical call positions and use 250 ms `Task.yield` silence as a drain verdict. An option assertion alone does not prove transport behavior. | Replace reachable source assertions with controlled behavioral boundaries and result/ownership assertions. Delete replacement-only tests if replacement is removed. Keep any irreducibly structural protection explicitly labelled and independently dispositioned. |

The transport claim requires qualification: the reviewed tree also contains
`one durable model attempt invokes the provider transport exactly once`, which
counts requests received by a real loopback 429 server. Another test invokes
ReqLLM's retry machinery with an instrumented transport. The option assertion
is therefore not the tree's only retry evidence. The retained exact-SHA review
also reported that removing the production retry restriction was killed. This
does not validate unrelated source-order or silence-based assertions.

### Other reconstructed repairs and limits

- Initial prepared state has no preparer monitor. Different installer-loss
  windows can leave the same unspent capability prepared or abandoned. Use
  the existing holder-loss mechanism from preparation onward, replacing the
  monitor only at a proved transfer.
- Guarded transfer calls `Process.alive?/1` on arbitrary participant PIDs.
  Reject unsupported non-local participants before a local liveness call can
  raise inside the coordinator.
- Fixed observation-call bounds must be checked against the operation they
  observe. A returned timeout does not prove an attachment or transfer failed
  to happen. Extending every call to infinity would not repair that contract.
- ReqLLM resolves the credential and builds credential-bearing options before
  the protection lease. Move both inside the selected protection owner.
- Restarting ReqLLM supervisors replaces the PIDs verified by the current
  credential facility; its normal admission path only verifies, not rebinds.
  The selected host facility needs a tested restart protocol.

These findings were reconstructed by source inspection. No new live account
lookup or provider call was performed for this record. The final source and
evidence checks remain future work; earlier green results are not projected
onto changed bytes.

<a id="completion-order"></a>
### Completion order

The three implementation workstreams are joined on the repair branch. The
checkpoints below describe completed work, not an assertion about an uncommitted
or future candidate. Acceptance of ADRs 0019–0021 is
recorded at `63511ca264ef99e8b93367a9cd671165525e4d4f`. The maintainer separately
authorized implementing these decisions and preparing release-review evidence.
The integration branch is `codex/m2-release-repair`. `main`, M2's Closed
register, accepted gates, and historical dispositions remain unchanged.

| Work item | State and owner | Completion requirement |
| --- | --- | --- |
| Record ADR acceptance | Complete; integrator | Exact-diff independent transition review clear; status and commit-message checks passed |
| ADR 0019 provider isolation | Actual two-runtime, pre-entry failure, backpressure and both narrower retainer-loss witnesses joined; 138 provider cases pass in the whole suite at `47948df` | Complete process-inspection and final-source package/platform/live evidence; earlier packages remain bound to their own sources |
| ADR 0020 explicit handoff | Joined Core and CLI lanes pass at `47948df`; all thirteen locked prepared-recovery names preserved | Final-source checks and independent content review; stale test comments corrected without changing behavior |
| ADR 0021 accounting provenance | Joined Core/CLI lanes pass at `47948df`; genuine old-reader control/refusal and actual child-provider accounting/rendering proofs remain source-scoped below | Final-source rollback and independent review; no old-source result is projected onto the final candidate |
| Rejoin and conformance | Clean `47948df`: zero compile warnings, 1,031 passed, zero failed, five live exclusions; `810f44c` subsequently strengthens one existing cleanup-receipt witness | Final clean source selection and serial qualification; no locked name, minimum, bound artifact or production byte changed in the witness repair |
| Clause-derived mutant hunt | The six earlier focused survivors have behavioral detectors; the restored-report content audit found and repaired a cleanup-adopter witness gap | The newest mutation was not executed after action-review refusal; no mutation kill or whole-suite survivor is claimed for it; independent review remains required |
| Final source and live evidence | Pending; integrator | Clean source `S`; full serial checks, literal M2 gate, actual provider/build identity and account verification |
| Release-review handoff | Pending; independent reviewer | Evidence-only child `E` names final `S` and actual repair range; push checkpoints; no integration or publication inferred |

Each writer uses its own disposable clone and branch. The integrator owns rejoin
and the candidate SHA. A single test-lane token covers all Mix/dependency/test
execution. No in-flight process is terminated merely to checkpoint work. Clone
paths are temporary execution state, not durable evidence or authoritative source.
The earlier public-overload and socket-write execution denials were resolved by
the explicit confirmation below. The maintainer has also explicitly authorized
the test migrations, as recorded below. The independently preservation-reviewed
provider-contract migration subsequently received execution approval and passed
all fourteen cases. The remaining legacy files and cold-build helpers have now
joined, and the complete provider application passes as recorded below. That
application result does not substitute for the joined eight-application suite.

### Implementation checkpoint on 2026-09-07

This earlier checkpoint predates the execution confirmation and source rejoin.
Its described working-tree and branch state is historical, not the current task
list above.

The repair branch carries the accounting implementation, configuration validation
(`f628131`), and private codec through merge `cc28caa`. These are pushed, not
integration or release candidates. The separate pushed branch
`codex/provider-process-guardian` retains
`31ccf5a40b2c8efe041dc0e4d4f7aba63fa0f045`. Its private Core registration/stop
message changes must join the matching adapter and fixture migration; merging
them into the still-active old adapter path alone would break that path.

The guardian's independent checkout passed warnings-as-errors compilation and
11 real-process/local-escript tests, seed `3107`, with the integrator's codec
and configuration supplied as test-only support. Those support copies were
excluded from its five-file commit. Its final process inventory found no owned
carrier, guard, or fixture worker left alive. The codec has 15 passing tests,
including local sockets and receive slicing for a `2^80` timeout. Configuration
validation has four passing cases. The joined accounting/protocol corpus passed
71 cases with seed `530542` in 28.7 seconds, credential-free and serially.
These are separate focused checks, not one whole-suite or packaged-provider pass.

The execution approval service also rejected changing the bridge's socket-write
primitive to `:infinity`. The intended finite operation bound belongs to the
independently responsive guardian, which stops the raw writer and closes the
socket at the committed deadline; `:infinity` would remove only the primitive's
smaller timer-domain constraint. The denied edit did not land in the guardian
checkpoint. Its original finite primitive remains and has not been proved for
the full accepted deadline domain. A smaller hidden timeout was not substituted.
This execution decision needs explicit resolution before that path is complete.

The integrator's uncommitted worker/build drafts remain in the repair checkout:
`provider_worker.ex`, `provider_build_identity.ex`, the provider build task,
adapter and CLI Mix files, CLI `provider_launch.ex`, and adapter/composition/CLI
wiring. A first force compile exposed a generated-manifest type warning and a
compile-time attribute syntax error; both were fixed, and the next
warnings-as-errors compile passed. Those drafts are not pushed or behaviorally
validated. In particular, the old VM-global adapter protection is still active;
the new child entry is not a claim that it has been removed. The draft contains
the same socket-write design awaiting approval and must not be silently treated
as an accepted execution workaround.

Remaining provider work is concrete: reject an unexpected credential frame in
the raw receiver before it can reach the guardian; wire the adapter to the new
bridge; remove old diagnostic ownership and replace its implementation-specific
tests with actual process observables; prove the worker's one-invocation latch;
derive the build-input manifest from exact archive paths/bytes; prove CLI config
refresh and floor/current packaged execution; then run real-provider evidence.
The build draft's basename-only input inventory is not a package-equivalence
proof. No live key was used for the focused checks above.

After the two execution approval blocks are resolved, complete ADR 0020 in its
own workstream, join the implementations, run the broader suites serially, and
perform the independent mutant hunt before freezing source `S`. The old-binary
replay proof, exact-source gate, account lookup, evidence-only child `E`, and
release review all remain outstanding. No test-lane process is intentionally
left running across this checkpoint.

### Explicit execution confirmation — 2026-09-07

The maintainer answered "Yes" to this exact follow-up question: "Do you
explicitly authorize adding the three-argument handoff that stops only its
owned prepared holder on lifetime loss, and allowing the socket writer to wait
without a separate timeout while its independent guardian enforces the
committed deadline?" Both workstreams may resume within that scope. This
confirmation does not remove the committed deadline, permit termination of
unowned processes, change an accepted ADR or gate, or authorize integration,
tagging, or publication. Execution success and behavior remain to be proved.

### Source rejoin and test-migration stop — 2026-09-07

The separate provider-process guardian and archive-bound build were joined, then
the adapter was routed through the companion bridge and the retired parent
Logger registry/application hook and IO sink were removed. The explicit handoff
and its approved test changes are also joined. At source `909a358`, a serial
credential-free `mix compile --force --warnings-as-errors` passed across all eight
applications. Two preliminary compilations refused real join-time warnings: an
unreachable adapter branch was removed, and the CLI's new unresolved-result
branch became reachable when the matching handoff implementation was joined.
Those refusals were not suppressed or presented as passing runs.

The joined Core provider protocol and accounting corpora first passed 69 of 71
cases. The two failures were an obsolete four-member private cleanup-message
expectation and a source-inspection lookup of the resource-registration helper's
old arity. The test now observes the added cleanup window, additionally checks
both integer deadlines and their order, and inspects arity seven without removing
any of its lifetime-ordering assertions. After that edit, the same two files and
seed `530542` passed all 71 cases in 28.7 seconds. This result belongs to the
post-rejoin test-fix worktree, not to an unchanged retry of `909a358` and not to a
whole suite. Formatting, compiled-documentation coverage (616 covered entries),
and commit-message checks also passed. No live credential was used, and no
test-lane process was left running at the checkpoint.

Focused worker evidence belongs to each worker's exact checkpoint, not to this
joined source:

- Guardian `728b4e3`: 15 real-process/local-escript cases passed, seed `3107`,
  and warnings-as-errors compilation passed. Saturated-output testing exposed
  an implicit 180-second socket-close drain; production now stops its owned
  sender/receiver and uses abortive close. The strict correlated process-death
  assertion was preserved, not relaxed to accept a normal exit.
- Build `4045382`: nine focused checks passed, and a clean companion build
  independently verified both archive inputs and the literal manifest. This
  does not prove the final joined worker, the actual CLI alias, a copied package,
  or the floor toolchain. Both exact floor installations were located but not
  executed for this checkpoint.
- Handoff `18e7b32`: final formatting and warnings-as-errors compilation passed.
  Twelve selected cases passed earlier in that workstream; subsequent helper
  cleanup and supplementary-test adaptations still require retesting. All
  thirteen locked prepared-recovery names remain exact.
- Fixture `429a4b4`: new provider-process support only, subsequently formatted by
  the integrator. It has not been compiled as a test fixture or executed. It is
  not package evidence.

The approval service blocked migration of the supplementary test named
`private lifetime markers fail closed while an ordinary holder transfer stays
unchanged`, despite the accepted removal of its hidden selector. Its body and
helper remain unchanged. Five other obsolete replacement/drain cases were
replaced only after a claim-preserving five-case duplicate-refusal mapping was
approved.

The same service blocked the adapter-contract rewrite and the explicit-launch
helper migrations because they alter existing protected test execution paths.
All five original adapter test files remain untouched. The proposed migration
keeps the exact M0/M1/M2 protected names, real-provider tags, ten classified
post-canary modes, minima, and refusal/identity assertions; it moves observations
from the retired same-VM credential registry to actual child entry, transport,
group cessation, unchanged parent diagnostics, and retained cleanup ownership.
The credential-plane replacement has not been authored. No denied patch was
applied indirectly or split into smaller edits to bypass the refusal.

At that checkpoint, explicit permission for those test migrations was still
needed. Their risk is
losing a surviving behavior while replacing implementation-specific assertions;
the required safeguard is a claim-by-claim mapping plus actual child-path
execution and subsequent independent mutation checks. This is not permission to
edit a locked gate, change a protected name or minimum, skip a required real
provider path, or manufacture a green suite. Full-suite, final package, fresh
clause-derived mutants, old-binary replay, live provider/account verification,
source-bound gate, and release review remain outstanding.

### Test-migration authorization — 2026-09-07

The maintainer answered "Yes" to the exact question: "Do you explicitly
authorize migrating those existing tests and provider helpers to the accepted
designs, preserving every locked name, minimum, required real-provider check,
and surviving behavioral guarantee?" The maintainer then directed completion,
in-scope repairs, and preparation for review without additional consultation
unless a new architectural decision appears. This settles the requested test
migration, not integration or publication, and does not authorize deleting a
surviving behavior merely because its existing fixture used a retired mechanism.

A fresh inspection of the first provider migration found four preservation gaps:
the detached-process replacement did not create the original real socket/task
chain; direct-IO replacement omitted explicit refusal and parent-task usability;
the retaining-owner cleanup replacement omitted causal queued-result ordering;
and unmanaged success omitted the blocked-cleanup-before-return schedule. That
weaker proposed patch remains unapplied. A revised migration must preserve those
claims through the actual isolated worker, not a compatibility shim for the
retired registry. The approval refusal was not bypassed.

The joined `5948fc1` checkpoint supplies nine supplemental actual-entry cases,
including the four preservation schedules above, but does not replace the old
adapter corpus. It also disables workspace dotenv loading before dependency
startup and directs only the private worker's dependency supervisors to its
protected IO sink. Those nine tests passed at that checkpoint; no package,
live-provider, whole-suite, or independent-mutation result is implied.

The portable `scripts/provider-accounting-rollback.exs` probe now passes against
separate current-writer and genuine old-reader VMs with an on-disk local Store.
Old source `63511ca264ef99e8b93367a9cd671165525e4d4f` writes version 1 and resumes
its own version-1 session successfully. Current production at `4913bd0` writes
version 2; that same old binary refuses it both during direct replay and through
the facade before readiness. Each reader adds exactly one fenced ownership row,
no semantic record, no public event, and no model or executor call; existing
records remain unchanged and the complete pre-read log is retained. Runs use
Elixir 1.20.3 / OTP 29.0.5, separate credential-free VMs and fresh temporary roots.
The script itself was being finalized during those checks, so these are focused
compatibility results rather than final clean-source package evidence.

The first probe failed because its event consumer did not handle `{:error,
:empty}`. Its initial old-reader refusal was also discarded: the version-1
positive control exposed a runtime-placement mismatch in the probe. A bounded,
isolated process-exit trace identified that cause; both writer and reader now
use the same declared placement. No production check was relaxed. Only the
subsequent passing positive control and corresponding version-2 refusal count.

The independent accounting hunt attacked the accepted clauses without reading
the author diff. Clearing the prior termination during reply compaction and
resetting the version latch at a later prompt each survived the original
71-case accounting/protocol corpus, formatting and warnings-as-errors compile
at `5254dff`. They were separately rejected by new probes while unchanged
production passed them. These are focused-corpus survivors, not whole-suite
survivor claims. Their three behavioral detectors are now in
`provider_accounting_lifecycle_test.exs`; the joined accounting/protocol corpus
passes 74 cases, seed `530542`, in 28.6 seconds. No production repair was needed
for these two evidence gaps, and no gate lock was advanced.

One new checkpoint had a 75-character title. An explicitly scoped execution
approval allowed correcting that message and its dependent hashes while proving
identical source trees, retaining a recovery ref, and leaving every accepted
candidate untouched. `5948fc1` maps to `90d3419`, `749fbe9` to `952a14d`,
`692f8f4` to `26beac0`, and `adf5245` to `f4a2d5b`. The repair branch alone was
updated using an exact-origin force-with-lease; the commit-message check then
passed. Worker verification named above remains evidence from where it ran,
not a claim that those commands were rerun after message correction.

### Original repair sequence (historical)

1. Repair the orphaned guardian and test active-call, post-result, and
   descendant-cleanup owner loss.
2. Independently review the three ADR proposals at their exact candidate and
   obtain explicit maintainer acceptance before dependent implementation.
3. Implement the agreed boundaries, installer-lifetime consistency, local-PID
   refusal, and behavioral test replacements.
4. Run clause-based mutants in disposable clones and the relevant conformance
   suites; retain the exact failures that prove the new tests matter.
5. Commit final source `S`, then run the required checks serially, including
   the literal M2 gate and live provider roles in a fresh clone.
6. Retain provider-account verification and source-bound evidence in child `E`.
7. Push all commits and obtain independent review of the exact `E` candidate.
   Integration and any publication remain separate dispositions.

### Focused repair verification

The guardian repair returns the actual retaining Core guard from private
resource registration and monitors it across the adapter lifetime. It does
not monitor only the callback, whose normal exit is expected. Death during
active work closes descendants before releasing the credential lease. After
descendant cleanup, a fresh monitor re-observes owner death even if the cleanup
receiver consumed its earlier notification. Owner death creates no stop
acknowledgement; the ordinary stop acknowledgement still follows lease release.

The supplemental adapter cases drive the shipped adapter with a synthetic
retaining registrar and controlled transport. The cleanup case suspends the
guardian, queues the real worker result, then queues retaining-owner death,
and resumes it. It proves that ordering rather than depending on winning a
scheduling race. The separate Core protocol corpus exercises the real resource
registration path. This is focused repair evidence, not a live-provider run or
a new integration review.

Serial, credential-free checks with seed `530542`:

- Adapter contract file: 12 passed, including all three owner-loss windows.
- Core provider-attempt protocol file: 64 passed.

A delegated clause-based mutation hunt used a disposable clone, without reading
the change history or mutating this checkout. All commands unset
`LOOPEX_PROVIDER_API_KEY`, `OPENAI_API_KEY`, and `ANTHROPIC_API_KEY`.

| Deliberate production fault | Direct detector and result |
| --- | --- |
| Ignore retaining-owner death during active work | `retaining owner loss during a managed call stops transport and releases the credential lease` fails awaiting guardian exit. Adapter file: 10/12 passed; a later lease-idle assertion also fails because the mutant strands the lease. |
| Observe only normal retaining-owner exit after a result | Both post-result and descendant-cleanup owner-loss cases fail awaiting guardian exit. Adapter file: 8/12 passed, including two consequential lease-idle failures. |
| Reuse the old monitor after descendant cleanup | `retaining owner loss during descendant cleanup releases the credential lease` alone fails. Adapter file: 11/12 passed. |
| Acknowledge stop before releasing the credential lease | `a managed adapter result precedes its retained resource stop acknowledgement` alone fails its observed first-send ordering assertion. Adapter file: 11/12 passed. |
| Return the callback PID instead of the retaining guard from Core registration | The previous Core corpus passed all 63 cases. That mutant also passed the then-current whole suite (932 passed, five default real-provider exclusions), formatting, and warnings-as-errors compilation. The new independent cleanup-requester case rejects it at `retainer == requester`: 63/64 passed. Restored production passes all 64. |

The last mutant was a real evidence gap, not a production defect left in this
repair. The new case waits for the callback to return normally, observes which
process actually requests resource cleanup, and compares that sender with the
registration result. It also proves the retaining guard stays alive until the
resource acknowledges cleanup. It does not compare a value with its own source.
These added cases are supplemental; this repair changes no locked selector
name, gate minimum, or bound gate artifact.

The focused commands were `mix test
apps/loopex_llm_reqllm/test/provider_attempt_adapter_contract_test.exs --seed 530542`
and `mix test apps/loopex/test/provider_attempt_protocol_test.exs --seed 530542`,
run separately. Survivor qualification used `mix test --seed 530542`,
`mix format --check-formatted`, and
`MIX_ENV=test mix compile --warnings-as-errors`. The 932-pass result above
belongs to a deliberately broken implementation under the prior corpus; it
is not a green result for the final repaired candidate.

The execution profile permitted writes and local process/socket inspection.
No real credential was needed. Final source-bound gate, live-provider, and
provider-account evidence remain outstanding; the three architecture decisions
are now accepted as noted above.

Before committing the repair, serial repository checks also passed:
`mix format --check-formatted`,
`MIX_ENV=test mix compile --force --warnings-as-errors`,
`mix loopex.docs_check` (611 covered entries), and `mix loopex.status`.
These checks do not stand in for the still-outstanding final gate and review.

### Explicit-handoff clause hunt — 2026-09-07

A fresh independent actor read ADR 0020 and the current handoff implementation,
not its author diff or history, at `f4a2d5b3ee0ff4fd7bc2eb588e5b66e62bd546b2`.
Two minimal mutations each passed the original 54-case prepared-recovery corpus
with seed `3107`, whole-repository formatting, and forced warnings-as-errors
compilation on Elixir 1.20.3 / OTP 29.0.5. Neither is a whole-suite-qualified
survivor, because the provider-test migration still prevents that qualification.

| Deliberate fault | Independent behavioral detector |
| --- | --- |
| Remove the committed-but-unresolved participant-loss abandonment | Keep the original preparer alive and do not abandon on its behalf. After participant loss returns unresolved, that same process presents the capability through the public activation API. Unchanged production refuses with `resume_activation_abandoned`; the mutant activates and returns success. |
| Replace the exact participant-PID match on a verdict acknowledgement with a PID-shape check | Retain the genuine pending handoff, then send wrong-participant and wrong-holder acknowledgements with the exact nonce, handoff and commit references. A following system request from the same sender proves processing. Unchanged production preserves the pending state until the actual participant acknowledges; the mutant commits the wrong participant's acknowledgement. |

Both separate detector cases passed on unchanged production and failed their
respective mutations. The hunt restored all production bytes, confirmed their
source hash, and left no executing test VM. The two detector bodies are added to
`prepared_recovery_contract_test.exs` without changing any existing selector,
minimum, gate or production byte. The joined prepared-recovery corpus passes all
56 cases in 25.0 seconds with seed `3107` and warnings-as-errors. Its first format
check caught a detector-only line wrap after renaming the probe message; that
was formatted before testing. The original implementation already honors both
requirements.

### Provider clause hunt and joined detectors — 2026-09-07

An independent actor read ADR 0019's lifecycle and codec requirements and current
production, not the author history or diff, at
`faa340f0343e4d46d89aefd9663e66248f464fc3`. Restricting retainer-death handling to
the interval before callback delivery and deleting the decoder's nesting guard
each survived the existing 47-case isolated-provider corpus, formatting and
forced warnings-as-errors compilation. Separate behavioral cases passed on
unchanged production and rejected those faults. These are focused-corpus
survivors, not whole-suite-qualified survivors or newly found production bugs.

The first detector waits for a successful actual worker reply and normal
callback-process exit, then kills the independent retainer and requires guardian,
worker and namespace cessation. The second sends a valid boundary-depth terminal
and then a correctly framed over-depth terminal through the actual local socket
receiver, bypassing only the encoder's rejection of invalid input. It therefore
proves the decoder's independent responsibility instead of testing the encoder
twice. The two additions leave every existing name, minimum and gate byte intact.
The joined five-file provider corpus passes 49 cases, seed `3107`, in 30.2 seconds
with warnings-as-errors. All commands exclude ambient provider credentials and
use synthetic local transport only.

### Integrated self-audit required before release-review handoff

The maintainer explicitly required a thorough self-audit on 2026-09-07 after
repeated audit/repair cycles. Finishing individual findings is not the handoff
criterion. No final source, evidence child or review-ready verdict may be claimed
until the following integrated checks are settled:

| Area | Required proof before handoff |
| --- | --- |
| Contract and composition | Map every ADR 0019–0021 requirement and the inherited release obligations to current production and real entry paths; reconcile direct adapter, embedded runtime, CLI, recovery child and cold gate configuration |
| Correctness and lifetime | Exercise ownership loss before, during and after work; unresolved handoff fences; exact cleanup acknowledgements; whole-parent-VM death; accounting/recovery across real Store versions |
| Test honesty | Preserve each surviving legacy guarantee; prove the actual observed values instead of literals or setup failures; close known mutation gaps and distinguish structural-only protection from behavioral evidence |
| Security and public impact | Check first-image and delayed diagnostics, credential and raw-reply boundaries, host isolation and concurrency, and every changed helper/configuration contract against operator and compatibility documentation |
| Portability and rollback | Run the supported toolchains and actual build pair outside the checkout; retain measured cost, source/artifact identity and genuine old-reader controls; disclose unavailable evidence without calling it a pass |
| Final verification and records | Freeze clean source `S`, run whole-suite/repository/gate/live lanes serially, retain account and source-bound evidence in child `E`, review the evidence-only edge, and push before requesting independent release review |

Remaining implementation or evidence defects are repaired before that handoff.
Any newly required architecture decision still goes to the maintainer; neither
this task list nor a green command supplies acceptance, integration or publication
authority. Execution-approval refusals remain visible and are not bypassed.

### Exact package and whole-parent loss proof — 2026-09-07

Clean source `faa340f0343e4d46d89aefd9663e66248f464fc3` was built and checked in
two isolated roots on Darwin 25.6.0 arm64, using Elixir 1.20.3 / OTP 29.0.5 and
the Elixir 1.17.0 / OTP 26.0 floor. Each real CLI build alias produced its companion
and embedded matching launch configuration in an external Mix build root.
Independent archive inspection compared actual input entries, manifest, executable
digests, source, toolchain and lock identity. Both source checkouts ended clean,
without checkout-local `_build` directories.

| SHA-256 identity | Current | Floor |
| --- | --- | --- |
| Manifest | `97302b1ca7c48c3858b4f094184fcc0956da6078b49ca28f902d3a8c544268ca` | `c712a4d859c6247b77bc2e4170a4aac235fd3b5c53ed9a7c0827abf4f2e4d707` |
| Companion | `34373052d142b5f3dfbad5d75dcfc4e13b2db006e9233bd2a4c71a2f8cadc90c` | `9d0d7aa87ffa014068a39436fe83edc53be91f2a6d74249dea71d9eaf6a4e1ba` |
| Command | `228988679a49feb897ce82d4f80493aaca09ce7fc5df5c62d43d544a51f99e44` | `027f4897e59b9342ccc1f7dbd6b0f2ca7a85f6ad917e22479c107df63146b0b9` |

The unchanged companions reached protected readiness outside the checkout with
development and malformed dotenv files. Archive-only model lookup resolved the
default Anthropic model without checkout `priv` paths. Separate interpreter
wrappers observed control descriptors 3 and 4 closed **before** executing the
configured interpreter. Canonical-interpreter runs completed correlated cleanup;
the copied CLI listed an empty state root successfully. No remote application
inventory was collected: application isolation is supported here by readiness
passing the packaged worker's own no-Core/application check, not an independent
enumeration of every child application.

An external observer then killed a separate, witnessed parent BEAM after actual
protected readiness. Before the kill it recorded carrier ancestry and the guard's
PID, creation identity, group and executable; it proved that same independent
guard survived parent exit 137 and then removed the namespace and live group
members. Cleanup was observed after 121708 microseconds on current and 123080 on
floor. No normal stop frame supplied those outcomes. No credential, invocation or
provider call occurred in any of these package checks.

Canonical ready samples were 385720–389638 microseconds on current and
469661–503161 on floor; sampled worker RSS was approximately 103 MiB and
95–97 MiB respectively. These are individual local observations, not a benchmark,
new allowance or general deadline proof. Startup remains inside the invocation
deadline. Linux, active-transport whole-host death, live-provider behavior and
any later source/artifact are not proved by these runs.

Unsuccessful observer/prerequisite attempts were not counted as product evidence:
model lookup before dependency startup; a Darwin process-name mismatch in the RSS
sampler; an incorrect direct-parent assumption before fault injection; and a
current-toolchain Hex archive used under OTP 26. The corrected observers and
existing floor-specific Mix home resolved these. Pinned dependency warnings were
retained, not described as a warning-free complete gate. All VMs ended and no
owned worker/guard or invocation namespace remained.

The witness report and logs were retained during execution under
`/private/tmp/loopex-package-proof.MnbwrM`,
`/private/tmp/loopex-package-current.ntTuH8`, and
`/private/tmp/loopex-package-floor.V4duJT`. The parent-death observer digest is
`sha256:a8acae5c2e7cf4901bc54ca8cf69dd0dfb52a35815a465ac8f995f31838ae3fe`.
These temporary paths locate supporting execution material; this source-bound
summary does not make their continued existence a project prerequisite.

### Cross-boundary self-audit repairs — 2026-09-07

The broader ADR 0020 inspection found a production defect outside the earlier
handoff detectors: `Runtime.finish_attachment/4` waited for Dispatcher creation
but imposed an ordinary five-second timeout on Control's mutating finalization.
The caller could receive `runtime_unavailable` and the queued call could still
install the attachment afterward. A new regression observes the actual queued
finalization, holds Control beyond that timeout, and then requires the exact
attachment result, usable command routing and idempotent reattachment. Before
the repair it failed with `{:ok, {:error, :runtime_unavailable}}` in 5.7 seconds.
The finalization now waits for Control's actual result, as the accepted ADR
requires. The full 14-case session-lifecycle corpus passes in 21.3 seconds, seed
`3107`, with warnings-as-errors. This is focused working-tree repair evidence,
not a final exact-SHA gate result.

A separate preservation review found that the provider fixture wrote a literal
`POST` instead of the observed request method. `d8ba357` joins the support-only
repair: the fixture records `request.method`, and cases assert the actual value.
Independent comparison of the revised legacy-contract proposal confirmed all
twelve original names, the same two additions and unchanged earlier assertions,
with eleven added method assertions. The normal execution-approval path then
permitted applying that exact proposal. Formatting and its fourteen cases then
passed with warnings-as-errors, seed `3107`, in 36.2 seconds. The ten post-latch
failure modes, real socket/task cleanup, explicit IO refusal, queue ordering and
actual method observations all executed. No test name or locked minimum was
removed; the other legacy migrations are not silently treated as complete.

Three additional bridge cases exercise a refused second connection after actual
bootstrap, well-formed wrong nonce/build readiness before credential delivery,
and wrong invocation bindings at dispatch and terminal. All fourteen bridge
cases pass in 12.4 seconds, seed `3107`, with warnings-as-errors. This is the
bridge plus a deliberately controlled socket peer, not proof of actual child
producer backpressure or live-provider behavior. No gate minimum or selector
name was changed by these additions.

Two additive executor observations now exercise public `Local.execute` and
`Local.receipt` instead of inferring durability or preflight from source text.
They bind successful file opens to exact receipt paths, observe successful file
sync before rename and parent-directory sync afterward, and read back the public
receipt. They also observe an actual at-limit read and require zero target
open/read calls for an oversized input. Trace delivery uses acknowledged barriers
for exact processes and descendants, not a quiet-mailbox delay.

The isolated final two-case baseline passed with warnings-as-errors, seed `3107`.
Deleting only receipt-file sync and adding only an eager read before preflight
each failed its new behavioral assertion, while the corresponding existing
locked case still passed individually. These are selective detector results,
not whole-suite survivors: the sync deletion also produced a compiler warning.
The initial read observer missed current OTP's `read_file/2`; the final observer
traces both exported arities, and the eager-read mutation then failed. A temporary
path-alias setup error was fixed before that final baseline. No production repair
was required for these two gaps.

After joining at `2f11245`, both new cases and the existing first-image case passed
together (three cases, 1.8 seconds). The executor's universal direct-spawn
inventory was separately strengthened from line-layout matching to syntax nodes;
its exact existing selector passed (one case, 1.2 seconds). These are current
toolchain, credential-free working-tree results. The new observations do not
simulate a power failure, exercise the accepted path-race limitation, or claim
floor/whole-suite verification not yet run.

The three-file cold-provider fixture migration is joined through `893cebf`.
Its final independently owned source, `6a806548a7decb0b5283692d30c1fe3d535c24bb`,
passed formatting, automatic-root cleanup on missing offline input, a fresh
ordinary Mix build (4,768 ms, verified reuse 221 ms), and a fresh standalone
build without a Mix project stack (4,485 ms, reuse 239 ms). Both manifests bound
that exact source. The unchanged reference-client corpus passed 18 cases with
two real-provider exclusions, seed `3107`, in 3.6 seconds. No owned process
remained. Earlier first-image environment and closed-stdin observations passed
at `41f10aa`; they are not re-labelled as runs at the cleanup child. The helper
copies admitted offline inputs into the caller's owned root and invokes the
actual companion build; it does not replace a provider call. No live call or
joined whole-suite result is implied by these fixture checks.

The supplemental CLI accounting file exercises a real protected worker and
loopback HTTP response through the adapter, Core, durable replay and terminal
renderer. An overlarge raw reply must retain explicit `none` and charge the
remaining 256-token allowance as estimated. A raw-admissible tool reply whose
full settlement exceeds depth 12 must instead retain the exact compaction
provenance and reported usage 37 + 11; it dispatches no discarded tool. Both
cases require one observed authenticated POST, exact durable accounting, worker
cleanup, and absence of private provenance fields from public events, traced
coordinator diagnostics, conversation, stdout and stderr.

Those two working-tree cases passed in 3.4 seconds, seed `3107`, with
warnings-as-errors after joining HTTP-body support at `41b3691`. The initial
observer used a string `kind` instead of the Store record's atom key and
captured stdout alone while failures render on stderr; that setup failed and
was corrected before the passing result. No production byte changed to satisfy
either case. This is synthetic-transport boundary evidence, not live-provider,
floor, final-source, or full-suite evidence. The original credential-plane
corpus remains untouched while its separately preserved draft is verified.

The subsequent test-honesty read identified a label-only privacy assertion:
removing the provenance map's `kind` could leave its other fields undetected.
The cases now require no diagnostic for these two ordinary failed runs and also
exclude the provenance members from the observed planes. The stronger pair
passed in 3.6 seconds. This integrated test does not independently locate the
raw-refusal guard: Worker and Core both perform admission. Removing only one
guard is not a proved survivor or kill here; do not credit the test as a
mutation of that specific site.

### Credential corpus migration preservation

The independently reviewed draft was subsequently applied through the normal
execution-approval path. Its 24 cases first passed separately in 54.4 seconds,
seed `3107`. The original SHA-256 was
`ec42519c38b146a23ed242682fbf2525da04185a45450c55897bbb4cc14d2a0a`;
the applied draft was
`1cf3990bb1d7b4b5087d7de4b224c5cbf124652a8dee7f1dc5cf96724987db75`.
No locked selector, minimum, real-provider tag or accepted artifact changed.
The original explicit-value scrubbing tests remain separate and unchanged.

The map below retains the original local case names; C01–C24 are adjacent
markers in the new corpus. Existing describe prefixes remain. Names asserting
retired registry or redaction behavior are replaced with truthful operational
names, not preserved as false compatibility claims.

| ID | Original local case name | Surviving observation |
| --- | --- | --- |
| C01 | `a progress function that throws ends the drain as a bounded interruption` | Same category and binary bound, fixed safe failure detail |
| C02 | `a progress function that exits ends the drain as a bounded interruption` | Separate exit path with the same bound |
| C03 | `a provider error echoing the key is substituted before it is returned` | Fixed failure independent of ambient-key rotation/removal |
| C04 | `the credential registry is supervised and an inactive restart recovers` | Actual parent supervisor restart, independent child and usable host logs/group leaders |
| C05 | `an inactive credential filter never waits on the registry` | Host logging succeeds while actual provider bootstrap is held |
| C06 | `the credential registry protocol never returns active credentials` | Actual guardian traffic through cleanup, with an acknowledged trace-delivery barrier |
| C07 | `credential generations reject stale events and retain overlapping leases` | Wrong control cannot stop another retained invocation |
| C08 | `metadata redaction replaces every occurrence in one binary` | Repeated key in actual child metadata remains private |
| C09 | `nested metadata map keys are redacted` | A credential used as a nested metadata key remains private |
| C10 | `one event redacts every distinct overlapping live credential` | Two concurrently live synthetic keys in one actual child event |
| C11 | `owner loss retains its credential until the lease is explicitly released` | Abrupt callback loss does not release a different live retainer |
| C12 | `missing activity state stops a logger event` | Actual protected sink loss, exact killed witness and contained failure |
| C13 | `registry loss with an active lease poisons logging and provider admission` | Failed child cannot poison sibling work or host logging |
| C14 | `post-transfer filter conflict refuses credential acquisition` | Actual invalid bootstrap refuses disclosure and dispatch |
| C15 | `a transfer timeout is cancelled when the delayed capsule reaches the registry` | Expired delayed entry cannot later disclose or relaunch |
| C16 | `provider IO isolation restores only after the last credential is released` | Cleaning one child cannot release the other's direct/supervised IO protection |
| C17 | `a transport raise after environment rotation is redacted by the real logger pipeline` | Actual request-key-bearing raise after child environment rotation |
| C18 | `ordinary and split logger messages redact every active credential` | Actual ordinary and split child Logger inputs remain private |
| C19 | `all Logger message forms and metadata use the active credential registry` | Actual string/chardata, format/args and report/metadata inputs |
| C20 | `a provider request adapter that throws cannot put the credential in a stream-server crash report` | Actual throw, StreamServer termination and bounded failure |
| C21 | `a provider request adapter that exits cannot put the credential in a stream-server crash report` | Separately executed exit and termination path |
| C22 | `the crash-report filter retains diagnostics and redacts the event's own credential` | Actual report containing its own request credential remains private |
| C23 | `the filter redacts an actual stream-server termination event` | Exact actual StreamServer and abnormal entry death, not a fabricated report |
| C24 | `a conflicting credential filter refuses before provider transport` | Unrelated host filter remains unchanged and has no isolated-provider admission authority |

ADR 0019 expressly retires five mechanisms/representations: parent-global
filter and group-leader ownership; host-visible rewritten raw diagnostics;
registry/ETS credential transfer; callback-owned rather than retaining-owner
lifetime; and node-global poisoned admission/logging. The operational
guarantees above are not waived. In particular C13/C24 now assert independence,
not the opposite historical behavior.

The initial draft run passed 20 of 24 cases but failed four fault witnesses.
Those failures exposed observer teardown, not evidence of successful
containment. The final fault fixtures monitor the real worker entry without
altering its production links, install observers before explicit fault release,
and require exact sink/StreamServer and abnormal worker death within the
original remaining request deadline. A suspended guardian is resumed in
`after`; no replacement result or cleanup acknowledgement is supplied. The
observer exports bounded booleans, never the raw child exit reason it observes.
The final preservation review and successful draft execution are distinct
evidence; neither supplies independent release acceptance.

The joined provider application then passed 132 cases with one real-provider
exclusion, seed `3107`, in 129.8 seconds; the ordinary application-level
`mix test --seed 3107 --warnings-as-errors` command exited 0. Credentials were
unset. The preceding explicit-directory run had also passed 132 cases, but
exited 1 because current Mix warned about the two new `.exs` support modules.
That earlier execution is not recorded as green. The application now names
exactly those two explicitly required helpers in `test_ignore_filters`; no
`*_test.exs`, case, selector, tag, or test policy is excluded by this repair,
and warnings-as-errors remains enabled. The passing result includes the applied
credential migration, the real-entry cleanup-expiry case, and the pre-existing
retainer-death cases. It is neither a live-provider nor a whole-suite result.

### Restored complete-report reconciliation — 2026-09-07

The restored `FF17990-REVIEW.md` was read completely, including its medium
findings, previously sound areas and exclusions. Its SHA-256 is
`59daf51280a1bebc88bf43c305a0103dfb9a2221800fc635f866c48df59a989c`.
It reviews exact `ff17990453426e129cf0b3f1895ae936f64ff875` against
`3a729b08ff0ce9f14bca1ef64da04ee96879ac2b`. The external file is not
repository authority. The following map keeps the complete follow-through
visible without projecting this branch's results onto its historical source.

| Original item | Follow-through and remaining proof |
| --- | --- |
| 1 — authority/evidence does not cover the candidate | ADRs 0019–0021 and the current implementation task authorize these repairs, not integration of an unseen candidate. Override 21 and old attestations remain historical. Final clean source `S`, new three-role provider evidence/account verification, evidence-only child `E`, and exact-SHA independent review are still required. No older gate result supplies that evidence. |
| 2 — host Logger/IO takeover | ADR 0019's isolated companion replaces the parent-global filter, registry and group-leader ownership. Actual-entry tests exercise host logging, parallel independent invocations, startup failure and child diagnostic containment. The joined 132-case application result and earlier exact-package results above are scoped to their named sources. Backpressure and final-source live/package qualification remain explicit work, not inferred from isolation's architecture. |
| 3 — guardian survives its retaining owner | Managed cleanup now follows the actual retaining lifetime guard through the post-result wait. Tests distinguish callback return from retainer death and require the genuine guardian/child/namespace to end. The unmanaged cleanup-expiry case also reaches the real entry. Final joined verification remains required. |
| 4 — hidden public handoff and unused replacement | ADR 0020 introduces explicit `transfer_resume/3`; ordinary `/2` no longer selects behavior from CLI process state. Duplicate initial installation refuses atomically, with no handler-replacement/drain system or global drain lock. The remaining private provider lifetime registrar is invocation-local resource bookkeeping under ADR 0019, not a selector for public transfer. A newly exposed idempotent-abandonment caller check is repaired and described below. |
| 5 — accounting contradiction and permissive recovery | ADR 0021's versioned retained provenance distinguishes raw refusal from validated settlement compaction. The additive ADR disposition corrects the historical conservative-rule misstatement without rewriting override 21. Production replay validates provenance against accounting; actual Store old-reader control/refusal and protected-provider-to-Core/renderer cases are described above. Final-source rollback evidence is not yet supplied. |
| 6 — tests overclaim observations | Replacement-only lexical and short-silence verdict tests were removed with that retired behavior. Actual HTTP request counting and retry-path observations now supplement the option assertion. Receipt preparation's lexical-order assertion was replaced at `da75851` with real execute-process call/return observation. Unconfirmed untrappable-worker-stop branches retain explicitly labelled structural and pure-result checks; these do not claim a real BEAM process survived `:kill`. Adjacent real lease/bound/owner-loss cases remain separate behavioral evidence. The historical wide deadline case did not kill the reviewer's final-clock mutation; the exact-equality case did. No broader mutation claim is carried forward. |
| 7a — independent caller timeouts over admission | `950fb08` removes the unrelated reserve/permit observation ceilings, retaining job/admission/cancellation authority deadlines. Real queued/held-handler tests distinguish waiting for the decision from a caller timing out while it continues. Both pass in the 161-case executor lane at `a99db63`. This is not a bound on a permanently stalled filesystem. |
| 7b — unsupported holder liveness can crash Local | `8336403` checks the holder's local PID domain before calling `Process.alive?/1`. Ordinary simultaneous local-holder execution remains covered without claiming distributed execution. The owning clone's safe regression batch passes 30 cases, and the joined 161-case executor lane passes at `a99db63`. |
| 7c — host materializes secret-bearing provider options | Normal execution constructs options in the protected child after private credential delivery. Exported `call_options/3` remains callable and returns secret-bearing data to its explicit caller; the compatibility inventory now states that responsibility rather than implying the helper itself protects the caller. |
| 7d — prepared installer death diverges from documented state | The initial preparation holder is monitored. The joined full suite exposed a further same-state acknowledgement to a different caller; an ordered real-runtime regression now proves holder loss is processed before that call, and the caller-specific idempotence repair preserves the rightful holder's repeated acknowledgement. |
| 7e — already-spent permit still pages Store | The pure exact-spent-binding check now precedes the bounded Store read. The existing protected case positively witnesses the real Store read protocol and then requires no read for the duplicate, after a trace-delivery barrier. Original ordering fails that assertion; repaired ordering passes. |
| 8 — undeclared surfaces and liveness overclaim | The compatibility inventory now names trusted-local clock/removal options, native placement authority, exported hidden test-support arities, concrete error families and `call_options/3`. The honest liveness claim is refusal after loss is observed, not atomic knowledge of every later death. Generic response IDs preserve optional nonempty UTF-8 bytes up to 256 bytes; the historical `req_` attestation dialect is a narrower evidence requirement, not the Model callback domain. No generic identifier normalization is introduced. |
| Fourth-audit minor docs | `install_prepared/3` and the inventory distinguish setup errors, handoff refusals and unresolved answers. The operator Store guidance states the exact same-VM dead-owner exception. Usage guidance now rejects extra keys with the whole reply instead of claiming they canonicalize to unreported usage. |

The complete report's excluded areas are not automatically covered by running
tests. The independent release reviewer still owns a fresh content review of
the large agent-loop/prepared corpus and the Ledger/WorkspaceLease boundary.
The reference fixture now actually builds and validates a same-source companion
from a cold clone; its deterministic cases and current/floor package evidence
are recorded above. That closes a configuration uncertainty, not all possible
reference-client defects. No external provider-account lookup was performed in
this reconciliation pass.

### First joined whole-suite result and focused repairs

At clean `50191d5c74b8ee343061caeada1037053bd4c3b0`, current-toolchain
test-environment force compilation with warnings-as-errors passed. The serial
whole suite, seed `3107`, with all three provider-key variables unset, then
exited 2: **1,019 passed, two failed, five real-provider cases excluded**.
By application: protocol 12; Core 524 passed and two failed; provider 132 and
one excluded; Store 41; executor 158; composition 13; reference 18 and two
excluded; CLI 121 and two excluded. It is not recorded as a green source.

The first failure was the dead-preparer abandonment assertion. Its former
preparer exit had no ordering witness for the coordinator's own monitor. The
strengthened case waits for the actual `prepared_holder_down` receive and a
subsequent state barrier. Its initial observer used the wrong monitor-message
shape and failed at setup; correcting that observer produced the substantive
failure: a different caller received `:ok` from the abandoned state's
idempotent branch. Restricting that acknowledgement to the recorded holder
fixes it. The ordered Core case and the late-reply case below pass together;
the CLI case separately proves repeated same-holder abandonment succeeds while
another caller is refused.

The second failure was a stale expected `none` provenance in the oversized
valid late-reply case. The case now independently measures the actual complete
settlement, requires its exact compaction provenance and retained reported
usage, and preserves abort precedence and bounded record assertions. This is
conformance to accepted ADR 0021, not an accounting policy change.

The receipt-preparation ordering case now runs both real effects through
`Local.execute`, requires their actual file bytes and completed receipts, and
observes private call/return events in the executing process. Its trace-delivery
barrier precedes every negative ordering assertion; it no longer reads source
text. The joined working-tree case passes in 0.4 seconds, seed `3107`. This is
an execution-order observation, not a slow-filesystem simulation or a new
timing budget. The unreachable untrappable-stop qualification above remains.

The duplicate-permit regression uses a positive real Store page witness before
tracing the exact repeated binding. Its strengthened assertion fails with the
old read-before-spent ordering (2.5 seconds) and passes after the two checks are
reordered (2.3 seconds). The other ownership, position, worker and deadline
checks remain in place. These focused greens do not substitute for the next
clean whole-suite and gate run.

### Joined medium repairs and provider backpressure

The safe holder-domain repair joined at `8336403` with ordinary local-holder
preservation coverage. The two independent caller observation ceilings were
removed at `950fb08`. Its two controlled public `Local.execute` cases first
failed at the original 10/15-second `GenServer.call` timeouts (25.1 seconds,
seed `3107`), then both passed in 25.1 seconds after the repair. The separate
ordinary executor corpus passed 29 cases in 18.9 seconds. Formatting and
warnings-as-errors compilation passed in the owning clone. Actual job and
cleanup authority bounds did not change; the tests do not reproduce a slow
filesystem or promise a response from an indefinitely stalled host kernel.

Provider backpressure checkpoints joined at `e5bf3cd` and `b4968ce`. The actual
worker first fills its driver buffer, then its real writer blocks, while the
ReqLLM producer completes 513 deltas and the full 33,280-byte reply. The test
requires one pending delta and notification plus the independent terminal;
after releasing the receiver, the complete reply and producer count survive.
Replacing the slot's insert-once operation with replacement made the assertion
observe 511 queued notifications rather than one. Restoring exact production
bytes restored the green baseline; this is a focused regression demonstration,
not a whole-suite survivor claim.

The three-case file also proves a committed deadline cleans up while the writer
is blocked, and channel destruction after an admitted delta cannot turn the
queued full reply into a successful short reply. All three passed in 13.2
seconds with seed `3107`, formatting and warnings-as-errors compilation. Stop
requests use the already captured absolute cleanup/observation deadlines; no
fresh post-result allowance or fabricated protocol reply supplies the proof.
The channel-loss case does not claim deliberate byte truncation of a terminal
already on the wire. These are real-worker, synthetic-HTTP observations, not
live-provider or self-contained-package evidence.

The restored-report self-audit additionally identified two narrower lifetime
schedules needing positive witnesses: retainer death during credential transfer
and after OS cleanup actually begins. Existing tests covered deadline during
credential transfer and terminal-before-retainer ordering, respectively, not
those exact schedules. Supplementary cases are being prepared; they are not
counted as passing evidence here. Provider-specific failed-process-inspection
and final-source required-platform qualification also remain explicit evidence
work. The local Docker runtime is installed but was not running at inspection;
that read-only check is unavailable Linux execution evidence, not a Linux pass.

### Second joined whole-suite result and remaining lifetime witnesses

At clean, pushed `a99db63e46dccd509458126436d0333166c889c7`, force compilation
of all eight applications with warnings-as-errors passed. The serial whole
suite, seed `3107`, with `LOOPEX_PROVIDER_API_KEY`, `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY` and `TIDEWAVE_REPL` unset, exited 2: **1,027 passed, one failed,
five real-provider cases excluded**. By application: protocol 12; Core 526;
provider 135 passed, one failed and one excluded; Store 41; executor 161;
composition 13; reference 18 and two excluded; CLI 121 and two excluded.
The two failures at `50191d5` are absent. This run is not a green source.

The remaining failure is `a blocked progress consumer cannot queue data or
delay cleanup` in `provider_bridge_test.exs`. After cleanup the expected
successful 10,000-delta reply instead returned the conservative
`dispatched_or_unknown` classification. The child's terminal marker records its
socket send/close, not admission of the terminal by the host guardian. Issuing
Core stop at that marker can stop the receiver while frames are still in
transit. A focused original-seed diagnostic passed; that disappearing failure
does not clear the original run. The repair must establish host-side terminal
admission before the case demands successful-result preservation, without
changing its request, cleanup or observation bounds. Its actual changed-case
focused result passed in 0.5 seconds, seed `3107`, and the repair joined at
`d3a39ac`. The exact 10,000-delta successful reply and at-most-two queued
messages remain required. This focused result does not replace the next
joined-suite check.

The actual-cleanup retainer-loss witness joined at `a99db63`. It establishes
automatic OS cleanup by observing namespace removal while the actual child is
still stopped and alive, then loses the retainer. After the child resumes it
requires the genuine correlated cleanup acknowledgement and normal guardian
exit. There is no competing Core stop request that could independently end
the wait. The case passed individually in 10.3 seconds and in this whole-suite
provider lane. It does not supply the separate credential-transfer schedule.

The credential-transfer witness joined at `05abb07`; its first focused baseline
passed in 1.1 seconds, seed `3107`, with formatting and warnings-as-errors
compilation. A test-local observer pauses the real worker entry before its
credential receive, after the genuine ready frame. The case establishes actual
socket pending bytes and a real raw writer blocked in `ProviderCodec.send`,
then loses the retainer. The blocked sender is classified from its actual
stack as the credential or invocation writer; driver buffering is not
mislabelled as a blocked credential send. The result is ambiguous, both raw
helpers die, the guard supplies actual cleanup proof, and no HTTP call occurs.
No private protocol frame or cleanup acknowledgement is fabricated.

A real two-runtime/adapter-lifecycle isolation witness is being checked in its
own clone; it is not yet counted as joined evidence. The required Linux host
`serenity` was unreachable with a
bounded, non-interactive SSH check (connection timeout). No Linux check passed,
and no remote state changed. Final-source packaged current/floor/platform,
live-provider/account, rollback and independent review remain required.

### Third joined whole suite and restored-report content audit

At clean, pushed `47948df3253171d74ee7fa591fcc2bdcbc7db38b`, test-environment
force compilation of all eight applications with warnings-as-errors passed.
The serial whole suite, seed `3107`, then exited 0: **1,031 passed, zero failed,
five real-provider cases excluded**. Application counts were protocol 12,
Core 526, provider 138 plus one excluded, Store 41, executor 161, composition
13, reference 18 plus two excluded, and CLI 122 plus two excluded. All three
provider credential variables and `TIDEWAVE_REPL` were unset. This run resolves
the two preceding whole-suite failures on their repaired source; it does not
erase those failures or claim that the source stayed unchanged afterwards.

The real two-runtime witness at `314b4bc` holds both actual protected entries
before HTTP, fails one invocation, and then completes and replays the other.
It observes host Logger configuration, ordinary logs and unrelated group
leaders across adapter start/stop. It does not claim simultaneous active HTTP.
The actual pre-entry crash witness at `47948df` first establishes a successful
worker/HTTP positive control for its credential-read observer, then requires
zero credential reads and transports after a child exits before entry. Both
cases pass in the joined suite. Neither is a direct observation of the first
OS image's complete environment or final-source live-provider evidence.

The restored report's omitted Ledger and WorkspaceLease bodies were read,
along with the reference-client fixture changes and the changed high-risk
agent-loop/prepared-recovery cases. The reference's real session still binds
exact request/result identities and file effects; its recovery fixture still
uses an untrappable runtime-tree kill and retained receipts without redispatch.
The real loopback 429 server counts received HTTP requests and continues
accepting requests: it is separate evidence from the injected retry callback
and option-literal checks. This was a self-audit, not an independent release
review or an exhaustive assertion about every line of the large corpora.

That content audit found a test-witness gap: the malformed receipt case's
cancellation fixture could release its worker before cleanup reserved the
result, allowing the ordinary result path to satisfy the assertions. The
test-only repair joined at `810f44c`. It suspends the real worker, observes
the cancellation answer and its exact abort reserve, then positively observes
that worker's bound malformed receipt in the coordinator's mailbox before
adoption resumes. Every original outcome/closure/record assertion, selector
name and timing bound remains. Its clean worker commit
`5d7bc2f54929b4afb5b385726b0c0d08de2e2d1c` passes the focused case in 3.2
seconds with seed `3107`, formatting and force compilation with
warnings-as-errors. The proposed production mutation was refused by action
review before any write; it was not executed or retried. No mutation kill,
survivor or product defect is inferred from that unavailable experiment.

Native Linux qualification is in progress. The first AMD64 toolchain preflight
failed in the Docker-on-ARM Rosetta path before any Loopex process ran. Native
ARM64 sibling images preserve the exact accepted pair and avoid changing JIT
protection; metadata and a prepared build do not count as a Linux pass.
The authenticated provider account now renders request-log rows, removing the
previous UI-access obstacle. No final-source account verification or new live
attestation is claimed yet. Package/platform, rollback, live/gate and final
evidence-child verification remain the next execution work.

### Native shell qualification and the resulting portability repair

Native ARM64 Linux qualification exposed two genuine cleanup defects shared by
the provider and executor guards. Ubuntu dash rejects `kill -TERM -- -PGID`,
and its command-substitution job table is empty even while a child remains
alive. Thus the former could fail to signal the owned group, while the latter
could mistake a trapped, interrupted wait for child completion. Darwin passing
those paths did not establish Linux conformance. The initial cooperative
control exceeded its existing bound; after the signal-only repair, a second
control exited 137 without acknowledgement. Neither is passing evidence.

The repair joined at `4b3d9b6` uses the live shell's builtin
`kill -s SIGNAL -- -PGID` and a same-shell trapped-interruption flag. A final
status at or below 128 wins even beside a trap; an untrapped signal exit remains
final. No numeric-PID liveness sample, external signalling helper, new option,
authority, timer, protocol or gate change was introduced. The existing
structural assertions now name that syntax and wait algorithm; their test name,
behavioral assertions, count and bounds are unchanged. This structural check
remains distinct from actual process evidence.

The clean worker checkpoint
`3eda863f2fcd865f7a7d6e1bd65f80c895120a72` passed formatting, forced
warnings-as-errors compilation, four provider launcher and eight executor
cases on Darwin, and the same four provider launcher cases on native Linux,
all with seed `3107`. The exact launcher SHA256 is
`c90fd6c468dad6549f3540c7f1ca56039fd9a5037aba1227e28303cb4912655b`;
executor SHA256 is
`e9477cbbd23fdb658d6092542c579075d2b9240722a76c9770443f0ad4b73bf5`.

A separate actual-guard control received one correlated cleanup acknowledgement,
exit 0 and Port DOWN, with an empty owned group and removed namespace in 9 ms.
The fault removed execute permission only from the owned Linux container's
original `/bin/ps` target. Its inode and digest stayed fixed, other helpers
were unchanged, literal execution returned EACCES, and a digest-identical copied
observer could still inspect the owned processes. That run received no cleanup
acknowledgement through actual exit 137 and Port DOWN; its owned group was empty
and namespace absent after 2,012 ms, within the unchanged 2,000 ms cooperative
period plus 100 ms observation allowance. Original ps permissions and identity
were restored and execution succeeded. Timeout alone was not read as cleanup.

This ran on native Linux ARM64, Elixir 1.20.3 / OTP 29.0.5 / ERTS 17.0.5,
using image
`sha256:85f03f17afa2e4c30445d9d461d176e7ef980f5cba7b1c3089a179d52a9381e0`,
without a JIT workaround. It exercised the actual launcher and a cooperative
shell worker, not the packaged companion, ReqLLM transport or live provider.
Native executor-app, final joined suite, package/floor, live-provider/account
and rollback evidence remain separate pending checks. The failed AMD64
Rosetta preflight and intermediate native failures are retained, not replaced
by these narrower successes.

### Cleanup watchdog follow-through before final qualification

Read-only follow-through of the portability repair identified two further
provider-guard defects. Generic termination could disarm the cleanup timer
before quiescence, and namespace-helper failure could fall through to an
acknowledgement when its timer wait was interrupted. Both were reproduced:
the first left the owned group alive past the unchanged observation bound;
the second emitted a cleanup acknowledgement and exit 0 while an owned
namespace obstacle remained. Neither result is treated as passing evidence.

The repair joined at `a6187c7`. Only an established quiescent birth group may
cancel its timer using USR1; generic termination does not cancel it. The
quiescence check also requires a live, non-zombie direct child of the timer in
the same group. The timer installs its cancellation handler before spawning
that child, so this observation establishes readiness without a new protocol
channel. Namespace failure now exits unproved regardless of interruption.
Signals retain the live birth-group authority, and all existing command,
cleanup and observation bounds remain unchanged.

The final follow-through at `cfcd02c` ignores generic termination before the
timer fork, preserves that inherited disposition in the timer and sleeper,
and restores interruption handling in the owning guard after capturing the
timer identity. A structural case pins this executable-script ordering. A
separate shell-conformance case pauses before handler installation and across
child execution, sends actual group signals, and requires actual reaping. It
does not claim to pause the production launcher at its precise fork boundary.
The read-only follow-through found no remaining concrete issue in these two
changed files; this is self-audit, not independent acceptance.

The final launcher bytes have SHA256
`bb62b118fc1d01a30d4b3a83ae28b7a1911577c68a6d34a30a03af1608134f39`.
All eight launcher cases passed serially with seed `3107` on Darwin in 5.3
seconds and on the native Linux image above in 4.9 seconds. Formatting and
standalone warnings-as-errors compilation also passed. The first native
eight-case run failed because the new shell fixture let an asynchronous
child inherit `/dev/null` as stdin. Capturing its input descriptor before
fork repaired that fixture; its failed result is retained separately from
the corrected run. No test name, gate minimum, or locked artifact changed.

With those final launcher bytes, the actual native guard control produced
one correlated acknowledgement, exit 0, Port DOWN, an empty owned group and
removed namespace in 11 ms. Removing execute permission from only the
container's original ps target produced no acknowledgement, exit 137, Port
DOWN, an empty group and removed namespace in 2,017 ms, within the unchanged
2,000 ms cooperative period plus 100 ms observation allowance. The original
ps inode and digest, and every other helper identity, were unchanged; ps
permissions were restored and execution succeeded. These are launcher-only,
synthetic-worker observations, not packaged or live-provider evidence.

The provisional current-pair package at `ef463e0` passed archive identity,
outside startup, copied CLI, separate FD observation and parent-death checks.
Its first build failed before product compilation because the isolated task
environment omitted HOME; preserving the existing HOME fixed that environment.
That changed-environment, incremental result is not a cold-build proof and
does not qualify these later source bytes. Final-source current/floor/native
package, whole-suite, live gate/account and rollback checks remain outstanding.

### Floor-format compatibility at the next qualification checkpoint

At clean `b994bc039afcd018b5b02af2d169aa4d8a6fb2a1`, the current-pair cold
CLI/companion build and all seven subsequent format/archive/outside/descriptor/
copied-CLI/parent-death commands exited 0. The exact floor-pair cold build also
exited 0. Its whole-repository format check then exited 1: Elixir 1.17.0 formats
the compact `if Enum.all?(...)` expression in `ProviderWorker` differently from
Elixir 1.20.3. No later floor witness was run, and no floor-lane pass is claimed.

The expression now uses the ordinary `do`/`else` block with the same condition
and `:ok`/`:error` branches. Both exact supported toolchains' whole-repository
`mix format --check-formatted` commands exit 0 on that repair. These are focused
format results, not a qualification of the next source's package or runtime.
The preceding successful packages and failed floor formatting remain bound to
`b994bc0`; final qualification must use the new clean source throughout.

### Qualification at 7d1cdde: Darwin passes; Linux executor blocks release

The next clean, pushed source was
`7d1cdde971221bc86972012cfe86198a4c4d87a8`. This is a qualification
checkpoint, **not a release-review candidate**. No product, gate, accepted ADR,
or lifecycle change is carried by this evidence update.

On Darwin current (Elixir 1.20.3 / OTP 29.0.5), forced product compilation with
warnings-as-errors, format, status, dependency budget, core-only isolation,
formatter scope, compiled documentation, bootstrap and commit-message checks
passed. Bootstrap passed 68 cases. The serial credential-free whole suite,
seed `3107`, ran from 2026-09-08T00:56:18Z to 2026-09-08T01:11:21Z and exited
0: **1,035 passed, zero failed, five real-provider cases excluded**. Its output
SHA256 is
`148a99909d26adfd3b59bccca37c4fc3b945c441e67aaa2d3eea5f5178793ee0`.
No live-provider or account evidence is inferred from that run.

Both Darwin package lanes, current and floor (Elixir 1.17.0 / OTP 26.0),
passed all nine phases each: format, forced compilation, actual paired build,
archive identity, two canonical outside-checkout startup checks, separate
descriptor observation, copied CLI execution, and owned parent-death cleanup.
These were forced incremental rebuilds using preserved dependency caches, not
new cold-build claims. The full report and phase records are retained at
`/private/tmp/loopex-final-package-proof.nAfHeO/PACKAGE-7d1cdde.md`.

The first native Linux run stopped before product compilation. macOS tar had
generated AppleDouble metadata entries which GNU tar extracted as extra
dependency application files. The original archive and failed run remain at
`/private/tmp/loopex-final-linux-package.2StorO/run-7d1cdde`. A separate archive
disabled macOS metadata; before compilation its native reader refused any
AppleDouble entry and verified all 878 regular-file payload hashes against the
original inputs. No dependency or product source was changed by that correction.

The corrected run used the native ARM64 image recorded above, the exact current
toolchain, no network or credential, and the image's actual `ubuntu` account
(UID 1000). Running non-root preserved the meaning of permission-refusal cases.
Product compilation, package/archive checks, three outside-checkout runs, copied
CLI execution and all eight provider-launcher cases passed. The ordinary full
executor application suite then **failed: 91 of 161 passed, 70 failed, exit 2**,
seed `3107`, in 239.1 seconds. Failures included commands refused before launch
admission and bounded helpers returning `:no_answer`. This is a product failure,
not a sandbox refusal, disappearing retry, or passing qualification. Output is
retained in `run-7d1cdde-portable/logs/executor.log` under the same task root,
SHA256 `12cf7f841ed9fcc586be3db770180d294d718f50fe5fbefd78bb7415b1c9e5ba`.

Research-only probes independently established two noninteractive Linux shell
mechanisms behind those failures. With the supplied control frame, dash's
background `<&0` launch reads EOF; capturing the descriptor before fork preserves
the frame. Separately, dash's `set -m` returns zero but reports that job control
is disabled without a terminal: the helper guard remains in its carrier's
process group. The helper cleanup design requires a distinct guard group so
the carrier survives helper KILL to relay authenticated acknowledgement and
exit. An input-only repair therefore cannot preserve that design on this shell.
Darwin's existing shell passed both corresponding mechanism probes.

Fixed `/bin/bash` as the internal carrier and guard passed the native mechanism
probe: the guard had its own process group, received the exact control frame,
and its raw `/bin/sh` command joined that guard group. This proves a mechanism,
not a repaired production executor or cleanup result. Exact scripts, observations
and limits are retained at
`/private/tmp/loopex-executor-shell-portability.86bziR/PROBE-EVIDENCE.md`.

The proposed decision is to require `/bin/bash` only for the reference local
executor's internal supervision scripts, keeping raw `/bin/sh` command semantics
and leaving Core and third-party executors independent. This is recommended
because it preserves the current ownership/protocol with the smallest tested
mechanism change, but adds a product runtime prerequisite. A POSIX-only solution
needs a different, separately qualified process-group launcher; sharing the
helper/carrier group instead requires redesigning acknowledgement and cleanup
ordering. Restricting the release to Darwin would defer the Linux defect and
requires explicit scope/coverage disposition. None of those alternatives is
accepted here. Bash in the development prerequisites does not establish it as
a product runtime dependency. The ADR procedure pauses dependent implementation
for the maintainer's choice; no gate weakening or platform waiver is inferred.

After that choice, the affected executor path needs focused and full native and
Darwin verification before selecting a new final source. Literal live and
inherited gates, provider-account lookup, real old-reader rollback and the final
evidence-only review child remain outstanding. The successful Darwin results
above are not back-projected onto a later source or presented as Linux evidence.
