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

The existing repair authorization remains the task scope. Historical override
21 continues to describe its original range; this follow-up neither extends
its accepted baseline nor authorizes integration, publication, or a version tag.

### Repair directions and remaining decisions

| Decision | Recommended direction | Alternative and consequence |
| --- | --- | --- |
| Provider credentials and diagnostics | Make protection explicitly host-owned. Adapter application startup must not modify the host logger or shared ReqLLM process group leaders. The reference composition selects protection explicitly; failed protection refuses provider admission and has a tested recovery path. Same-VM ReqLLM users share the host's chosen diagnostic policy. | A separate provider process isolates credential-bearing ReqLLM work, diagnostics, and IO from the host VM's logging machinery. It gives a stronger embedding boundary but adds framing, startup, packaging, cancellation, and real-provider proof. A dependency change would need owned task supervision and safe diagnostics, not just a new supervisor option. |
| Prepared recovery handoff | Make the lifetime participant explicit on the public transfer boundary, retaining the ordinary two-argument call. Remove unused dynamic handler replacement and refuse duplicate initial installation atomically. | Ordinary transfer with a CLI-only guard is smaller, but cannot independently observe idle coordinator death through today's facade. That option must explicitly narrow immediate dependent-holder cleanup. Keeping replacement retains a state machine with no command caller and requires bounded, behaviorally proved draining. |
| Compacted provider accounting | Preserve ADR 0018's distinction. Malformed or pre-validation unreadable replies use estimated remaining allowance. A validated reply compacted only because its settlement cannot fit preserves reported usage. Introduce versioned retained provenance so replay can validate which case occurred and the exact retained usage. | Estimating every unreadable result is smaller but supersedes ADR 0018 combination 5 and loses known reported figures. Retaining today's permissive validator leaves the accounting claim without retained provenance. |

On 2026-09-06 the maintainer approved these three recommended directions for
preparing decision proposals. That confirmation does not accept an ADR, extend
override 21, or authorize integration or publication. The contracts below
remain subject to exact-candidate review and explicit acceptance.

These are approved proposal directions, not accepted architecture decisions.
Their exact contracts, compatibility, recovery, and rollback need proposals before
dependent implementation. In particular, explicit host ownership alone does
not resolve the logger failure mode: the proposal must establish how the host
continues safe diagnostics and recovers protection when the registry or ReqLLM
supervision restarts.

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

The concrete proposals are [ADR 0020](../adr/0020-explicit-prepared-handoff.md#concept)
and [ADR 0021](../adr/0021-compacted-provider-accounting-provenance.md#concept).
Both remain Proposed with empty governance rows. ADR 0021 makes one operator
cost explicit for acceptance review: an old unreadable-plus-reported settlement
has no recoverable usage provenance, so the new reader refuses that session
rather than rewriting accounting. These proposals supply no executed conformance
claim. No product, accepted ADR, plan, gate, or lifecycle bytes move with them.

<a id="provider-protection-choice"></a>
### Provider protection: one additional ownership choice

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

### Completion order

Current checkpoint: the guardian repair is committed at
`6fab2f8c117b9618c204ef87324a9c64e21c9fe5`. ADRs 0020 and 0021 are Proposed;
0019 is reserved pending the provider-protection choice above. Dependent
architecture implementation and final source-bound evidence have not begun.

1. Repair the orphaned guardian and test active-call, post-result, and
   descendant-cleanup owner loss.
2. Settle the three directions above and accept the required ADR proposals.
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
No real credential was needed. Architecture decisions and final source-bound
gate, live-provider, and provider-account evidence remain outstanding.

Before committing the repair, serial repository checks also passed:
`mix format --check-formatted`,
`MIX_ENV=test mix compile --force --warnings-as-errors`,
`mix loopex.docs_check` (611 covered entries), and `mix loopex.status`.
These checks do not stand in for the still-outstanding final gate and review.
