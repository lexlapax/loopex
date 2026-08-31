# 0017. Durable context and record admission budgets

<a id="concept"></a>
## Concept

Technical depth: [Budget algebra, durability, and evidence](0017-durable-context-admission-budget-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-31
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` closure
- **Supersedes:** 0010
- **Supersedes:** 0013

The ADR 0010 supersession is limited to its claim that the repository estimator
never undercounts every provider tokenizer and to the two cumulative-accounting
fallback rows that depend on that claim when provider usage is absent, partial,
or unavailable after dispatch. This decision defines the estimator as
deterministic admission policy rather than a provider-capacity guarantee. A
dispatched turn without complete provider usage consumes the run's entire
remaining cumulative token budget and is marked `estimated`, so no second
provider call can spend behind an unknown first bill. Complete reported usage,
the cumulative sum and subtotals, staging failure rather than `bound_reached`,
untrimmed history, and optional project-resource withholding remain in force.

The ADR 0013 supersession is limited to its exhaustive enumeration of prompt and
promotion configuration as the three run-stopping bounds. This decision adds a
separate context-admission value without making it a fourth `Loopex.Bounds`
member. ADR 0013's three bounds, deterministic promotion inheritance, and
deadline-at-first-staging rule remain unchanged.

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
whole-estimated-token ceiling for the exact provider-visible request under the
repository's recorded estimator, separate from the run's cumulative
`token_budget`. It is an admission policy, not a guarantee about a selected
provider model's actual tokenizer or context window. Prompt admission commits
it. A queued follow-up
retains only its accepted input algebra; promotion inherits the active run's
committed context budget beside its other three inherited bounds, and recovery
reuses it. No provider adapter, coordinator restart, or new command default may
replace it after admission.

The reference composition supplies a documented policy default of 8,192
estimated tokens when its host omits the option. This is an operator convenience
and a bounded reference policy, not proof of Store safety or model capacity. An
embedder may choose another positive value for its own risk policy. Supplying a
malformed or non-positive value refuses runtime start rather than silently
selecting the default.

Estimated token cost is measured over the exact canonical provider-visible
messages and the canonical `ToolDefinition.model_facing/1` projections in their
final order, and every receipt names the estimator identity and version.
The reference system prompt plus four active tool projections currently measures
779 tokens under the repository estimator and stays below the accepted
1,000-token base ceiling. The complete tool-definition bytes remain in the
staged durable request for reconstruction; their storage cost belongs to the
record-byte check rather than being misreported as provider context.

That estimator is not a billing fallback. When a dispatched turn returns no
provider usage, only partial usage, or no complete reply, its cumulative charge
is `token_budget - cumulative_tokens_before_call`, marked `estimated`. The
charge therefore exhausts the committed run budget before another provider
dispatch. It is a conservative run-control charge, not a claim about the
provider's exact invoice; complete provider usage continues to be charged and
marked `reported` exactly as ADR 0010 specifies.

ADR 0010's per-class limits remain distinct from the total. The reference
`system` ceiling stays 1,000 tokens. The `project_resource` ceiling is derived
from the exact canonical wrapped block at the accepted 65,536-byte intake
maximum under the repository estimator; it currently evaluates to 21,885
tokens. It is recomputed from that canonical maximum rather than copied as an
independent configuration literal. A class must fit its own ceiling and the
whole provider-visible request must fit the run's committed total.

With M2's one project-resource label and equal per-file and class-total intake
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
byte cost the Store validates. Passing the token budget never bypasses this
preflight. The successful context receipt records both observed values and both
limits.

The project-resource 65,536-byte limit remains an intake and denial-of-service
ceiling, not a promise that every maximum-sized file can fit one staged record.
Its token ceiling is the derived class limit above, not an unrelated host-owned
constant. If adding the optional project class exceeds the total token budget or
the exact record-byte ceiling, the whole class is withheld, its declined receipt
names the dimension and observed value, and the task continues. It is never
truncated. The derived class guard is still evaluated and retained, so a later
multi-label shape cannot silently turn it into dead prose.

If required system, session, steer, or tool-definition context exceeds its
class ceiling where one applies, the total token limit, or the record-byte
limit, staging makes no provider call and ends the run
`failed(context_budget_exceeded, false)`. The same Store transaction retains a
compact receipt, the failed terminal, and its public event. The receipt carries
one ordered-descriptor digest plus bounded counts, totals, limits, estimator
identity, and project disposition; it never repeats the descriptor list or the
oversized bodies that caused refusal. It never reports
`bound_reached(:token_budget)`, because cumulative usage did not reach a run
bound, and it is not retryable because identical committed history and limits
produce the same refusal.

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

**Keep using admission estimates when provider usage is incomplete.** Once the
estimator stops claiming provider-tokenizer conservatism, that fallback can
undercount a billed turn and authorize another call after the real run budget
was spent. Consuming the remaining committed budget fails safe and keeps the
uncertainty visible. Not taken.

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

Runtime configuration, the versioned prompt-admission record, promotion,
recovery, context receipts, the reference command/composition, and operator
documentation gain one unreleased field. The queued follow-up record retains
ADR 0011's exact three-member input algebra. Staging gains an exact record-byte
preflight and compact refusal receipt. The three run bounds and their terminal
algebra do not change.

A host can run many turns under a large cumulative budget while selecting a
smaller context-admission budget, or the inverse. An operator whose required request no
longer fits sees a staging failure naming whether provider context or durable
record capacity was exceeded, rather than a normal bounded stop or an incidental
Store error.

A provider response with missing or partial usage can stop a run earlier than
its actual bill required, because uncertainty consumes the remaining cumulative
budget. The alternative would authorize more externally billed work using a
repository estimate this decision explicitly does not claim is conservative for
that provider.

Old development prompt records without the committed value fail closed as
unavailable rather than receiving a new process default. New prompts use a
`prompt_admitted_v2` record kind the prior reducer does not recognize, so a rollback also
refuses new histories instead of silently dropping their budget. Rollback
removes the value, propagation, preflight, and enforcement together. No provider
reply, artifact, or workspace file migrates.

`M2` does not close until boundary cases prove both dimensions, optional project
withholding, required-context failure, compact refusal retention, zero provider
dispatch on every refusal, exact successful receipt retention, and
recovery/promotion reuse of the committed value.

Technical depth: [Compatibility, rollback, and evidence](0017-durable-context-admission-budget-technical.md#technical-adr-0017-consequences).

## Links

- [ADR 0010 — Provider continuation and exact context staging](0010-provider-continuation-and-context-staging.md#concept)
- [M2 technical plan](../plans/M2-technical.md#technical-depth)
- [Vision model boundary and context pipeline](../vision-technical.md#technical-vision-model-boundary)
- [Vision verification and measured budgets](../vision-technical.md#technical-vision-verification)
