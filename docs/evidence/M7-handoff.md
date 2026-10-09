# M7 handoff checkpoint, 2026-10-09

Part of the [evidence index](README.md). This is the current takeover runbook
and evidence record. It does not accept an ADR, close M7 or authorize publication.

## Concept

The maintainer asks to save all work, commit and push `m7`, then pause this
chat's active goal so another agent can take over. Continue the accepted M7
implementation in `/Users/spuri/projects/lexlapax/loopex` on branch `m7`.
The goal is complete implementation with required tests passing and exact
outcome evidence. Keep the supplied T00–T19 checklist, report original and added
counts separately, and commit/push bounded completed units. Do not replace the
checklist or add small rows just to make the completed count rise.

The delivery has taken too long. Narrow component proofs and repeated fixture,
review and checkpoint work have outpaced integrated outcome completion. The
next lead should prioritize complete workflows and existing rows, keep one
integrator, and use parallel agents only for independent owned work. The new
lead should reassess sequencing; no elapsed-time promise is supported.

Only T01, T02 and T10 are fully complete. T09's original checklist is complete
but one added transport join remains. M7 remains In progress. No checkbox changes
at this checkpoint. T01–T19 totals are **89 original done / 84 open / 6 retired**
and **375 added done / 22 open**, combined **464 done / 106 open / 6 retired**.
T00 separately has original0/6/1 and added4/1. Its final inventories remain owed.

Read the current instructions and sources in this order:

1. [AGENTS.md](../../AGENTS.md), [plans register](../plans/README.md), accepted
   [M7](../plans/M7.md#concept) and [technical plan](../plans/M7-technical.md#technical-depth).
2. This handoff, [resume history](M7-resume.md) and
   [canonical task ledger](M7-implementation-tasks.md).
3. [Context map](../developer/agent-context-map.md), [DEVELOPMENT.md](../../DEVELOPMENT.md)
   and relevant accepted ADRs/code/tests. Read the vision pair before architecture,
   trust, cross-domain or public-contract decisions. Avoid bulk historical-plan reads.
4. [Closure evidence scaffold](M7-closure-runs.md). Pending fields remain Pending.

Before 1.0, maintain one current contract and delete superseded code/readers/
compatibility paths. Current-format replay, authority, cleanup and backup/restore
remain required. Ask material decisions one at a time, with options and plain
English repercussions. Preserve all required real-path tests, assertions,
original joins and cutoffs. No same-byte failed rerun becomes a pass.

This checkpoint authorizes no main merge, milestone closure, release, tag,
publication, paid provider campaign or weakening of verification. Closure and
release remain separate maintainer decisions. Do not treat archived proposals
or source reviews as acceptance or native proof.

## Technical depth

### Exact checkpoint and process state

The implementation source checkpoint is `0317a9980aac15c44dad864a8983c486ff609d78`.
Its parent `439f71cd9f05ceacc91cd5ccee1ec728e7a9e26d` joins reviewed native privacyV4
and ProgressSinkV2; the child applies only strict non-line-AST-equivalent
formatting. The later commit containing this handoff changes documentation only.
The final reply supplies that pushed handoff SHA. Find it without a self-reference
using `git log -1 --format=%H -- docs/evidence/M7-handoff.md`.

All three owned source files are committed in the primary checkout:

- `apps/loopex/lib/loopex/progress_sink.ex`
- `apps/loopex/test/progress_sink_test.exs`
- `apps/loopex_composition/test/native_model_switch_test.exs`

There is no unjoined latest source unit. Isolated donor worktrees under
`/private/tmp/m7-native-thinking-privacy-20261009-v1` and
`/private/tmp/m7-progress-sink-completion-20261009-v1` are stale raw donors.
Do not reapply their source over the formatted primary files. Their complete
before/after packets and reviews have been retained outside temporary storage.
All workers finished. No native original handle/process group is live. No queued
agent result is needed to continue. The old chat pauses only after the push.

The root/integrator owns native BEAM, parser, compiler, formatter, build/cache,
process and Git custody. Text-only workers use independent worktrees and
non-overlapping paths. Root alone rejoins and qualifies. Do not mutate the
primary source or HEAD while a native original is live. Collect each original
once, retaining actual exit, all original process joins/group absence/EOF,
complete logs and hashes. Private incremental caches are development caches,
not fresh-source evidence.

### First work after takeover

1. Verify `m7`, clean primary tree, pushed checkpoint and no live original.
   Run `python3 scripts/m7-task-status.py` and read the existing ledger rows.
2. Fix the **two new native privacy failures** from original18775 below. The
   actual cause of the missing text delta is not established. Inspect provider
   streaming/public progress mapping and the fixture's retention/closure order
   before deciding whether this is fixture or production. The artifact fixture
   reaches `Loopex.start_link` with tools but lacks the required host policy.
   Use the existing current host-policy preparation contract. Do not bypass the
   gate, weaken the expected delta or introduce a new contract without approval.
3. Independently review only the repaired delta, preserve every prior case,
   canary, actor/monitor/cutoff and first-failure cleanup rule. Commit a new source
   candidate, format with strict AST equality, and run complete native files on
   both pairs. Current ProgressSink48 passed already at0317a998; reuse that exact
   evidence if its relevant bytes/dependencies remain unchanged. Floor48 and
   both production compile-out checks are still owed. Do not rerun unchanged
   passing groups gratuitously; record reuse identities explicitly.
4. Complete qualification of `test/native_model_switch_test.exs` in Composition
   and `test/native_transport_test.exs` in ReqLLM on both pairs. Actual populations
   are5 and14. No filters/exclusions/skips/invalid cases are authorized. Inspect
   actual production-compiled ProgressSink BEAM to prove the test scheduling
   seam absent. The retained root-only checker/runner supplies a reviewed recipe.
5. Reconcile existing rows, not new checkboxes. The independent conditional T08
   audit permits original privacy row10 to close only after the repaired full5+14
   both-pair proof joins retained buffered55 and existing failure/accounting proof.
   The T07 source change touches a runtime dependency of the earlier buffered
   tests. Reuse earlier evidence only after checking the relevant bytes and
   proof impact; requalify affected buffered groups if that impact is unresolved.
   T08's seven/nine/cancellation subsequent-prompt campaign row remains open.
   T07's existing added standalone sink row needs both-pair48, physical CAS/cut
   witnesses and production compile-out. Real transport/activity/caller work is
   a separate remaining obligation.
6. Qualify the joined bounded answer-scope CLI diagnostic on the full twelve-case
   recovery file, both pairs. It is still UNRUN. Establish the intermittent
   duplicate's actual failed wire/closure cause and repair it without weakening
   exact-once output. A quiet diagnostic pass does not repair an earlier flake.
7. Rejoin current protocols/clients and remaining creation/configuration paths,
   finish helper authority/accounting, attempts writer and whole integration.
   Respect the pending decisions below. Use the complete remaining-row snapshot
   and canonical ledger, which carry precise proof obligations and prior evidence.
8. Once implementation outcomes are complete, assemble the exact candidate,
   required inventories, focused/real-path/Linux/attended evidence and independent
   review. Follow T17, then request closure approval before T18. T19 publication
   needs separate authorization. Never call all M7 done based on a focused run.

### Latest original qualification, failed and retained

Original18775, source `0317a9980aac15c44dad864a8983c486ff609d78`, finished
FAIL in **54.023 seconds**. Current native discovery found48+5+14 cases, zero
excluded/skipped. Current ProgressSink passes48/48. Current native privacy
passes3/5 with two failures:

- `verified native summary keeps progress, canonical history and private outputs distinct`,
  line302: `assert_privacy_progress/7`, line1127, expected
  `["PUBLIC_ANSWER_CANARY"]` but observed no `:text_delta`.
- `native private continuation stays out of a real tool-created artifact across reopen`,
  line316: startup atline1426 returns `{:error, :host_policy_required}`.

Current NativeTransport, every floor group and both production-build/compile-out
stages are **UNRUN** because the runner stops at the first failed group.
All10 original processes joined;45 artifacts authenticated. Output is
`/Users/spuri/projects/lexlapax/loopex-evidence/M7/handoff-units-v2-focused-20261009-v1`.
Collection SHA-256 `566d873a996ec82d7b807f41303cf79b5106e352f20df0a886fb44f5f15974bd`;
terminal `5811fe644fbdea917af0eba101d49d32f13c6ae539e8af12b8ddbc8c0cd7c2eb`.
Latest admitted registry has3340 keys, digest
`74b95a02471fd887b1ed98c3309cf1053c669dd04c0d57967f06058d338648fe`.
The final documentation run extends this registry; use its collected child
as the next admission seed, not this older registry.

Formatter original49127 at439f71cd passes strict non-line AST equality for
all three paths and both changed-source format checks in2.944seconds.
Collection `0823d6ca589bc008c59312ecbf8fdeda001bc44562fe3f37614a2363bf54f4f0`.
The correction reviews are source-only, not a substitute for the failed run:

- nativeV4 `16c8f521692f5a054394482f3a0a4d8083f1c4977d59396a6cc8ae008ba3e52e`
- ProgressSinkV2 `bba072dc34830827928c9d781ba49d328fb089d74d05f1ff90a7efafe1e58e77`
- conditional T08 row review `7f406826eb1bb98028206949a22fbbf34afed23ff43cbb4144aff67eef0a9c00`

### What these two joined units implement

NativeV4 keeps the original ABA case, adds verified nonempty/empty and unverified
private-thinking cases, actual native SSE, exact permitted summaries, separate
private continuation capsules, bounded managed trace/diagnostic observations,
public history/reopen checks and a real `loopex.read` artifact-spill/reopen case.
The artifact case checks actual Executor output, receipt/use identity, open/closed
continuation replay, physical Local Store/Executor reopen and zero redispatch.
V4 fixes first-error preservation and attempts every available cleanup release,
close, stop and original monitor join within the unchanged captured endpoints.
Two native assertions fail as recorded above; no completed privacy row is claimed.

ProgressSinkV2 retains42 existing cases and adds six physical witnesses: exact32
failed real native CAS at reserve, shared reserve/publish budget, blocked claim
custody, producer death after reserve and after payload materialization, and
actual retirement/reuse resisting a stale generation. The test-only schedule
seam surrounds real `:ets.select_replace` and supplies no result or arena write.
V2 places ABA startup under original first-error cleanup and retains the original
owner/guardian monitors promptly. Current48 pass. Floor and actual production
seam absence remain unproved. Sink-only proof does not complete runtime/caller
migration or actual foreground output ownership.

### Other retained results and open failures

- Buffered privacy original35897 passes55 per pair at764110c3 in141.152seconds.
  Complete Composition integration29, ambient2, API19, CallerWire5. Actual verified
  TLS Haiku-low permitted-summary and Fable-default private-thinking cases,
  exact public outputs, original actor joins. Collection
  `c07e84fe139baf3253f2250e589f0983843f804ad9aad3eff52caf4174785552`.
- Original63594 passes complete documentation gate at5d6a8bd3 in26.598seconds.
  Collection `421e3fc985f0398e06d35e848bc8be826f9af593fc6e49c4aed2ffeea9d9ba56`.
- CLI recovery original44759 at0fc5b96b fails11/12 current in332.425seconds,
  fresh-before-prompt prints its answer twice; floor UNRUN. Observer was disabled
  in that fresh case, so healthy lost-create wire metadata is not its cause.
- CLI recovery original18074 at8b083be9 fails11/12 current in332.233seconds.
  Fresh body passed, but128-record diagnostic capacity filled with control
  polling before answer progress; floor UNRUN. Joined answer-scope diagnostic
  keeps128/65536 caps and all original behavior checks, retains selected answer
  records and counts control omissions. It is formatted but native UNRUN.
- Ordinary CLI original99704 passes38 per pair at3e5f83f3 in168.994seconds.
  This does not settle recovery duplication/progress, provider or attended proof.
- ADR0066 lost-registration original10853 passes41 Local artifact cases per
  pair in144.495seconds ataa4187da, including actual60-second six-placement
  barrier and full64MiB/four-capacity accounting. Broader Core/transport opening
  joins remain in T05. Do not reinterpret it as full artifact closure.
- Native configuration93 and creation79 per pair at ecc14289 are proved by
  originals99182/59208 in195.327/235.739seconds. Root/VM creation recovery is
  proved. Caller migration and coordinated serving remain open in T04/T05.
- Full integration failures remain in T16: sixty-three quiesce fences sharing
  one cutoff at520ff308; pre-fence `runtime_unavailable` at0823aa50; and actual
  Task.Supervisor/OwnerGroup `shutdown_error`/`noproc` diagnostics. Their retained
  failed outputs and exact proof obligations are in the ledger/resume history.

The conditional T08 audit authenticated prior native22 and buffered55 outputs,
but some older239/416-case Core component logs were not recovered at their
recorded temporary paths. Those older claims remain ledger-recorded, not newly
authenticated evidence. Recover durable originals or re-establish the affected
proof on a valid new candidate before relying on it for closure.

### Decisions and authorized boundaries

ADR0066 is Accepted, including the maintainer's latest reaffirmation. Do not
ask again. Existing accepted ADRs and overrides are in the context map.

**Presented and unanswered:** exact Proposed ADR0067 pair at
`805df2c2107bee43b81d266f520935c7b9cb4b89`, closed R8/T7 `tool.finished` union,
coordinated manifests/pins/transports/clients and no synthetic operation ID.
Concept SHA-256 `fd19c8e175c35abec19a168638146d8f630c3270c23dd01003f788271b6bc995`;
technical `b04e5e2706aad4f695e71eada2ac4d0b7c61e729f097301ac02cb868d9417e7f`.
Do not implement dependent projection until exact acceptance. The new chat may
need to present the same pending decision once because the old question UI is
chat-local. Distinguish restating an unanswered decision from asking approval again.

Queued material decisions, not accepted:

- ADR0065, exactb651904a84be33800f3a2bf19cf782940e3fc1fb, Python3 stdlib and
  physical private-attempts file locking prerequisite. Dependent T14 writer waits.
- ADR0068, exact773e090df996d3cd2e5966244121a9b632cffbd7, physical CLI output owner
  and separate5-second pre-runtime acquisition. Dependent physical writer waits.
  Concept89e1bcb090a1e1648ef289c3238f5541d0b62627778419b5084fa3295a309b6f;
  technical6b40f8445e23a106911254ef09a14f76eff49d3cf7afd16060c94751783200d4.
- T11 retained child-accounting access and universal mutation guards before
  runtime-only helper exposure. Do not copy private reducer accounting or expose
  an unapproved public read to avoid the decision.
- Older Core artifact36 observer-only1,000-ms fixture grace is not covered by
  the prior diagnostic approval. Check the exact current packet/context before
  asking; do not enlarge it silently. Runtime opening limits stay unchanged.

The approved1,000-ms diagnostic cutoff and600,000-ms aggregate64-restore test
cutoff are already recorded. Their per-operation limits, grace and joins remain.
No compatibility work for old roots or old clients is required before1.0.

### Durable packet/evidence recovery

Complete logs stay outside git under
`/Users/spuri/projects/lexlapax/loopex-evidence/M7`. This follows the repository's
evidence contract. Git retains code, goal, tasks, decisions, run identities,
limitations and takeover steps; no essential source exists only in a worker.

Latest preparation retention is
`M7/current-source-preparation-20261009-v44/retention.json`, SHA-256
`420fb369b95fc83f0dd325a9a86e3d00bac65e5bb506f53b34aad52101a9a255`.
It authenticates151 assets and parentv43, including complete originals63594,
49127 and18775, nativeV3/V4 and ProgressSinkV1/V2 before/after packets, reviews,
conditional audit, native discovery, collector, formatter and qualification
recipes. v43 digest `6d06b66ea7840539a123f0d429a61376e1331149d4c72d72b4bd4dc0a0e341bd`.
v42 digest `25fc05c26cc566670d8a78084aa63e4cf8cc4f63e7d71d5350541523816f6223`.
Parent records authenticate older evidence; do not bulk copy or rerun it.

If `/private/tmp` disappears, authenticate retention.json, then every `assets`
entry's bytes/hash before use. Restore only needed assets using their recorded
original `source` paths. Refuse any conflicting existing bytes, symlink or path
outside `/private/tmp`. Keep original packets0444. Do not execute a retained
runner with its stale PIN/OUT/seed. Derive a unique new recipe against the new
clean committed source and latest collected registry, inspect the exact delta,
then admit once. Important retained recipe names under `recipes-and-reviews`:

- `m7-focused-proof-derive-20261009-v1.py` and its complete base
  `m7-embedded-workflows-focused-20261009-v1.py`
- `m7-handoff-units-v2-focused-20261009-v1.py`, PIN/seed/cardinality/file-pin
  sidecars, original derivation and production-check derivation
- `m7-progress-sink-production-absence-20261009-v1.exs`
- `m7-current-daemon-cli-discovery-20261009-v8.exs`
- `m7-native-collect-20261008-v1.py`
- `m7-candidate-format-preparation-20261009-v82.py` with sidecars/AST checker

The incomplete v1 handoff derivation failed before native admission because two
helper paths were wrong. Actual v2 pins correctly use
`apps/loopex_llm_reqllm/test/support/provider_isolation_fixture.exs` and
`apps/loopex/test/support/configured_genesis_helper.exs`. This derivation error
was not a native retry. Both recipes are retained honestly.

Runner engine `M7/retained-finalization-format-runner-20261006-v1/run.py` digest
`c8834d1c45f7832bad69df20c848b9cd55079dfc66ea2484e31f0333382c93d4`,
helpers `fd4b95e7e4055f563e34c188eafe0995a679e54bac4a4ea12200cf872fe8fffa`.
Private environment preparation source is
`M7/coupled-current-context-20261008-v6/assets/44/proof.enabled.py`, digest
`0a6647fdd1a5824af3e996f5dc14f5bd60f6600205ac54f85ae0b8079ebb2e55`.
Actual native environment recipes pin credential-free temporary homes, offline
private dependency/build caches, Node22.14.0 and `+S4:4`. Supported pairs are
Elixir1.20.3/OTP29.0.5 and floor Elixir1.18.5/OTP27.3.4.

The final handoff documentation gate runs once on its clean commit. Its immutable
output/collection is referenced by the final reply and by the evidence sibling
`M7/handoff-docs-check-20261009-v1`. It is a documentation check only. The final
handoff commit cannot contain results produced after it without a later commit;
use the retained terminal/collection, verify their source equals this document's
commit and use its extended registry as the next seed. No full check or release
matrix is claimed by this checkpoint.

### Task counts at handoff

This table is a snapshot. The canonical checkbox source remains
[M7-implementation-tasks.md](M7-implementation-tasks.md). Recompute with
`python3 scripts/m7-task-status.py`; it includes T00, so its aggregate totals
are original89/90/7 and added379/23/0. T01–T19-only totals are given above.

| Task | Purpose | Original done/open/retired | Added done/open |
| --- | --- | ---: | ---: |
| T00 | Specifications and fixtures | 0/6/1 | 4/1 |
| T01 | Conversation continuity | 7/0/0 | 0/0 |
| T02 | Large outputs and artifact reads | 9/0/0 | 18/0 |
| T03 | Host-composed instructions | 6/1/1 | 5/0 |
| T04 | Configuration, genesis and routing | 7/4/0 | 34/4 |
| T05 | Records, protocols and independent clients | 1/9/0 | 41/8 |
| T06 | Complete chat and preserved workflows | 5/2/0 | 12/0 |
| T07 | Automatic and explicit compaction | 10/1/0 | 50/2 |
| T08 | Model selection and private continuation | 9/2/0 | 29/0 |
| T09 | Model-originated questions | 8/0/0 | 14/1 |
| T10 | Chat controls, pipes and tracing | 10/0/0 | 22/0 |
| T11 | Read-only helpers | 1/14/0 | 13/1 |
| T12 | Ephemeral support | 8/2/0 | 9/0 |
| T13 | Coding fixtures and operator instructions | 4/6/0 | 7/0 |
| T14 | Attempts and evidence validation | 0/10/0 | 9/0 |
| T15 | Current-format restore and retired compatibility | 3/1/5 | 39/2 |
| T16 | Integration and regression | 1/8/0 | 73/4 |
| T17 | Closure candidate | 0/10/0 | 0/0 |
| T18 | Closure and main merge | 0/7/0 | 0/0 |
| T19 | Separately authorized release | 0/7/0 | 0/0 |

### Remaining task and subtask snapshot

The following copies the open row text for takeover navigation. It changes no
scope, status or proof. Check the canonical ledger for nearby evidence and
accepted dispositions before acting. Retired original rows stay retired.


#### T00

- Original: Inventory every affected record, API, tool generation, adapter and protocol.
- Original: Pin schema definitions, digests, compatibility vectors and provider mappings.
- Original: Create the M7 fixture manifest with exact prompts, budgets, allowed changes and objective results.
- Original: Assign every operator step and negative scenario to a named test or demonstration.
- Original: Prepare the indexed closure-evidence scaffold with results marked Pending.
- Original: Verify manifest completeness, invalid-manifest rejection and actual instruction/tool-schema costs.
- Added: Join that family inventory to exact payload schemas, path inventories and decoder vectors.

#### T03

- Original: Prove instructions cannot widen policy or helper authority.

#### T04

- Original: Retain committed session settings, tool selections, roles and delegation declarations.
- Original: Implement named provider and credential bindings through the existing custody boundaries.
- Original: Abandon prepared owners on every post-preparation refusal; retain uncertain cleanup honestly.
- Original: Test malformed files, duplicate keys, overrides, resume conflicts, missing bindings, changed catalogs and cleanup failures.
- Added: Implement accepted ADR0059's atomic creation heads, complete candidate capsules and exact created/cancelled resolutions in the shipped Stores; prove claim/reservation and final/close races, physical replay and complete current-format backup/restore, with no unreserved fresh-create fallback after coordinated rejoin.
- Added: Implement accepted ADR0059's owned Control creation slot, conservative pre-permit fence and mechanical carrier with finite startup/recovery; prove actual held Store stop/status/overlap behavior, occupied-read refusals, original joins/cutoffs, actor/root/VM loss and no historical activation before coordinated rejoin.
- Added: Finish provider bindings and captured exclusions through chat, daemon-command and remaining ask/helper entrypoints, including discovery and helper preparation.
- Added: Finish accepted ADR 0050 through live foreground /3, daemon /4 and independent clients after coordinated generation activation; prove lease/owner authority, runtime alias resolution, exact duplicate/unknown persistence, public projection and cleanup without host-route disclosure. Native implementation and dormant ingress are proved; superseded generations do not advertise configure.

#### T05

- Original: Implement every new record/request generation before emitting it.
- Original: Add foreground protocol /3 and daemon protocol /4.
- Original: Update both servers and the independent Node clients together.
- Original: Update daemon mutation, capacity, lease and succession inventories.
- Original: Implement bounded snapshots and events with consistent replay cursors.
- Original: Preserve numeric domains without JavaScript rounding or narrowing.
- Original: Test negotiation order, malformed offers, digest mismatches, old clients, authority checks and replay.
- Original: Verify private thinking, credentials and host-only data never enter public projections.
- Original: Run the required independent-client workflows.
- Added: Resolve and implement the current full-transfer opening boundary under ADR0028: one original lookup/verification deadline, bounded four-transfer custody and cancel-before-open behavior, honest cleanup/refusal and late reclamation, exact immutable-use identity and complete physical/transport proofs. Accepted ADR0066 supplies the port/ownership/work-accounting amendment; the separately proved artifact-description guard does not complete this obligation.
- Added: Join accepted ADR0059's closed creation cancellation through native result readers, both complete negotiated generation schemas and independent clients; prove refused/no-activation/no-session correlation and exact replay before coordinated serving activation.
- Added: Finish accepted ADR0052 native answer provenance, exact policy cursor/replay relations and shared Elixir/Node payload projection in both transports; prove focused current/floor and independent vectors after rejoin, complete negotiated manifests and real answered-command workflows.
- Added: Pin and implement the exact configure request and versioned remote creation-option grammars through governed decisions; preserve authored aliases, central preparation, host-only bindings, current command replay and both transport authority gates.
- Added: Pin and implement the closed transient compaction-progress payload and its actual owned emission/loss/succession behavior; exclude summaries and private captures and prove both transports/clients before complete generation activation.
- Added: Implement the approved closed `context.maintenance_changed` event and active-maintenance snapshot view; authenticate both actual owners and retained admission bounds, emit only changed safe projections in serial-owner transactions, reduce snapshots at the same public cursor, and prove closed numeric/opaque domains, privacy canaries, paged/mid-transaction anchors, duplicate/succession and all three Store uncertainty phases with both independent Node workflows.
- Added: Resolve and pin the complete current inspection member inventory and answered policy-defer visibility at the correct public/private truth plane before hashing or serving the full /3-/4 manifests; preserve configuration, active bounds, maintenance privacy and snapshot cursor semantics.
- Added: Migrate remaining implicit Core/edge/transport test hosts to captured current creation, replace their superseded record assertions, remove old configuration-less readers/writers, and prove current replay, command identity, uncertainty, authority and cleanup without a Core fallback. Run the full check once on the resulting clean committed candidate. The headless/loop and context-admission fixture phases are complete; superseded request/admission decoders and edge/transport joins remain.

#### T06

- Original: Preserve existing ask, durable-run and embedded workflows.
- Original: Later retain the required attended multi-prompt proof.

#### T07

- Original: Prove automatic compaction, explicit compaction and restart preserve the required facts.
- Added: Implement and prove accepted ADR 0058's standalone ProgressSink arena and owner custody on both toolchains, including finite pre-mailbox admission, conservative retained-byte charges, lease generations, pressure and death races. Sink-only proof does not complete runtime/caller migration or real output qualification.
- Added: Join accepted ADR 0054 activity to real foreground and daemon transport progress routing, preserving current-owner subscription, resume/cleanup, malformed-row privacy refusal and existing queue/frame bounds. Prove actual delivery and independent clients under the coordinated served generations; dormant codec/projection tests alone do not complete this transport obligation.

#### T08

- Original: Test model switching, crashes, cancellation, malformed replies, overflow, usage accounting and privacy.
- Original: Complete the seven thinking-round subcases, nine bound subcases and cancellation witness, including their prescribed subsequent prompts.

#### T09

- Added: Join that answer schema and decoder to the complete M7 /3-/4 contracts and both authorized mutation paths.

#### T11

- Original: Implement saved roles with exact instructions, models, credentials and finite allowances.
- Original: Register the opt-in helper tool and immutable read-only tool selection.
- Original: Implement exact create-result lookup and retain genesis before child creation.
- Original: Implement parent bindings, catalogs, allowance ledgers, stop records and receipt routing.
- Original: Implement bounded private codecs, framing checks, writer fencing and reserved completion space.
- Original: Enforce one unresolved helper per parent while allowing independent parents to progress.
- Original: Charge attempted reservations conservatively; only the specified pre-effect refusals consume nothing.
- Original: Implement bounded startup classification of all committed creates, including helpers-disabled startup.
- Original: Guard existing attachments and settled child sessions against ordinary host mutations.
- Original: Validate cache coverage, remove refused registrations and handle interrupted publication.
- Original: Recover completed results and stop unfinished helpers; recovery must never create or re-prompt them.
- Original: Test read-only authority, nesting refusal, budgets, concurrent parents, cancellation and exhausted-call reopening.
- Original: Inject faults at every binding, reserve, create, prompt, stop, settlement, receipt and cache boundary.
- Original: Prove both role demonstrations with unchanged child workspaces and separate/combined usage.
- Added: Resolve exact retained child-accounting access and universal host mutation guards before exposing helpers through runtime-only clients; preserve host ownership, current serial session truth, retained maintenance charges and settled-child protection without copying private reducer accounting or adding an unapproved public read.

#### T12

- Original: Preserve the existing credential and transport-cleanup guarantees.
- Original: Complete the attended ephemeral-question witness.

#### T13

- Original: Implement the trusted fixture wrapper and exact approved test-command policy.
- Original: Let the agent run approved tests; independently rerun immutable oracles and inspect allowed changes.
- Original: Pin and execute the maintainer-selected external repository task.
- Original: Make every V1–V13 instruction runnable, with one owner and evidence slot per step/subcase.
- Original: Complete the specified human-attended steps with a named operator.
- Original: Collect previous executions without adding extra model attempts.

#### T14

- Original: Implement the canonical, hash-chained attempts index and fsync-before-dispatch.
- Original: Implement single-writer ownership and safe evidence handoff between machines.
- Original: Implement all attempt states, verdict classes and legal transitions.
- Original: Handle missing, corrupted or incomplete evidence as unavailable.
- Original: Implement pre-dispatch-only continuation without redispatching completed work.
- Original: Implement suspended-lane abandonment and committed index-head barriers.
- Original: Enforce causal corrections and independent outage review; a new SHA alone permits no reroll.
- Original: Add the M7 evidence validator to the existing two check commands.
- Original: Implement M7 lane selectors while preserving all legacy cases.
- Original: Test truncation, forks, duplicate writers, interrupted handoff, resume, abandonment, redaction and every verdict route.

#### T15

- Original: Restore into an empty root and compare complete manifests.
- Added: Remove superseded record/API/protocol readers, tool generations, host fallbacks and compatibility-only fixtures; migrate current callers and retain one current contract at each boundary.
- Added: Prove current-format backup/restore and recovery with complete manifests, separate workspace state and exact nonredispatch of unresolved effects.

#### T16

- Original: Keep outcome rows linked to actual tests and evidence.
- Original: Update operator/developer documentation, indexes, compatibility guidance, README, roadmap and changelog.
- Original: Update verification guidance to the accepted M7 procedures.
- Original: Run focused unit, property, conformance, fault, security, protocol and CLI tests during development.
- Original: Run the fast check once per clean integration candidate.
- Original: Run required selected real-provider, Node, daemon, long-bound and cross-UID lanes.
- Original: Run changed process-boundary cases thirty times under the prescribed pinned Linux load.
- Original: Independently review integration changes and fix confirmed defects without weakening checks.
- Added: Integrate foreground FIFO and emitted-cursor custody through the physical OutputWriter, native progress ingress and bounded frames; prove all eight whole files / 112 cases per supported pair, including all four Node cases and allocation negative controls, then integrate the exact 17 owned files above qualified Core32. Preserve original actor/credit/cursor/cleanup oracles and cutoffs; Linux stress, served-generation activation, forced 32-CAS exhaustion and full integration remain separate.
- Added: Investigate and repair the full 520ff308 integration failure in the sixty-three blocked quiesce fences sharing one cutoff with a settled sibling; retain the failed exact-candidate output, establish the cause through bounded runtime observability and actual process lifetimes, preserve the shared cutoff, sibling progress, fence accounting and cleanup assertions, and verify both supported pairs.
- Added: Resolve the exact 0823aa50 full-check pre-fence runtime_unavailable under untraced combined load; retain failed output, establish its phase/cause and exact process lifetimes, preserve the original gate/fence/reap/cleanup/Store assertions, and verify a clean committed integration candidate without relabeling the failed run.
- Added: Investigate Task.Supervisor and OwnerGroup shutdown_error/noproc diagnostics for Task.Supervised and coordinator children in configuration/input/interaction cleanup; retain reproduction and actual task-lifetime evidence, including the coordinator-child report in the maintenance-view full Core run.

#### T17

- Original: Provision both supported toolchains, pinned Node, provider bindings and the legacy Ollama witness.
- Original: Provision Linux cross-UID support, descriptor limits, retained evidence storage and attendance.
- Original: Finish all source, fixtures and documentation before committing the tested candidate.
- Original: Move the candidate to In review with complete proof mappings and Pending evidence slots.
- Original: Verify main is an ancestor.
- Original: Count the existing current-toolchain fast check; run the floor-toolchain check.
- Original: Run the full logical release matrix in its fixed order.
- Original: Complete every M7 case, subcase and operator evidence join.
- Original: Retain outputs, manifests, usage, sizes, durations, failures and independent review with digests.
- Original: Present the exact candidate for the maintainer’s closure decision.

#### T18

- Original: Obtain explicit closure approval on the tested candidate and evidence.
- Original: Create the administrative direct child confined to the five permitted paths and regions.
- Original: Record both tested and administrative identities correctly.
- Original: Verify confinement and status transitions.
- Original: Fast-forward main to the administrative closure commit under the maintainer’s integration authority.
- Original: Push and verify the resulting repository state.
- Original: Clean up landed worker branches/worktrees; retain m7 through implementation and decide its disposition after closure.

#### T19

- Original: Select the release label before testing any version-dependent source changes.
- Original: On the administrative SHA, prove confinement, documentation structure and documentation meaning.
- Original: Compare tested and administrative source archives using the required complete manifests.
- Original: Validate modes, paths, source identities and permitted exclusions.
- Original: Create the authorized annotated tag at the administrative SHA.
- Original: Push the authorized tag/publication and verify its target.
- Original: Reuse unchanged-source closure evidence; do not rerun the suite or provider matrix.

All historical evidence remains tied to the revision named in its record.
