<a id="technical-depth"></a>
## Technical depth

Concept: [Milestone purpose and outcomes](M3.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Milestone scope](M3.md#concept-plan-scope).

Concept: [Milestone non-goals](M3.md#concept-plan-non-goals).

This plan is Open. `M2` is Closed and integrated, so `M3` opens from a closed
product base rather than as a planning lookahead, and there is no second
implementation authority to wait for. Acceptance, integration, and
implementation still require the ordinary sequence: an accepted plan pair and
locked gate, a gate that is red for its own declared missing behaviour before
implementation, and an independent exact-SHA review.

One decision is a prerequisite for accepting this plan pair:

- **ADR 0002 — Bootstrap runtime floor and version matrix.** Already Accepted
  and therefore not blocking, but it is the decision this milestone changes, and
  Outcome 8 cannot begin until an amendment to it is separately accepted. The
  amendment raises the floor family; it does not turn the floor into a released
  support statement, and it does not authorise a version, tag, or publication.

The floor amendment text below is a **proposal**, not an accepted decision. It
lives here so the plan pair and the change it commits to are reviewed together;
on acceptance of the amendment it is lifted into
[ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) and its technical
companion by the ordinary ADR amendment path, and this block stops being the
source. Accepting this plan pair does not accept it.

> **Proposed ADR 0002 amendment — raise the bootstrap runtime floor family.**
>
> Replace the floor family Erlang/OTP 26 with Elixir 1.17 by Erlang/OTP 27 with
> Elixir 1.18. The two locked pairs become:
>
> ```text
> # floor pair
> elixir 1.18.5-otp-27
> erlang 27.3.4
> #
> # current pair
> elixir 1.20.3-otp-29
> erlang 29.0.5
> ```
>
> The current pair is unchanged. The two pairs stay in distinct OTP families,
> because Elixir supports the three most recent OTP releases and a floor equal to
> the current pair would collapse the matrix to a single toolchain and lose every
> lane that can detect toolchain sensitivity. Core must still compile and pass on
> the floor pair, both pairs are still validated individually rather than as a
> cross-product, and the ADR still makes no released compatibility or support
> claim: the floor remains a development and validation target until a release
> makes it a promise.
>
> The amendment must also state, in the ADR itself, which rule produced these
> exact pins. ADR 0002 today derives them — the lowest supported pair in the
> floor family, the newest stable supported pair — and the proposed floor pins
> are not the lowest 1.18.x with the lowest 27.x. Either the derivation rule
> changes with the family, or these pins are recorded as chosen rather than
> derived. That choice belongs to the amendment and is not settled here.
>
> Nothing about `.tool-versions` changes at the moment the amendment is
> accepted. The bytes move only through the four gate transactions below.

Six further decisions remain separate from plan acceptance:

1. `.tool-versions` is bound by four gates — the `M0`, `M1`, and `M2` gates and
   this one. Raising the floor therefore lands as four transactions run in
   sequence and never as an edit: an `amendment-transaction-v2` gate generation
   on Closed `M0`, the same on Closed `M1`, the same on Closed `M2`, and an
   ordinary `amendment-transaction-v1` amendment on Accepted `M3`. Each carries
   its own explicit acceptance. Between the first proposal and the last rebind,
   an artifact bound by a holder that has not yet run its own transaction is a
   stale binding that sequence is on its way to fixing rather than a failure of
   the transaction in flight, and no revision in that window is a closure
   candidate. This milestone binds `.tool-versions` deliberately, knowing it
   adds the fourth transaction, because a gate that validates a toolchain and
   does not bind the file naming it protects nothing.
2. `apps/loopex/test/gate_isolation_test.exs` is bound by the `M2` gate. Outcome
   7 changes those bytes, so it rides an `amendment-transaction-v2` generation
   on Closed `M2` with its own acceptance. This gate deliberately does **not**
   bind that corpus, for the reason `M2` gave for leaving the dependency-budget
   artifacts unbound: binding bytes the milestone must change would lock a
   digest acceptance already knows is wrong.
3. The `M0` outcome-1 verdict correction (Outcome 6) reaches a Closed gate and
   is folded into the `M0` generation that Outcome 8 opens rather than opening a
   second one, because both changes reach the same gate and a second generation
   would be two acceptances for one edit window.
4. `M3` acceptance and any governance-only Acceptance integration remain
   maintainer decisions.
5. Closure remains a maintainer decision after every Purpose outcome maps to
   evidence, demonstration, or an explicitly approved limitation.
6. Publication, tag, package, release, compatibility freeze, and the `0.1.0`
   version all remain separately approval-gated and are not implied by `M3`
   closure. They are expected at the end of `M4`.

Two obligations `M2` recorded are settled here rather than restated:

- The inherited-gate enforcement obligation originates in the `M2` disposition
  anchored
  [the `disposition-m2-inherited-gate-enforcement-2026-08-27` record](../developer/agent-context-map.md#disposition-m2-inherited-gate-enforcement-2026-08-27).
  It named form B — invocation placed in a repository entrypoint that owns the
  rule, or a check that fails when a milestone gate omits its one mandatory call
  — as accepted `M3` scope. Outcome 5 delivers exactly that and nothing wider.
- The cleanup-period limitation anchored
  [the `cleanup-grace-not-session-visible` record](../evidence/M2-recorded-limitations.md#cleanup-grace-not-session-visible)
  is recorded as withdrawn in `M2` itself: the value is session configuration,
  it is forwarded by the shipped composition, it survives reconstruction, and
  every terminal reports it. `M3` therefore inherits no ADR 0009 debt from it.
  The residue named in the Concept — the process-group-confirmation program — is
  executor configuration by that same record and is not an ADR 0009 term.

Deferred decisions and trigger points:

| Deferred decision | Trigger |
| --- | --- |
| The process-group-confirmation mechanism: `/proc`, `kill(pid, 0)` over a retained group, or a platform syscall | Before Loopex claims support for an image that does not ship `/bin/ps`, or before an operator-facing flag for it is offered |
| Bounding the local executor trust to less than a whole ledger root | Before a host runs mutually distrusting tenants against one root |
| Generic context pipeline | Before the first registered provider, transformer, selector, or observer |
| Generic transport behaviour | After a second real transport exists and supplies common evidence |
| Public protocol, schema bundle, and durable interaction lifecycle | `M4`, under ADR 0019 and ADR 0020 |
| Daemon lifetime, concurrent clients, controller leases, takeover, residency | `M5` |
| Released runtime-floor support statement, after which raising the floor is a breaking change requiring migration under the 0.x compatibility policy | Before the first release |

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Milestone scope](M3.md#concept-plan-scope).

| Workstream | Owned paths and state | Rejoin condition |
| --- | --- | --- |
| A — Floor and gate transactions | `docs/adr/0002-*`, `.tool-versions`, `docs/plans/M0-gate.md`, `docs/plans/M1-gate.md`, `docs/plans/M2-gate.md`, `docs/plans/M3-gate.md`, `docs/plans/M0.md`, `docs/plans/M1.md`, `docs/plans/M2.md`, `scripts/check-m0-gate.sh`, `apps/loopex/test/gate_isolation_test.exs` | The ADR 0002 amendment is accepted; all four `.tool-versions` transactions and the `M2` isolation-corpus generation have landed their rebind revisions; binding validation, bootstrap, and every inherited gate pass on the raised floor; the complete matrix is re-captured on both raised pairs across all three lanes |
| B — Closed-gate aggregate | `scripts/check-closed-gates.sh`, `scripts/check-bootstrap.sh`, `apps/loopex/lib/mix/tasks/loopex.gate_invocation.ex`, `apps/loopex/test/closed_gate_aggregate_test.exs` | The aggregate runs every `Closed` gate the register names and fails closed on a missing, unreadable, or red one; `scripts/check-bootstrap.sh` invokes it; the structural check fails a milestone gate that omits its mandatory call; adversarial cases prove both directions |
| C — Product repairs | `apps/loopex/lib/loopex/runtime/context_admission.ex`, `apps/loopex/lib/loopex/runtime/session_state.ex`, `apps/loopex/lib/loopex/runtime/event_dispatcher.ex`, `apps/loopex/lib/loopex/runtime/control.ex`, and their selectors | Step 5 resolves and measures a required-only lower bound with generated evidence to cardinality 1,024; the dispatcher answers with no synchronous Store read in its call handler and the watermark acknowledgement is bounded; spent attempts are pruned on journal-proved past settlement with the succession fence intact |
| D — Corpus honesty and the inherited lock | The eighteen inherited regression selectors, the eight frozen-weakness selectors, and `docs/plans/M3-gate.md` selector tables | Every one of the seventy-nine inherited cases is named in this gate at an exact name and minimum and passes through the authoritative standalone channel; each repaired weakness carries mutation evidence that the assertion fails on the old path |

Rejoin order is **A → B → C → D**, and the order is load-bearing rather than
convenient.

A rejoins first and alone because it is the only workstream that moves bound
bytes. While any of its transactions is between proposal and rebind, binding
validation is legitimately red, and a second workstream landing in that window
would make it impossible to tell a stale binding from a broken one. No other
workstream may change a bound artifact at any time.

B rejoins second because every later piece of evidence is worth more once a
closed gate is actually executed by the repository. Running C or D first would
produce results whose inherited-gate context is still the `M2` waiver.

C rejoins third. Its three slices are independent of one another and may proceed
concurrently in separate worktrees with separate state roots, but none of them
may be merged before B, because the dispatcher and admission changes are exactly
the class of change a closed gate exists to catch.

D rejoins last, for two reasons. A locked name cannot be repaired after it is
locked, so the inventory must be taken against the final corpus. And a mutation
proof taken against pre-repair product code proves the wrong thing: the mutants
for Outcome 7 must be applied to the product as C leaves it.

Decision owners: the maintainer owns the ADR 0002 amendment, each of the four
gate transactions, the `M2` isolation-corpus generation, plan acceptance, every
blocking-finding disposition, and closure. No delegate accepts a gate, a
generation, or a waiver. The integrator owns rejoin, conflicts, the candidate
SHA, and post-rejoin verification, and owns no acceptance.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Milestone outcomes](M3.md#concept-plan-outcomes).

| Outcome | Required evidence | Where it is proved |
| --- | --- | --- |
| 1 | The eighteen selectors run through the authoritative standalone ExUnit channel at the exact names and minima this gate locks, with the seventy-nine inherited case names present and passing and no case skipped, excluded, or renamed | The gate Protected Outcome Selectors table |
| 2 | A generated property over list cardinalities 1 through 1,024 binding the required-only lower bound to the admissibility implication; a structural walk over a structurally maximal instance of the project-receipt schema; replay equivalence showing exactly which byte refusals change meaning and which do not | `apps/loopex/test/context_admission_test.exs` |
| 3 | A held-Store-transaction fixture proving control latency stays bounded for an unrelated session; fault injection over deferred reads at every cut; ordering properties for queue, overflow, and invalidation; the existing fence cases extended rather than replaced | `apps/loopex/test/event_dispatcher_availability_test.exs` |
| 4 | A retention property over synthetic attempt histories bounding Control spent-attempt memory by live work; succession negatives proving no successor can re-spend a pruned attempt; a measured growth observation over a long attempt sequence | `apps/loopex/test/provider_attempt_protocol_test.exs` |
| 5 | The aggregate executed against the real Closed gates; enumeration derived from the register rather than a literal list, proved by a register mutation that changes what runs; adversarial cases where a gate is missing, unreadable, or red; adversarial cases where a milestone gate omits its mandatory call | `apps/loopex/test/closed_gate_aggregate_test.exs` |
| 6 | One negative case per distinct `M0` outcome-1 failure mode, each requiring a distinct verdict, including the observed floor-toolchain-over-current-pair-artifacts case that produced the misleading formatter verdict on 2026-08-27 | `apps/loopex/test/closed_gate_aggregate_test.exs` |
| 7 | Concurrent allocation of isolation scratch roots from simultaneous virtual machines with no collision; one mutation record per repaired weakness showing the case fails on the pre-repair path and passes after; unchanged locked names and minima, or an amendment where either changes | `apps/loopex/test/gate_isolation_test.exs` and the seven further selectors the gate enumerates |
| 8 | The complete toolchain matrix re-captured on the raised floor pair and the unchanged current pair, on Darwin for both and Linux for the current pair; binding validation, bootstrap, and every inherited gate green at each rebind revision; the amended-gate truthful product state reproduced at each proposal and its rebind | `apps/loopex/test/status_check_test.exs` and the retained toolchain-matrix record |

Mandatory closure evidence, each bound to the exact product candidate SHA, gate
digest, command, seed, toolchain, platform, and limits:

1. the closed-gate aggregate executed against every `Closed` gate, with its
   register-derived enumeration printed and compared;
2. a demonstration that deleting any one of the seventy-nine inherited cases turns
   this gate red, taken on at least three cases chosen across three
   applications;
3. the generated ADR 0017 step-5 cardinality evidence with its seed and bound;
4. a multi-session control-latency observation under a held Store transaction,
   before and after the dispatcher change;
5. a Control memory observation across a long provider-attempt sequence, before
   and after the retention bound;
6. one mutation record per repaired frozen weakness;
7. the toolchain matrix on both raised pairs across all three lanes; and
8. the four `.tool-versions` transactions and the `M2` isolation generation,
   each with its acceptance, its proposal and rebind revisions, and the checks
   proved at each.

`M3` claims no real-provider behaviour of its own and its gate defines no
credential lane for its own probes. It re-runs the inherited `M2` gate, which
does define one; the credential reaches that gate through the inherited bounded
frame and never through this milestone evidence records. No `M3` evidence record
may describe an offline check as proving a network call occurred.

Unavailable evidence is unavailable, never PASS. A missing toolchain lane, an
unreadable closed gate, or an environment that cannot allocate an isolated
evidence root blocks closure rather than being recorded as a pass.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Milestone scope](M3.md#concept-plan-scope).

`M3` changes no public contract. The `Loopex` facade gains no function and loses
none; no port callback arity changes; no durable record family is added; no
event shape changes; and the command surface is untouched. Nothing is published,
so there is nothing to freeze.

Two changes are observable and are stated rather than assumed.

Outcome 2 changes what a byte refusal means. Today a refusal on
`context_record_bytes` reports `record_byte_cost` equal to `observed`, the
measured cost of the exact candidate handed to the reducer. After step 5, the
refusal additionally carries a required-only lower bound, and the ADR reading of
`observed` becomes a bound rather than a final cost. Every already-journaled
refusal keeps its recorded members and replays unchanged; the new member is
absent from historical records and its absence is not an error. The milestone
must prove that, not assert it.

Outcome 3 changes the availability characteristics of the event dispatcher, not
its truth. Ordering, the durable event cursor, publication watermark semantics,
and the transient-plane guarantees are unchanged; only the process that performs
the read and the boundedness of the acknowledgement change. A consumer that
depended on a synchronous read completing before an unrelated call was answered
depended on a defect.

Outcome 8 raises a development and validation target. It is not a released
support statement, because none exists yet, and the ADR amendment says so. The
first release converts the floor into a promise; after that, raising it is a
breaking change requiring migration under the 0.x compatibility policy. That is
exactly why the decision is taken now, while it costs nothing.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Milestone scope](M3.md#concept-plan-scope).

There is no data migration. No durable schema, journal record family, store
layout, or on-disk artifact format changes.

Rollback per workstream:

- **A.** The floor raise is reverted by reverting the four transactions in the
  reverse of their acceptance order and re-proving binding validation, bootstrap,
  and every inherited gate at the restored pins. The ADR amendment is reverted by
  its own amendment path. Rollback requires the floor toolchain to still be
  installable; the retained matrix record names the exact pins so it can be.
- **B.** The aggregate and its structural check are additive. Reverting them
  restores the `M2` condition exactly — no closed gate is executed by the
  repository — which is a loss of protection rather than a change of behaviour,
  and it is why reverting B alone requires an explicit disposition.
- **C.** Each of the three repairs is revertible independently. The admission
  change is reverted by dropping the lower-bound resolution and its refusal
  member; historical records are unaffected because the member was never
  required. The dispatcher change is reverted by restoring the synchronous read;
  the deferred-read fence cases fail loudly rather than silently, which is the
  intent. The retention bound is reverted by restoring whole-generation
  retention; the successor fence is unaffected either way.
- **D.** A locked name or minimum cannot be rolled back by editing; it is an
  amendment in both directions.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](M3.md#concept-plan-scope).

The umbrella stays at eight applications. `M3` adds no application, no role, and
no production dependency anywhere in the tree; core remains stdlib and OTP only,
and the dependency direction and budget are unchanged. The one new Mix task,
`mix loopex.gate_invocation`, lives with the existing repository checks in
`apps/loopex/lib/mix/tasks` and is not product code.

Every application version and the root `VERSION` stay exactly where `M2` left
them. `M3` creates no Git tag, no Hex package, no archive, no escript artifact
beyond the one `M2` already ships, no publication, and no release. The `0.1.0`
version belongs to the end of `M4` by maintainer decision of 2026-09-04, and no
`M3` artifact may anticipate it.

`scripts/check-closed-gates.sh` is a repository entrypoint, not a packaged
artifact. Hosted continuous integration may call it, and calling it is the only
integration a host is permitted to have with the rule it enforces.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Milestone scope](M3.md#concept-plan-scope).

The justified growth in this milestone is almost entirely test and enforcement,
which is the point: the product changes in three places and the protection
around it changes in many.

The gate locks these negative constraints and ceilings:

- **No new application, port, behaviour, or public facade function.** The gate
  fails if the application inventory, the role set, or the exported surface of
  `Loopex` changes.
- **No new external dependency anywhere in the umbrella**, and no change to the
  dependency direction. `mix loopex.deps_budget` and `mix loopex.core_only`
  remain green unchanged.
- **`scripts/check-closed-gates.sh` is at most one hundred effective lines.** It
  reads the register, runs the commands it names, and fails closed. Anything
  larger is a framework, and a framework here would need the second real
  consumer that does not exist.
- **`mix loopex.gate_invocation` is at most one hundred twenty effective
  lines.** It answers one question: does every milestone gate document carry its
  one mandatory call.
- **No new abstraction over the three product repairs.** Each is direct OTP and
  direct code in the module that already owns the concern. A deferred-read
  worker pool, a generic retention policy, or a pluggable admission strategy are
  all explicitly refused: each has exactly one caller, and one caller is not
  evidence for an abstraction.
- **No new evidence directory and no new sidecar document class.** Evidence
  lands in `docs/evidence` beside the `M2` records it continues.

Raw line count is a review signal here rather than a cap, except where a ceiling
is named above. What the review must judge instead is whether each of the
seventy-nine locked cases still asserts what its name promises after the product
changed underneath it, and whether the mutation records for Outcome 7 attack the
assertion rather than a neighbouring one.
<!-- loopex:plan-technical-envelope:end -->
