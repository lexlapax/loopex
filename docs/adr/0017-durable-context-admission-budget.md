# 0017. Durable context and record admission budgets

<a id="concept"></a>
## Concept

Technical depth: [Budget algebra, durability, and evidence](0017-durable-context-admission-budget-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-31
- **Decision owner:** Maintainer
- **Prerequisite for:** proposed `M2` Amendment 4
- **Supersedes:** 0010
- **Supersedes:** 0011
- **Supersedes:** 0013

The ADR 0010 supersession is limited to its claim that the repository estimator
never undercounts every provider tokenizer, the provider-conservative identity
attached to that claim, the context descriptor's scalar `source_reference`
shape, the tool-descriptor digest and cost preimage, and the project-resource
receipt's formerly open detail map and closed decline-reason set. This decision
charges a tool descriptor over the exact model-facing projection rather than its
larger retained definition and replaces the project receipt with the exact
versioned shapes in Technical depth. It defines the estimator as deterministic
admission policy rather than a provider-capacity guarantee. Its exact identity
becomes `loopex.context_bytes.v1`; the one-token-per-three-canonical-bytes
algorithm is unchanged, but the new name and version prevent a retained policy
measurement from inheriting the old provider-conservative meaning. Staging
failure rather than `bound_reached`, untrimmed history, the existing project
trust decisions, and whole-class optional project-resource withholding remain
in force.

The ADR 0013 supersession is limited to its prompt-admission record kind and key
set and its exhaustive enumeration of successor reducer state as the three
declared bounds. This decision changes that prompt record to
`prompt_admitted_v2` and makes reducer state inherit those same three bounds plus
the separate context-admission value, without making the new value a fourth
`Loopex.Bounds` member. The terminal record still duplicates none of those
values. ADR 0013's three bound meanings, deterministic promotion, and
deadline-at-first-staging rule remain unchanged.

The ADR 0011 supersession is limited to the accepted prompt-admission record
kind as incorporated through ADR 0013 and to the private/public failed-terminal
projection, which now carries the bounded context dimension, observation, and
limit beside the existing category and retryability value. It does not restore
ADR 0011's superseded promotion-record copy of run configuration. The atomic
outcome, `run.finished`, steer resolution, queued-follow-up promotion or
session-settlement rule remains unchanged; reducer state simply inherits the
new value as ADR 0013 now specifies. The queued follow-up record and command
input algebra stay exact, but every would-be accepted content-bearing command
now preflights its exact durable command record and any deterministic
content-bearing public event it can produce. An over-limit candidate commits
the neutral compact command-admission refusal in Technical depth. This does not
change `(session_id, command_id)` idempotency: command identity remains exactly
what the operator submitted, while resolved run configuration is retained
beside it and never folded into that identity. Abort, streaming, and every
non-context terminal projection remain unchanged.

Provider-attempt authority, callback error classification, reply settlement,
usage accounting, retry, and crash recovery are deliberately outside this
decision. ADR 0018 receives the exact staged request and digest after this ADR's
admission transaction succeeds and owns that boundary exclusively.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0017-context"></a>
## Context

ADR 0010 requires measured per-class and total context budgets before provider
dispatch, but names no committed total. The implementation can therefore retain
an exact receipt while enforcing no context-admission policy at all.

A token limit alone is insufficient. The exact staged request and its receipt
are one durable Store item with a 65,536-byte ceiling. Provider-visible content
cost does not include every receipt and envelope member: complete tool
definitions, bounded source provenance, the canonical request bytes, and the
semantic request all occupy durable space. A request can therefore fit every
token ceiling yet overflow the Store record before the runtime can retain the
staging fact it promised.

The cumulative run token budget cannot fill either gap. It answers how much
input and output a whole run may spend across turns. A context budget answers
how large one exact provider request may be. A record budget answers whether the
durable fact describing that request can be committed. Conflating the three
produces the wrong outcome and lets recovery evaluate identical history under a
different process default.

Technical depth: [The two missing admission dimensions](0017-durable-context-admission-budget-technical.md#technical-adr-0017-context).

<a id="concept-adr-0017-decision"></a>
## Decision

**Every run commits one `context_token_budget`, and every staged request must
also fit the Store's fixed record-byte ceiling.** The token budget is a positive
unsigned 64-bit whole-estimated-token ceiling for the exact provider-visible request under the
repository's recorded estimator, separate from the run's cumulative
`token_budget`. It is an admission policy, not a guarantee about a selected
provider model's actual tokenizer or context window. Prompt admission commits
it. A queued follow-up
retains only its accepted input algebra; promotion inherits the active run's
committed context budget beside its other three inherited bounds, and recovery
reuses it. No provider adapter, coordinator restart, or new command default may
replace it after admission.

That top-level value is a default only when a new prompt admits a run. Ordinary
embedded recovery neither compares a caller default with nor substitutes it for
an already-active run. Prepared owner status exposes the active run's committed
value. For reference `resume` and `cancel`, omitting
`--context-token-budget` accepts that retained value and never compares the
Composition default. After ADR 0016's cleanup-period comparison has matched, an
explicit unequal context value abandons the prepared owner before activation or
abort admission. Confirmed abandonment returns
`{:error, :context_token_budget_configuration_conflict}`; unconfirmed
abandonment returns
`{:error, {:context_token_budget_configuration_conflict_owner_unconfirmed,
abandon_reason}}`. If both explicit values differ, the cleanup-period conflict
wins first. A settled session has no active-run context conflict: nil status is
never compared with an explicit value or abandoned for mismatch. The explicit
value, or the reference default when omitted, remains only the default for a
later newly admitted prompt.

The public attachment snapshot is versioned with the active run's phase as well
as its identity. An operator attaching after prompt admission but before the
first staged request can therefore distinguish an admitted, unstaged run from a
started one, and recovery can validate the later start or a pre-staging finish
without inventing an event.

Command replay is decided before any current process default is resolved. A
known command ID with the same normalized operator input returns its original
durable result; a changed input conflicts. Only a new settled prompt resolves
run configuration. Every semantically admissible prompt, steer, or follow-up
must preflight its exact accepted command record, every exact normalized
unstamped public-event payload that command deterministically emits, and every
deterministic future bound-terminal record/event shape that command can make
reachable before any is committed. An otherwise valid command whose record, promoted-message event, or
future terminal carrying an existing positive bound cannot fit is refused
before any run, model task, executor job, effect, or queue work with one compact
durable `command_admission_too_large` result and no public event. This
preserves the existing input and positive-integer bound domains without
pretending every in-memory value is persistable or letting a later default
change alter replay.

Core Runtime accepts one required top-level `:context_token_budget` option; it is
not a member of `:bounds`, session genesis, or command input. The reference
composition and CLI expose the same top-level option and supply a documented
policy default of 8,192 estimated tokens when their host or operator omits it.
This is an operator convenience and a bounded reference policy, not proof of
Store safety or model capacity. A direct embedder must choose a value and may
choose another positive value for its own risk policy. Supplying a malformed,
non-positive, or above-unsigned-64-bit value returns
`invalid_context_token_budget` before Runtime start rather than silently
selecting the default.

Estimated token cost is measured over the exact canonical provider-visible
context members: messages and canonical `ToolDefinition.model_facing/1`
projections in their final order. It does not claim to charge model identity,
sampling, deadline, continuation, provider envelope, or provider translation,
and every receipt names the estimator identity and version.
The old `loopex.conservative_bytes.v1` identity is never written into a new
context receipt or compact refusal.
The reference system prompt plus four active tool projections currently measures
799 tokens under the repository estimator and stays below the accepted
1,000-token base ceiling. The complete tool-definition bytes remain in the
staged durable request for reconstruction; their storage cost belongs to the
record-byte check rather than being misreported as provider context. Tool
descriptors use the model-facing projection for content digest, byte cost, and
token cost, while their source reference retains the full definition digest and
generation identity. Changing storage-only tool metadata therefore changes
retained source identity and record bytes, not provider-estimated context.

That estimator is not a billing fallback. ADR 0018 owns provider usage
normalization and conservative cumulative accounting; it may consume the
inherited committed cumulative `token_budget` allowance but cannot reinterpret
the context estimate as a provider invoice.

ADR 0010's per-class limits remain distinct from the total. The reference
`system` ceiling stays 1,000 tokens with ADR 0010's strict rule: one below fits,
while exactly 1,000 and anything above refuse. The `project_resource` ceiling is derived
from the exact canonical wrapped block at the accepted 65,536-byte intake
maximum under the repository estimator; it currently evaluates to 21,885
tokens. It is recomputed from that canonical maximum rather than copied as an
independent configuration literal. A class must fit its own ceiling and the
whole provider-visible request must fit the run's committed total.

With M2's zero-or-one-entry project-resource shape and equal per-file and class-total intake
ceilings, every admitted block is at or below that derived class ceiling. The
class check is therefore a proved future-shape guard, not an independently
reachable refusal branch in this milestone. The committed total and exact Store
record limits are the independently reachable staging constraints.

The second limit is fixed, not host-owned:

```text
context_record_byte_ceiling = Store maximum item bytes = 65_536
```

Before a Store transaction, core constructs the exact final
`model_request_committed` record and computes the same deterministic encoded
byte cost the Store validates. Its self-size field is resolved by the canonical
fixed-point construction in Technical depth, then the final normalized record is
measured once more and must equal the embedded value. Passing the token budget
never bypasses this preflight. The successful context receipt records both
observed values and both limits.

The project-resource 65,536-byte limit remains an intake and denial-of-service
ceiling, not a promise that every maximum-sized file can fit one staged record.
After bounded shell, label, containment, and O(1) declared-size checks, the
runtime applies per-entry and total byte limits before hashing any content; an
oversized body is never traversed merely to prove the digest it already cannot
admit.
Its token ceiling is the derived class limit above, not an unrelated host-owned
constant. If adding the optional project class exceeds the total token budget or
the exact record-byte ceiling, the whole class is withheld, its declined receipt
names the dimension, observed value, and limit, and the task continues. It is
never truncated. A matching empty manifest is truthfully `staged` with no
descriptor or cost; it is distinct from no manifest. Under M2's zero-or-one flat binary block, optional project content
cannot independently cause a depth or collection-cardinality failure before the
byte ceiling: required-only structure and a deterministic record-size lower
bound are proved before optional evaluation, including the exact implication at
the descriptor-list cardinality edge. Those dispositions are not claimed. The derived class guard is
still evaluated and retained, so a later multi-label shape cannot silently turn
it into dead prose.

If required system context reaches or exceeds its strict class ceiling, or
required session, steer, or tool-definition context exceeds the total token limit
or any Store record
byte, depth, or cardinality limit, staging makes no provider call and ends the run
`failed(context_budget_exceeded, false)`. The same Store transaction retains a
compact receipt, the failed terminal, and its public event. The receipt carries
one ordered-descriptor digest plus bounded counts, totals, limits, estimator
identity, and project disposition; it never repeats the descriptor list or the
oversized bodies that caused refusal. It never reports
`bound_reached(:token_budget)`, because cumulative usage did not reach a run
bound. It is not retryable within the same run because a retained terminal is
final and the same run never re-enters staging after it; changing context,
configuration, or policy requires a newly admitted run. The compact refusal is
not claimed to retain every live preimage needed to reconstruct the rejected
candidate.

The private terminal and public `run.finished` failure projection each name
exactly the category, `retryable: false`, dimension, observed value, and limit.
An operator can therefore distinguish `system_class_tokens`, `context_tokens`,
`context_record_bytes`, `context_record_depth`, and
`context_record_cardinality` without receiving descriptor bodies or private
source identity. Oversized command admission mutates no run or queue and emits
no public event; its correlated command result names `command_record_bytes`,
`future_bound_record_bytes`, or—for a promoted follow-up only—
`command_event_bytes`, together with the observed bytes and Store limit. An
accepted prompt record strictly dominates its immediate user-message event, so
that event is still measured as defense in depth but is not an independently
reachable refusal dimension.

Technical depth: [Exact two-dimensional admission](0017-durable-context-admission-budget-technical.md#technical-adr-0017-decision).

<a id="concept-adr-0017-alternatives"></a>
## Alternatives

**Use only a token budget.** Receipt and envelope bytes are not all token-charged,
so a request can pass and then fail as `item_too_large`. Not taken.

**Use only the Store limit.** Durable bytes would be bounded, but a host could
still dispatch a request larger than its chosen context-admission policy. Not
taken.

**Require every reference host to supply a token limit.** This is the narrowest
configuration contract, but makes the shipped reference stack incomplete until
every operator chooses a value. The explicit host option remains available; the
reference policy chooses a bounded default without claiming provider capacity.
Not taken.

**Reuse the cumulative run token budget.** That conflates per-request capacity
with whole-run spending and produces the wrong terminal meaning. Not taken.

**Make provider-specific tokenizers and capacity metadata part of the runtime
contract.** That could estimate a selected provider more closely, but it would
move provider catalog and tokenizer ownership into core and still would not
prove what a provider billed. That is a broader provider contract than M2 needs.
Not taken.

**Trim history or project content to fit.** Session truth would become a
different conversation, and a truncated instruction file is a different
instruction file. Optional project content may be wholly withheld with an
explicit receipt; no class is silently repaired. Not taken.

Technical depth: [Alternative costs](0017-durable-context-admission-budget-technical.md#technical-adr-0017-alternatives).

<a id="concept-adr-0017-consequences"></a>
## Consequences

Runtime configuration, promotion, and recovery gain one unreleased scalar. The
prompt-admission kind and key set and successful context/project receipts are
replaced by the exact versioned schemas above; the compact context refusal and
its bounded failed-terminal projection are new. Public attachment snapshots
advance from the prior unreleased three-member projection to the exact
revision-2 identity-and-phase shape. Existing callers that match the map exactly
must update; attachment snapshots are ephemeral outputs rather than durable
replay input, so no Store migration or phase inference is performed. The reference command,
composition, operator documentation, and compatibility inventory expose those
changes. The queued follow-up record retains ADR 0011's exact three-member input
algebra. Staging gains the exact structural and record-byte preflight. The three
existing run bounds and their `bound_reached` algebra do not change; context
admission adds the distinct failed outcome defined here.

Development receipts carrying `loopex.conservative_bytes.v1` retain their old
meaning; the new reducer does not relabel them. New receipts use
`loopex.context_bytes.v1`, and unknown estimator identities fail unavailable.

A host can run many turns under a large cumulative budget while selecting a
smaller context-admission budget, or the inverse. An operator whose required request no
longer fits sees a staging failure naming whether provider context or durable
record capacity was exceeded, rather than a normal bounded stop or an incidental
Store error.

The prior runtime accepted positive run-bound integers until persistence itself
failed on a sufficiently large encoded value. This decision keeps those values
semantically valid but makes representability an explicit, durable prompt
admission result. No bound is silently narrowed to uint64, and replay never
re-evaluates the old command against a newer process default.

Provider settlement may stop a run earlier than its actual invoice required,
but that consequence belongs to ADR 0018's conservative recovery decision, not
to this context estimator. This ADR supplies the exact admitted request, budget,
and Store measurement boundary that settlement consumes.

Old development prompt records without the committed value fail closed as
unavailable rather than receiving a new process default. New prompts use
`prompt_admitted_v2` and oversized content-bearing commands use
`command_admission_refused_v1`; the prior reducer recognizes neither, including a
refusal-only prompt, steer, or follow-up history, so a rollback also refuses new histories instead of
silently dropping their budget. The new reducer likewise refuses the legacy
accepted prompt kind. Rollback
removes the value, propagation, preflight, enforcement, and revision-2 snapshot
projection together. No provider
reply, artifact, or workspace file migrates.
If ADR 0016's receipt-fitting path or ADR 0018's settlement-preflight path is
also implemented, rollback preserves the Store-owned
normalization/measurement API until every consumer is removed, or removes the
dependent units atomically. Removing the API first is not a deployable
intermediate state.

Acceptance of this ADR alone changes no M2 plan or gate byte. `M2` Amendment 4
must explicitly replace the accepted estimator guarantee, declare this ADR as a
closure prerequisite, and lock the context-admission and Store-measurement
evidence below before dependent implementation or closure. Provider attempt,
settlement, accounting, and recovery obligations belong to ADR 0018 and must be
declared and locked separately.

`M2` does not close until boundary cases prove the token budget and every Store
byte, depth, and cardinality dimension, optional project withholding,
required-context failure, compact refusal retention and commit-unknown replay,
zero provider dispatch on every refusal, exact successful receipt retention,
and recovery/promotion reuse of the committed value.

Technical depth: [Compatibility, rollback, and evidence](0017-durable-context-admission-budget-technical.md#technical-adr-0017-consequences).

## Links

- [ADR 0010 — Provider continuation and exact context staging](0010-provider-continuation-and-context-staging.md#concept)
- [ADR 0018 — Provider attempt authority and recovery](0018-provider-attempt-authority-and-recovery.md#concept)
- [M2 technical plan](../plans/M2-technical.md#technical-depth)
- [Vision model boundary and context pipeline](../vision-technical.md#technical-vision-model-boundary)
- [Vision verification and measured budgets](../vision-technical.md#technical-vision-verification)
