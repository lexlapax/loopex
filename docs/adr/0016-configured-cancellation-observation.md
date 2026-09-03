# 0016. Configured cancellation observation

<a id="concept"></a>
## Concept

Technical depth: [Exact bounds, records, and evidence](0016-configured-cancellation-observation-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-08-31
- **Decision owner:** Maintainer
- **Prerequisite for:** proposed `M2` Amendment 4
- **Supersedes:** 0009
- **Supersedes:** 0011
- **Supersedes:** 0012

The supersession is narrow:

- ADR 0009's closed `JobRequest` field set, statement that no other executor
  boundary moves, unbounded-positive cleanup domain, unchanged receipt shape,
  output-ceiling-only spill rule, unconditional reconstructability after an
  ArtifactStore refusal, and requirement that every pre-effect deadline be a
  receipt move only as stated below.
- ADR 0011's claims that progress was the complete executor-boundary change and
  that the receipt gained no other private facts move only for the fields added
  here. Its progress and stream algebra do not move.
- ADR 0012's preserved job and receipt shapes, three-argument facade as the
  complete production path, fixed-wait comparison, terminal-job cleanup rule,
  and absence of an execute-result reserve move only as stated below. Its
  required `cancel/2`, answer normalization, meaning of `cleaned`, fail-closed
  fallback, job scope, cancellation ordering, and terminal algebra remain.

This decision adds one committed cleanup value to session genesis and
`JobRequest`, configured cancellation and prepared recovery entries, and
cleanup-confirmation and retention-bound receipt facts. Existing three-argument
cancellation and one-argument interrupt entries remain defensive compatibility
paths, but the reference production path uses the configured entries. Grant
bindings, attempt identity, and progress do not change.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-adrs-0015-through-0018-acceptance-2026-09-01) | candidate `acfdbeea5b3a7507c5510e03a10bb8b238481c88`; concept `sha256:0b5c536791ad2d553fb8001e896c0004d34f5b161809b0072f9ff93e7fd31caa`; technical `sha256:76c20b8abf4344ccda8f45cbc2df173e174f08c6b30be21d8d09c2350edf7e5b` |

<a id="concept-adr-0016-context"></a>
## Context

The session already has an operator-selected cleanup period, but the reference
stack observes cancellation through unrelated fixed waits. A valid long cleanup
can therefore be reported unconfirmed or have its process halted while the
executor is still operating inside the configured period. Recovery can also
substitute a new process default for the session's original value.

Cancellation truth crosses three distinct boundaries: process cleanup, return
of the original execute result, and retention/rendering of the terminal. A
single unstructured timeout cannot make all three truthful. Recovery also needs
a durable effect-admission boundary: without one, two Local instances sharing a
state root can disagree about whether an effect began and whether cancellation
is clean.

Technical depth: [Clock and authority boundary](0016-configured-cancellation-observation-technical.md#technical-adr-0016-context).

<a id="concept-adr-0016-decision"></a>
## Decision

**The committed cleanup period derives every cancellation observation bound.**
Core owns the formula:

```text
executor_observe_ms       = max(10_000, grace_ms + 2_000)
receipt_retention_ms      = max(1, ceil(grace_ms / 4))
execute_result_reserve_ms = receipt_retention_ms + 2_000
terminal_reserve_ms       = max(10_000, execute_result_reserve_ms)
session_cache_ms          = max(10_000, execute_result_reserve_ms)
cli_backstop_ms           = executor_observe_ms
                            + execute_result_reserve_ms
                            + terminal_reserve_ms
```

The admitted value is the positive unsigned 64-bit range. The value is
committed in `session_genesis_v2`, reconstructed before recovery advances work,
carried by every canonical `JobRequest`, exposed read-only in session status,
and used by Local for the job being cancelled. A process option is a default for
new sessions only. The complete genesis and effect-intent records are measured
before owner or executor authority is acquired; an enlarged record that exceeds
the Store item ceiling receives its declared pre-effect refusal rather than an
incidental Store error.

**Wall-clock contract facts and monotonic effect control remain separate.** The
immutable wall-clock `effective_job_deadline` remains the job fact used for ADR
0009 validation. At the executor handoff, Local samples wall and monotonic time
as one pair, computes the nonnegative remaining wall duration, and adds only
that duration to the monotonic sample with checked arithmetic. The resulting
private monotonic effect-action deadline is derived once. Every transition that
can authorize an effect requires both current wall time to precede the immutable
`effective_job_deadline` and current monotonic time to precede the derived
action deadline. A backward wall jump cannot extend authority beyond the
monotonic fence; a forward wall jump expires authority by wall truth. No wall
instant is compared with or added to a monotonic instant. All cleanup and
retention waits likewise use one monotonic deadline in safe finite slices; a
later phase receives only the time remaining and never refreshes the allowance.

**Cancellation becomes linearizable with durable effect admission.** Before an
effect is permitted, Local installs a digest-bound admission marker and open
authority entry under one root-wide administrative claim. A deadline or queued
cancellation that wins before the effect boundary may publish the exact durable
pre-effect refusal. `cleaned` is returned only from a matching durable refusal or
independently confirmed cleanup. Absence, conflict, a stranded claim, malformed
truth, or uncertain cleanup is `unconfirmed` or ledger-unavailable; it is never
upgraded by timeout, process death, or a readable-but-unsynced file.

The effect boundary is the serialized transition that reserves exact worker
authority immediately before its single permit. Once it wins, cancellation may
terminate and confirm the owned work but cannot claim no effect began. Every
effect worker is fenced by the Local instance that admitted it. Command cleanup
uses a launch-owned guard rather than signalling sampled numeric process IDs;
filesystem work has an equivalent owner-death boundary. Command cleanup and
confirmation cover only the captured process group: a descendant that leaves
that group is outside both M2 kill authority and confirmation. Cleanup
confirmation requires positive captured-group quiescence or exact no-effect
proof and never claims that every escaped descendant is gone.

Where ADRs 0009 and 0012 call the job's captured-kill-identity scope its
“owned process tree,” the Local reference implementation's exact referent is
this captured process group. That makes the existing kill-identity limit
explicit; it does not grant authority over descendants that have left the
captured identity.

**The Local receipt-ledger root is the trusted atomic administrative unit.**
Every Local using one prepared root shares its generation, admission marker,
open index, refusal, and terminal truth. Root mutation is serialized and
first-writer-wins; exact marker replacement is required for later refusal or
receipt truth. Unresolved open authority quarantines new effects across restart
until exact reconciliation closes it. Every decision combining terminal truth
with an open entry acquires that same root-wide claim and reads one complete
bounded snapshot while mutation is excluded. Claim refusal, malformed truth, or
an incomplete snapshot is bounded unavailable, never permission. The decision
is fixed before the claim is released, so no later unlocked read becomes its
authority.

The generation binds executor identity, a random epoch, the exact expanded root
path, and the verified directory device/inode identity. An ordinary whole-root
move presented at a different expanded path, replacement, or copy, and copying
only its generation into another root, are refused. Retargeting the original
path through an administrator-created alias is an administrator rewrite and is
covered by the limitation below rather than by the ordinary-move guarantee.
Partial copy or deletion, snapshot rollback, inode reuse, and administrator
rewriting of the trusted root are unsupported and may defeat local-only
exactly-once claims. M2 provides no migration. A future migration must close the
old root's authority and create a fresh generation. Receipt-ledger authority is
private to Local and `WorkspaceLease`; it never enters Core Runtime, a job,
grant, receipt, event, log, or diagnostic.

**Cleanup and operation truth remain independent.** Every terminal receipt says
whether cleanup is confirmed and records the committed retention bound. A
validated receipt preserves its operation result. A valid tagged pre-effect
refusal proves no effect began; the exact `effective_deadline_reached` reason
keeps ADR 0009's `cancelled` terminal, while other valid pre-effect refusals are
ordinary failed tool facts. Expiry, malformed answers, or uncertainty remain
`outcome_unknown`. A cancellation answer and receipt disagreement takes the
weaker cleanup fact.

Local may spill output below the tool's model-facing ceiling, or shorten the
displayed prefix, when the exact mandatory receipt envelope would otherwise not
fit. A valid artifact reference preserves full-byte reconstruction and is never
omitted. ArtifactStore refusal or a malformed reference instead produces a
bounded truthful retention-unavailable receipt; it does not claim that an
unrepresented suffix remains reconstructible.

That fitting path consumes ADR 0015's compact object/use reference and ADR
0017's Store-owned normalization and exact item measurement. This ADR neither
accepts those sibling decisions nor authorizes a partial implementation: all
three must be accepted before the receipt-fitting path is implemented, and
rollback removes this consumer before removing either supplied contract.

The configured facade waits for the normalized cancellation answer and then
allows the original `execute/5` caller its distinct result reserve. The CLI arms
one process-liveness backstop when abort admission starts and extends it once,
on accepted admission, to preserve a full post-acceptance window. It never reads
timeout as a commit verdict. Prepared resume transfers one opaque activation
capability to the interrupt owner before ordinary recovered work can resume;
cancel admits abort while that work remains paused.

Technical depth: [Exact decision mechanics](0016-configured-cancellation-observation-technical.md#technical-adr-0016-decision).

<a id="concept-adr-0016-alternatives"></a>
## Alternatives

**Keep fixed facade and command waits.** Rejected because any fixed value is
truthful for only part of the admitted configuration range.

**Let callers supply arbitrary timeouts or query Local configuration.** Rejected
because callers could undercut the session fact and Core would couple to one
executor implementation.

**Use process-local admission state only.** Rejected because it cannot order two
Local instances sharing one durable root or survive restart.

**Put executor admission and receipt authority in the Core Store, or introduce
a pluggable executor-ledger behaviour.** Rejected for M2. A Store-backed ledger
would improve backend portability and could reuse Store transaction machinery,
but it would make local effect permission depend on Core/session availability,
latency, and trust while still needing a same-host authority that owns the
worker and filesystem sync boundary. A pluggable ledger would avoid fixing one
backend, but it would create a new cross-application contract, conformance
matrix, recovery vocabulary, and dependency decision before the reference
Local boundary has proved one implementation. The selected private Local root
keeps process authority and its durable admission fact in the same edge domain;
Core receives only the validated bounded consequence. A future backend may
generalize that boundary through a separately accepted contract and migration.

**Signal sampled PIDs or process groups.** Rejected because observation data is
not durable actuation authority and identifier reuse can redirect cleanup.

**Automatically reap stranded root claims or open entries.** Rejected because
elapsed time and process absence do not prove that no effect or late writer
survives.

**Authenticate the root against administrator or snapshot rollback.** Rejected
for M2. The chosen local boundary trusts the root as one atomic unit; stronger
anti-rollback authority needs a different external trust source and migration
decision.

Technical depth: [Alternative failure modes](0016-configured-cancellation-observation-technical.md#technical-adr-0016-alternatives).

<a id="concept-adr-0016-consequences"></a>
## Consequences

- Operators get one cleanup value that survives recovery and truthfully sizes
  executor observation, result return, terminal rendering, and the CLI backstop.
- Embedders gain configured cancellation and prepared-recovery entries while
  legacy defensive entries remain available.
- `JobRequest`, session status, genesis, receipt, and the Local durable ledger
  gain versioned fields and records; M2 is unreleased, so no released data
  migration is promised.
- Local may refuse availability or quarantine an entire root after ambiguous
  filesystem, helper, or cleanup failure. This is the cost of preventing a
  duplicate effect without external reconciliation authority.
- Large admitted durations remain exact but can produce correspondingly long
  observation windows. Timer implementation limits do not silently cap them.
- Rollback is an operator procedure: use the prior source and a fresh empty state
  root only after every Local instance, guard, captured worker group, and other
  effect authority from the old generation has positively terminated. If that
  termination cannot be proved, the operator must reboot the host before
  activating the fresh root. The old root remains quarantined; a root containing
  the new generation or genesis is not downgraded or rewritten. M2 has no
  cross-root registry and does not claim that a Local opened only on a different
  path can discover or automatically refuse the unsafe procedure.
- Closure requires formula, clock-domain, compatibility, durable-record,
  concurrency, fault-injection, security-plane, recovery, and real-path
  evidence described in Technical depth.

Technical depth: [Compatibility, rollback, and evidence](0016-configured-cancellation-observation-technical.md#technical-adr-0016-consequences).

## Links

- [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept)
- [ADR 0011](0011-session-input-algebra-and-streaming.md#concept)
- [ADR 0012](0012-executor-cancellation-capability.md#concept)
- [ADR 0015](0015-artifact-object-and-use-identity.md#concept)
- [ADR 0017](0017-durable-context-admission-budget.md#concept)
- [Concept vision](../vision.md#concept)
- [Technical vision](../vision-technical.md#technical-depth)
