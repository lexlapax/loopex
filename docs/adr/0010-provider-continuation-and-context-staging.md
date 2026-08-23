# 0010. Provider continuation and exact context staging

<a id="concept"></a>
## Concept

Technical depth: [Canonical request, conversation record, and termination mechanics](0010-provider-continuation-and-context-staging-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-23
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` acceptance

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0010-context"></a>
## Context

`M1` proved the property that matters most about a model call: the adapter
receives exactly the bytes that were committed with the call's intent. A
canonical request digest is committed per turn, and the real-provider lane
asserts the adapter saw exactly those committed bytes. That property must
survive `M2` intact.

What `M1` did not build is a conversation. The model request is literally one
message, `[%{"role" => "user", "content" => work.content}]`. Turn two's content
is a string Loopex synthesizes, `"Tool <name> completed: completed"`. The model
therefore never sees the original prompt on its second turn, never sees its own
prior assistant message, and never sees any real tool output. The loop does not
terminate on a condition either: turn one forces the single configured tool
through `tool_choice`, and turn two is sent with an empty tool list and
`tool_choice: "none"`, so it cannot request anything and the run ends by
arithmetic. `max_tokens` falls back to 128 when unset.

That is a correct demonstration of durability and an incorrect agent loop. It is
also the reason the two properties in this decision are one decision: once a
request becomes a conversation projected from durable records, "the exact
canonical context committed with its intent" has to mean an ordered structure
rather than one string, and once `tools: []` no longer stops the loop, something
real has to.

The v0.1 rung also raises a question `M1` could ignore. A run that can call
tools repeatedly can call them without bound. A loop with no declared maximum
turn count, token budget, or deadline is a loop that ends when a provider bill or
an operator does, and neither of those produces a truthful terminal outcome.

Finally, the vision's context pipeline is a permanent seam with five stages and
an explicit warning that memory truth, retrieval intelligence, and prompt
selection belong to extensions and hosts. The roadmap lists context pipeline
contracts as a separate decision. `M2` needs some of that seam and must not
quietly absorb the rest.

Technical depth: [What M1 commits today and the three defects](0010-provider-continuation-and-context-staging-technical.md#technical-adr-0010-context).

<a id="concept-adr-0010-decision"></a>
## Decision

- **A turn's canonical model request is one immutable ordered value, committed
  before dispatch.** It carries exact model identity, the ordered message list,
  the ordered active tool-definition generations, the explicit sampling bounds,
  and the continuation binding. It is canonicalized by a protocol-versioned
  function, digested, and committed in the same transaction as the model-call
  intent and its context receipt. Only after that commit may the adapter receive
  the request, and it receives exactly those bytes. `M1`'s real-provider
  assertion is widened from one message to the whole request, never relaxed.
- **No implicit sampling default.** `max_tokens` is a declared committed value.
  The `M1` fallback of 128 is removed, and a session configured without a bound
  is refused at start rather than silently truncated at dispatch.
- **The conversation is durable, per element, in source order.** The admitted
  user prompt's exact bytes, each complete assistant message with the complete
  tool calls it made, and each tool result with its `tool_call_id`, terminal
  outcome, and bounded model-facing content are separate committed elements of
  the session journal. Nothing that the model will see exists only in coordinator
  memory.
- **Complete tool results correspond to complete tool calls, in source order.**
  Every committed result element names exactly one committed call element from
  the immediately preceding assistant message. Results commit in the assistant's
  original call order regardless of completion order. The next turn may not be
  staged while any call from that message lacks a committed terminal result. A
  malformed, truncated, or duplicated tool call never becomes a call element and
  never executes.
- **The next request is projected from the journal, never synthesized.** The
  message list is a deterministic projection of committed elements in commit
  order. No summary string stands in for a real result, no message is derived
  from live process state, and recovery after a restart projects the identical
  list. Where a staged request already exists for an unresolved model intent,
  the staged bytes are dispatched unchanged; missing staged bytes fail closed as
  unavailable rather than being recomputed.
- **A run terminates on a real condition.** It ends when the assistant message
  contains no tool calls, when a declared bound is reached, or through
  cancellation or unrecoverable failure. The hardwired two-turn rule and the
  `tools: []` termination trick are removed.
- **Three declared bounds, all committed with the run.** Maximum model turns,
  cumulative token budget across the run, and a wall-clock deadline each have a
  configured value with a default. Every bound is checked before the next
  request is staged, so exceeding one costs no provider call.
- **Reaching a bound is its own truthful terminal outcome.** It commits as
  budget exhaustion in the closed outcome algebra, naming which bound was
  reached and the observed value. It is never reported as completion, and no
  assistant message the model did not produce is ever written into canonical
  history. The partial conversation stays durable and a new run may continue
  from it.
- **Injected context is provenance-typed, budgeted, and receipt-journaled.**
  `M2` stages exactly three provenance classes: session lineage, the versioned
  system prompt with the active tool definitions, and a fixed reference
  project-resource stage. Every staged block carries a source reference, content
  digest, provenance class, trust class, and byte and token cost, and the
  receipt records the final ordered block descriptors. Per-class and total
  budgets are enforced before dispatch.
- **A project-local resource enters context only through an explicit
  deterministic trust decision.** The decision binds workspace identity, the
  resolved resource set, and its digests; a changed root, resolved set, or
  digest invalidates it. Headless operation without a matching positive decision
  fails closed. Nothing in any injected block changes the active tool set, tool
  policy, budgets, bounds, or grants — typed delimiters are input structure, not
  an authority boundary.
- **The pluggable context pipeline is explicitly deferred with a named
  acceptance point.** `M2` implements lineage projection, budgeted assembly, and
  exact staging with receipts, using one fixed reference candidate stage and no
  transformer or selector stage. Registered candidate providers, versioned
  transformers, selectors, observers, recall stores, and prompt libraries remain
  the separate context pipeline contracts decision, which must be accepted
  before any milestone admits an extension-supplied context provider. The
  receipt shape carries provider and revision identity now so that landing the
  pipeline does not migrate it.
- **Compaction, branching, and forking stay out of scope.** `M2` projects full
  lineage. A session that outgrows its budget ends a run on budget exhaustion
  rather than dropping or summarizing history, and compaction checkpoints remain
  a durable-service decision.
- **The prompt budget is measured, not asserted.** The reference system prompt
  plus the active bootstrap tool definitions must measure under 1,000 tokens
  before project context, computed from the exact canonical bytes with a
  recorded tokenizer identity. The measurement is retained evidence and the
  number is reported whether it passes or fails; a review reading is not
  evidence.
- **Provider-native continuation stays an optional adapter-private sidecar, and
  `M2` stores none.** Core carries portable canonical history only. The
  request's continuation binding exists and is empty in `M2`, and no adapter may
  require it. Changing the model within a run is refused in `M2`, so no
  continuation compatibility rule is asserted without evidence.

This decision changes nothing in
[ADR 0006](0006-store-transaction-and-owner-epoch.md#concept),
[ADR 0007](0007-local-executor-grant-job-receipt.md#concept), or
[ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept).
Conversation elements, staged requests, and context receipts are ordinary
session-domain records written only by the one serial session owner, fenced by
owner epoch and journal version like every other record. A successor owner
projects the same conversation from the same durable records, which is precisely
why no message may live only in process state.

Technical depth: [Exact request, element, projection, and bound contract](0010-provider-continuation-and-context-staging-technical.md#technical-adr-0010-decision).

<a id="concept-adr-0010-alternatives"></a>
## Alternatives

**Make the provider's own continuation state the durable conversation.** Send
back a response identifier or a provider-stored thread instead of replaying
messages. It is cheaper per turn and it preserves reasoning signatures and
provider tool-call metadata for free. It is not recommended: it makes durable
session truth a foreign opaque handle Loopex cannot project, branch, migrate, or
replay, it becomes invalid on a model or provider change, and it would make the
restart and replay property `M1` just proved depend on an external service
staying available and honest. The sidecar keeps the benefit available as an
adapter-private optimization without making it the truth.

**Keep synthesizing a result summary per tool call.** Extend what `M1` does with
a better string. It is not recommended: it is the exact defect this decision
closes. It discards the model's own prior message, replaces observed output with
Loopex's paraphrase, and makes correctness depend on a formatting choice nobody
reviewed as a product decision.

**Bound the loop by token budget alone.** A single budget is simpler than three.
It is not recommended: cheap tool-call cycles can spin for a very long time
inside a token budget, turn count is the bound a user reasons about, and
wall-clock is the bound that protects an operator from a stalled provider.

**Fabricate a closing assistant message when a bound is reached.** It produces a
tidier transcript. It is rejected: a message the model never produced would be
indistinguishable from a real one on replay, and canonical history would then
contain a Loopex assertion presented as model output.

**Implement the pluggable pipeline now.** The seam is already designed and
building it here would avoid a later change. It is not recommended: with no
memory extension, no retrieval store, and no second source of blocks, every
provider, transformer, and selector abstraction would unify exactly one
implementation, which the minimalism budget forbids. The receipt shape is what
protects the seam in the meantime.

**Add compaction or summarization now.** It would let long sessions continue
rather than end on budget. It is not recommended: a summarizer chosen without
measurement embeds an unevaluated quality decision into the kernel, and the
honest small answer is to end the run truthfully and let the operator start
another.

Technical depth: [Alternative analysis](0010-provider-continuation-and-context-staging-technical.md#technical-adr-0010-alternatives).

<a id="concept-adr-0010-consequences"></a>
## Consequences

Request canonicalization becomes protocol-versioned truth from the first
journal. Once a session exists, changing how messages are canonicalized changes
every committed digest, so the version tag must be recorded with each staged
request from day one and a change becomes a versioned migration with fixtures
rather than an edit. This is permanent.

Durable session size becomes proportional to tool output. Complete tool results
are journaled, which is what makes replay honest and what makes storage grow.
The bounded-output and artifact-spill rules in
[ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) are the only thing
keeping that finite, so the two decisions are coupled: accepting either without
the other leaves a real hole.

Every turn sends the whole conversation, so token cost per run grows with the
square of the turn count. The turn, token, and time bounds make that finite but
do not make it cheap. Measuring it is what will later justify compaction, and
until then long sessions end on budget exhaustion rather than degrading — a real
v0.1 usability limit that documentation must state rather than soften.

Refusing implicit defaults makes the runtime harder to start. A session now
needs an explicit token bound, explicit run bounds, and, from the paired
decision, an explicit policy. That friction is deliberate and it will show up as
configuration surface in the reference CLI.

Deferring transformers and selectors leaves receipt fields that look redundant
today, because `M2` fills them with one fixed reference identity. The cost is a
slightly wider receipt now in exchange for not migrating every retained receipt
when the pipeline lands.

Refusing a mid-run model change is a visible limitation of the reference CLI
against the flows the vision eventually expects of it, and it is the price of
not asserting a continuation compatibility rule before there is evidence for
one.

Technical depth: [Operational consequences](0010-provider-continuation-and-context-staging-technical.md#technical-adr-0010-consequences).

<a id="concept-adr-0010-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists and no installed base exists. Version 0.1.0 is a
tagged source version with no Hex publication, so the canonical request format,
the conversation element shapes, the context receipt, and the bound outcomes are
all experimental and freeze nothing.

`M1` journals are not migrated. `M1`'s synthesized second-turn record has no
successor form, because a synthesized string is not a degraded version of a real
tool result, and `M1`-owned test roots are discarded.

Rollback before closure removes the conversation elements, the bounds, the
budget outcome, and the context receipt together, returning to `M1`'s
single-message request. It cannot be partial: the termination condition depends
on the assistant message shape, and the assistant message shape exists only
because the conversation record does. After the 0.1.0 tag, a change to
canonicalization, an element shape, or the receipt is an additive versioned
change with fixtures and a projection rule for older journals, never an edit to
what a recorded digest meant.

Technical depth: [Format, migration, and rollback mechanics](0010-provider-continuation-and-context-staging-technical.md#technical-adr-0010-compatibility).

## Links

- [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) — the paired
  decision supplying tool definition generations, bounded results, and the
  cancellation algebra this record replays
- [ADR 0006](0006-store-transaction-and-owner-epoch.md#concept) — the
  transaction and owner-epoch contract these records commit under
- [ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept) —
  the succession recovery this projection must survive without change
- [ADR 0007](0007-local-executor-grant-job-receipt.md#concept) — the one
  canonical request digest identity this decision extends to a full request
- [Vision model and context boundary](../vision.md#concept-vision-model-boundary) — the governed pipeline and what belongs to hosts
- [Vision loop semantics](../vision-technical.md#technical-vision-loop-semantics) — one run, input queues, and the split payload rule
- [AGENTS.md](../../AGENTS.md) — durability and recovery truth, truth planes,
  credentials and context, and the smallest sufficient system
