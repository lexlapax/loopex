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

One part of that seam cannot be left abstract. §16.2 requires an explicit
deterministic admission decision for project-local resources, but a decision
needs something exact to decide about: which resources were resolved, in what
order, at what sizes, under which digests, who resolved them, and what the
operator saw before answering. Without those fixed, "an explicit trust decision"
is a sentence rather than a mechanism, and the first implementation would fix
them by accident — most likely by having core open a file, which §15.2 does not
permit it to do. They are founding trust requirements and belong in this
decision.

Technical depth: [What M1 commits today and the three defects](0010-provider-continuation-and-context-staging-technical.md#technical-adr-0010-context).

<a id="concept-adr-0010-decision"></a>
## Decision

- **A turn's canonical model request is one immutable ordered value, committed
  before dispatch.** It carries exact model identity, the ordered message list,
  the ordered active tool definitions, the explicit sampling bounds, and the
  reserved continuation field. It is canonicalized by a protocol-versioned
  function, digested, and committed in the same transaction as the model-call
  intent and its context receipt. Only after that commit may the adapter receive
  the request, and it receives exactly those bytes. `M1`'s real-provider
  assertion is widened from one message to the whole request, never relaxed.
- **The staged request carries complete tool-definition bytes, not references to
  them.** Each active tool contributes its full immutable definition — name,
  description, and parameter schema, canonicalized exactly as it is dispatched —
  carried together with its `{tool_id, version, digest}` generation identity. A
  staged request is therefore reconstructible and verifiable from the journal
  alone: a later registry edit, version bump, or removal changes neither the
  bytes that were dispatched nor the digest that covers them. Committing only
  the generation triple would leave a recorded digest depending on a mutable
  registry to mean anything, and would make replay after a tool is retired
  impossible.
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
- **The deadline is enforced inside the model call as well as between turns.**
  The run's committed absolute deadline instant is propagated into the
  supervised model call and bounds that call, so one long generation cannot
  outlive the bound an operator declared. A between-turns check alone is not a
  wall-clock bound: it lets a run exceed its deadline by as long as a provider
  holds a single connection open, which is exactly the stalled-provider case the
  bound exists to catch. There is no separate per-call timeout that may exceed
  the run deadline, so the two enforcement points can never disagree.
- **The deadline race is decided by committed journal order, and the committed
  outcome is the truthful one.** If a complete validated reply commits before
  the deadline abort is admitted, that turn is completed, its assistant message
  is canonical history, and the deadline then ends the run before the next
  request is staged. If the abort is admitted first, the model call is
  cancelled, no assistant message is written, and a reply arriving afterwards is
  retained truthfully as attempt evidence without becoming canonical history.
  Partial or streamed output never becomes a canonical assistant message under
  either order. This is the same completion/cancellation ordering rule the
  vision already fixes; the deadline is one more thing that can request the
  abort.
- **A committed bound is always enforceable; a missing provider usage report
  never disables one.** Provider-reported usage is preferred whenever it exists.
  Where a turn's reply carries no usage, that turn is accounted conservatively
  from the exact canonical bytes already committed for it, using the same
  repository-owned tokenizer identity the prompt budget measurement records, and
  the accounted value is marked as estimated rather than reported. A run that
  mixes both sources records both counts. Failing the session closed at start
  instead was rejected: usage reporting is observable only after a reply, so a
  start-time refusal would turn a budget into a provider allowlist and would
  exclude local and OpenAI-compatible endpoints that are otherwise usable.
- **A turn that produced no complete reply is charged its committed maximum
  output allowance, not zero.** Counting only the request bytes would make a
  cancelled or deadline-aborted long generation almost free against the token
  budget, and that is the case where a run can burn the most while recording the
  least. Partial streamed output is transient progress rather than durable
  truth, so there is no retained observed output count to charge; the committed
  `max_tokens` value is the most output that turn was authorized to produce, it
  is already committed with the request, and it is therefore charged in full and
  marked estimated. That is a second reason the sampling bound may not be
  implicit: an unstated `max_tokens` would leave an aborted turn with no
  conservative number to charge.
- **Reaching a bound is the run's own terminal outcome, not a failure.** The run
  commits `bound_reached`, the member the vision's closed run terminal set holds
  for exactly this case, and the terminal record names which bound was reached,
  the observed value against the declared limit, and how that value was
  obtained. It carries no failure category and no retryable flag, because
  nothing malfunctioned and no invariant broke: the run stopped where its
  operator configured it to stop, and the committed conversation is complete.
  It is not `completed` either, since the model did not stop on its own and the
  task is not known to be done. It is never reported as completion, and no
  assistant message the model did not produce is ever written into canonical
  history. The partial conversation stays durable and a new run may continue
  from it under freshly committed bounds.
- **Resuming an interrupted run and prompting a completed session are different
  operations with different rules.** Resuming an interrupted run keeps the run's
  identity, its committed bounds, and its staged bytes: the same request is
  redispatched as a new attempt under the same operation identity, nothing is
  recomputed, and the wall-clock deadline is the absolute instant committed with
  the run, so a run whose deadline passed while its owner was down commits
  `bound_reached` naming `:deadline` on recovery, without a
  provider call and without redispatching the staged bytes. Submitting a new
  prompt to a completed session starts a new run with a new identity, its own
  freshly committed bounds, and a projection over the whole retained lineage; it
  is admitted only while the session is settled, and it requires live ownership
  acquired through a fresh resume command identity under
  [ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept).
  Neither operation ever inherits the other's bounds.
- **Injected context is provenance-typed, budgeted, and receipt-journaled.**
  `M2` stages exactly three provenance classes: session lineage, the versioned
  system prompt with the active tool definitions, and a fixed reference
  project-resource stage. Every staged block carries a source reference, content
  digest, provenance class, trust class, and byte and token cost, and the
  receipt records the final ordered block descriptors. Per-class and total
  budgets are enforced before dispatch.
- **Core never resolves, holds, or reads a filesystem path; discovery belongs to
  the hand that owns the workspace.** Core holds the opaque workspace reference
  and nothing more, exactly as it does for tool execution. The host, or the hand
  that interprets that reference, performs the lookup and returns bounded plain
  data: one manifest entry per resolved resource carrying a workspace-relative
  label, a byte size, and a content digest, plus the bounded content bytes of
  each resource. Core verifies supplied content against its supplied digest and
  size, enforces the declared ceilings, and treats the relative label as a
  display string it never joins, resolves, or opens. Containment is enforced
  where the filesystem actually is, under the same rule
  [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) applies to tool
  paths, and reaches core as reported evidence; an entry the supplier does not
  report as contained within the workspace is refused rather than admitted. A
  core that resolved a real path would need brain-local filesystem access and a
  POSIX path, which is precisely what the opaque workspace reference exists to
  prevent and what would break the moment the hand is remote.
- **Project-resource discovery is fixed, shallow, and content-independent.** The
  reference stage names exactly one resource: `AGENTS.md` at the root of the
  canonical workspace. There is no recursion, no globbing, no user-level or
  home-directory resource, no repository-history-derived resource, and no
  configured path list. The rule is stated to the supplier and verified by core
  against what comes back: a manifest carrying anything other than that one
  permitted label is refused whole. Content never extends the resolved set: an
  import, include, or link inside an admitted resource is inert text, because a
  rule that let admitted content name the next file would let untrusted data
  choose what else gets trusted.
- **The resolved set is presented as an ordered manifest with a digest, and
  refused rather than trimmed when it exceeds its limits.** The manifest lists
  each resource by its workspace-relative label, its byte size, and its content
  digest, in canonical label order, and carries one manifest digest computed
  over the manifest together with the opaque canonical workspace identity. A
  resource above its declared byte ceiling, or a class total above the declared
  ceiling, fails closed with the observed sizes; it is never truncated into
  context, because a truncated instruction file is a different instruction
  file.
- **A project-local resource enters context only through an explicit
  deterministic trust decision, and Loopex owns the binding while the host owns
  the decision.** Core exposes the resolved manifest and its digest for display
  without admitting anything; the decision is supplied at session start and
  binds the opaque canonical workspace identity, host-supplied repository origin
  and revision where available, the manifest digest, trust scope, decision
  source, issuance, expiry, and revocation state. The interactive reference
  command shows the label, size, and digest of every resource and the manifest
  digest, then asks once; a headless run with no supplied decision matching the
  exact current binding stages the class empty and journals a declined receipt
  entry rather than refusing the session, so failing closed withholds content
  instead of withholding the runtime. `M2` writes no expiry and no revocation
  beyond the absence of a decision, but records both fields so a host-owned
  lifecycle lands without migrating a retained receipt.
- **Any change to the binding invalidates it.** A different canonical workspace
  identity, a different repository revision where one is available, a resource
  added or removed from the resolved set, or any changed content digest produces
  a different manifest digest, and a decision bound to the old digest admits
  nothing. A previously trusted workspace identity is never itself a grant.
- **Nothing in any injected block changes the active tool set, tool policy,
  budgets, bounds, or grants.** Typed delimiters are input structure, not an
  authority boundary.
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
  lineage. A session that outgrows its budget ends a run at its declared bound
  rather than dropping or summarizing history, and compaction checkpoints remain
  a decision for the milestone whose long-lived sessions produce the measured
  token curve that justifies one.
- **The prompt budget is measured, not asserted.** The reference system prompt
  plus the active bootstrap tool definitions must measure under 1,000 tokens
  before project context, computed from the exact canonical bytes with a
  recorded tokenizer identity. The measurement is retained evidence and the
  number is reported whether it passes or fails; a review reading is not
  evidence.
- **What `M2` builds is canonical-history continuation, and the name is used
  consistently.** A turn continues its predecessor because the whole
  conversation is replayed from committed records: turn two is a continuation of
  canonical history, produced by projection, and of nothing else. Every claim
  this decision supports is a claim about replay from committed elements. No
  claim anywhere — plan, gate, evidence, or reference client — may call `M2`
  provider-native continuation, because nothing in `M2` retains a provider's
  continuation state, reasoning signatures, or response identifiers.
- **The continuation field is reserved, always empty, and carries no meaning in
  `M2`.** It is structurally present in the canonical request so that a later
  adapter-private sidecar lands without changing what a recorded digest covers,
  and it is empty in every `M2` request. It makes no turn a continuation, it is
  not a binding to anything, `M2` stores no sidecar and reads none, and no
  adapter may require one. Because the model is fixed at session scope, `M2`
  also has no model-change event for such a binding to be invalidated by: there
  is nothing carried and nothing to invalidate, and the reserved field must not
  be evidenced as though there were.
- **The model is fixed for the life of a session.** Exact model identity is
  committed when the session is created and every run of that session stages it.
  `M2` admits no `set_model` command, so the model changes neither within a run
  nor between runs of one session; changing model means creating a new session.
  This is stated at session scope rather than run scope because the reason is
  the same in both places: cross-model replay of a canonical history is a
  compatibility claim, and `M2` retains no evidence for one. The `/model` flow
  the vision expects of a reference client waits for the provider-continuation
  compatibility decision that accompanies the sidecar.

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

**Check the deadline only between turns.** It is the smallest possible rule and
it costs no plumbing into the model call. It is not recommended: a bound that is
only sampled between calls is not a wall-clock bound at all, because the single
place a run stalls longest is inside one provider call, and a run could exceed
its declared deadline by hours while every between-turn check passed. Bounding
the supervised call with the same absolute instant costs one propagated field
and one explicit race rule.

**Encode a reached bound as a `budget_exhausted` category of
`failed(category, retryable?)`.** It leaves the terminal set untouched, which
matters because every consumer, event projection, and conformance vector will
treat a closed set as exhaustive; a new failure category is additive where a new
terminal value is not; and the fact still reaches anyone who reads the category
and the named bound. It is rejected:
every consumer grouping by terminal value would then see a configured stop and a
genuine breakage in one bucket, distinguishable only by reading a reason code,
and that is exactly the distinction an operator scanning a list of sessions needs
most. Grouping by outcome is the cheapest and most common thing done with a run
outcome, so an encoding that is only truthful to a consumer who looks one level
deeper is a public value that misleads by default. `retryable?` would also carry
no honest content here: the bounds are committed with the run, so a retry under
the same identity re-evaluates the same limits and stops again without a provider
call.

**Charge a cancelled or aborted turn only for what it demonstrably produced.**
It is the most accurate-sounding rule and it never over-charges. It is not
recommended: partial streamed output is transient progress that no durable record
retains, so "what it produced" is a number Loopex cannot recover after a restart,
and where nothing was observed the charge is zero — which makes aborting every
turn the cheapest way to run indefinitely inside a token budget. Charging the
committed `max_tokens` allowance is recoverable from committed bytes, never below
what the provider could bill, and visible as estimated.

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

**Refuse to start a session whose provider does not report usage.** This is the
strictest reading of "a committed bound must be enforceable", and it has the
merit of never estimating anything. It is not recommended: usage reporting is
not a declarable capability that can be checked before a request, so the refusal
could only fire after a first reply, and the honest version of it would end a
run the operator already paid for. It would also exclude local and
OpenAI-compatible endpoints for a reporting gap rather than a behavioural one.
Conservative accounting keeps the bound live and marks the number as estimated;
what is never acceptable is the third option, silently dropping the bound.

**Let core resolve the workspace path and read the resources itself.** It is by
far the shortest path to a working reference stage, because the brain and the
hand share a filesystem in the single-machine `M2` topology and core could simply
open the file. It is not recommended: it makes core depend on a POSIX path and
brain-local filesystem access, which contradicts the opaque workspace reference
the whole executor topology is built on, and it breaks the first time a hand is a
container, a remote checkout, or a volume snapshot. It would also put path
containment in the one component that cannot enforce it honestly. Having the hand
supply bounded manifest entries and content evidence costs one more boundary
crossing and keeps core free of filesystem authority.

**Discover project resources by a configured glob or a recursive walk.** More
useful on day one, and every comparable tool does something like it. It is not
recommended for the fixed reference stage: a glob makes the resolved set depend
on a configuration surface nobody has reviewed, a recursive walk makes it depend
on repository size, and both make the trust decision harder to display honestly
because the operator cannot see what they are agreeing to. One named file at the
root is small enough to show in full, and widening the rule later is an additive
decision with a migration story, while narrowing it after operators depend on it
is not.

**Grant a resumed run a fresh deadline.** It would make resume useful after a
long outage, which is the case an operator actually hits. It is not recommended
here: an active-time deadline needs durable span accounting across incarnations,
with its own fault cases at every crash point, and `M2` has no evidence for it.
The absolute instant is honest, it costs one truthful terminal outcome, and the
operator's remedy — a new run over the retained conversation — already exists.

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

Staging complete tool-definition bytes makes every staged request larger by the
full size of the active definitions, on every turn, and that size is charged
against the token budget each time. The compensation is that a staged request
means something without the registry: it can be verified, replayed, and audited
years later, including after the tool that produced it is gone. Keeping tool
descriptions and schemas terse becomes a cost decision rather than a style one.

Durable session size becomes proportional to tool output. Complete tool results
are journaled, which is what makes replay honest and what makes storage grow.
The bounded-output and artifact-spill rules in
[ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) are the only thing
keeping that finite, so the two decisions are coupled: accepting either without
the other leaves a real hole.

Every turn sends the whole conversation, so token cost per run grows with the
square of the turn count. The turn, token, and time bounds make that finite but
do not make it cheap. Measuring it is what will later justify compaction, and
until then long sessions end at a declared bound rather than degrading — a real
v0.1 usability limit that documentation must state rather than soften.

Refusing implicit defaults makes the runtime harder to start. A session now
needs an explicit token bound, explicit run bounds, and, from the paired
decision, an explicit policy. That friction is deliberate and it will show up as
configuration surface in the reference CLI.

Deferring transformers and selectors leaves receipt fields that look redundant
today, because `M2` fills them with one fixed reference identity. The cost is a
slightly wider receipt now in exchange for not migrating every retained receipt
when the pipeline lands.

Fixing the model for a session's whole life is a visible limitation against the
`/model` flow the vision expects of a reference client, and it is the price of
not asserting a continuation compatibility rule before there is evidence for
one. It also has a quieter cost: an operator who wants a stronger model for one
hard turn starts a new session and loses the conversation, which is the sort of
friction that makes people paste context by hand.

Estimated token accounting is a permanent second class of number in the durable
record. A `bound_reached` outcome naming `:token_budget` now
has to say how its value was obtained, every consumer that renders a token count
has to render the distinction, and a run that mixes reported and estimated turns
carries both. That is the cost of never letting a committed bound become
silently inert.

Charging an aborted turn its full `max_tokens` allowance over-charges most of
the time, because a call cancelled early rarely generated its whole allowance.
That direction is deliberate — a bound should err toward ending early rather
than toward being evadable — but it means a run with several cancellations can
exhaust its token budget having been billed by the provider for considerably
less. The estimated marker is what keeps that visible instead of mysterious.

`bound_reached` is a terminal value every consumer has to handle. A run outcome
is a closed set that callers switch on exhaustively, so the reference client,
retained evidence, the operator documentation, and every event projection the
headless session protocol later publishes each need a case for it; a consumer
written against the set without it is incomplete rather than merely unpolished,
and that obligation lands on every future protocol surface, not only on `M2`.
The set also stays closed with one more member inside it. Each new way a run can
stop will make a further terminal value look reasonable, and holding the line
means the next one has to earn the same explicit vision decision this one
received rather than arriving as an implementation detail.

Bounding the model call by the deadline means a reply can be discarded after the
provider has already been billed for it. When the abort commits first, the run
gets no assistant message from a call the operator paid for, and the attempt
evidence records exactly that. The alternative was a bound that does not bind.

Discovery narrow enough to display honestly is discovery narrow enough to
disappoint. One file at the workspace root will not match what operators expect
from tools they already use, and the gap will be reported as a missing feature
rather than as a trust decision. Widening it is additive; the reason to start
here is that the operator can read the entire thing they are being asked to
trust.

Moving discovery out of core means core can no longer see a workspace at all.
The reference stage yields nothing unless a host or hand supplies a manifest,
so the reference CLI and the local hand each grow a small responsibility that a
direct file read would have hidden, and a host that supplies nothing gets an
empty class rather than an error. That is the price of core holding an opaque
workspace identity, and it is the same price already paid for tool execution.

Technical depth: [Operational consequences](0010-provider-continuation-and-context-staging-technical.md#technical-adr-0010-consequences).

<a id="concept-adr-0010-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists and no installed base exists. `M2` tags no version:
`VERSION` stays `0.0.0` and the first version number is reserved for the
headless session-protocol milestone. The canonical request format, the
conversation element shapes, the context receipt, the trust binding, and the
bound outcomes are all experimental and freeze nothing. The vision's run
terminal set is the one thing here that is not experimental, and it changed by
explicit maintainer decision: it gained `bound_reached` in the vision pair, and
this ADR implements that decision rather than making it. The widening migrates
nothing. No version is released, no public protocol yet carries a run outcome,
and no session record exists anywhere in which a reached bound was written as
something else, so there is no consumer to update and no journal to project
forward. The set stays closed with `bound_reached` in it, and a further member
needs the same kind of decision, with its own evidence and consumer analysis.

`M1` journals are not migrated. `M1`'s synthesized second-turn record has no
successor form, because a synthesized string is not a degraded version of a real
tool result, and `M1`-owned test roots are discarded.

Rollback before closure removes the conversation elements, the bounds, the
`bound_reached` outcome, and the context receipt together, returning to `M1`'s
single-message request. It cannot be partial: the termination condition depends
on the assistant message shape, and the assistant message shape exists only
because the conversation record does. Once a version is published, a change to
canonicalization, an element shape, or the receipt is an additive versioned
change with fixtures and a projection rule for older journals, never an edit to
what a recorded digest meant.

Technical depth: [Format, migration, and rollback mechanics](0010-provider-continuation-and-context-staging-technical.md#technical-adr-0010-compatibility).

## Links

- [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) — the paired
  decision supplying tool definition generations, bounded results, and the
  cancellation algebra this record replays
- [ADR 0011](0011-session-input-algebra-and-streaming.md#concept) — the input
  algebra that decides which admitted input becomes a conversation element, and
  the streaming rule that keeps the reconstructed assistant message the only
  durable model output
- [ADR 0006](0006-store-transaction-and-owner-epoch.md#concept) — the
  transaction and owner-epoch contract these records commit under
- [ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept) —
  the succession recovery this projection must survive without change
- [ADR 0007](0007-local-executor-grant-job-receipt.md#concept) — the one
  canonical request digest identity this decision extends to a full request
- [Vision model and context boundary](../vision.md#concept-vision-model-boundary) — the governed pipeline and what belongs to hosts
- [Vision executor protocol and brain/hand topology](../vision.md#concept-vision-executor-protocol) — the opaque workspace reference core never resolves
- [Vision recovery truth](../vision-technical.md#technical-vision-recovery-truth) — §9.5's outcome immutability and reconciliation rules, which a `bound_reached` run terminal obeys like any other
- [Vision loop semantics](../vision-technical.md#technical-vision-loop-semantics) — one run, the closed run terminal set `bound_reached` belongs to, input queues, and the split payload rule
- [AGENTS.md](../../AGENTS.md) — durability and recovery truth, truth planes,
  credentials and context, and the smallest sufficient system
