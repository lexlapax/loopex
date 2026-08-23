# 0010: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Provider continuation and exact context staging](0010-provider-continuation-and-context-staging.md#concept).

<a id="technical-adr-0010-context"></a>
## What M1 Commits Today and the Three Defects

Concept: [Context](0010-provider-continuation-and-context-staging.md#concept-adr-0010-context).

The closed `M1` product stages a request of exactly this shape, once per turn:

```text
messages    [%{"role" => "user", "content" => work.content}]
tools       turn 1: [the one configured tool]   turn 2: []
tool_choice turn 1: force that tool             turn 2: "none"
max_tokens  configured value, defaulting to 128
```

On turn two, `work.content` is not the user's prompt. It is a string the
coordinator builds when the executor receipt commits, of the form
`"Tool <name> completed: completed"`. Three distinct defects follow, and they
need three distinct fixes.

| Defect | What the model sees | What it cannot do |
| --- | --- | --- |
| No history | One message, replaced each turn | Refer to the original request, to its own reasoning, or to anything before this turn |
| No real result | A fixed Loopex-authored string | Read what the tool actually produced, notice a failure, or react to output |
| No termination condition | An empty tool list on turn two | Continue, stop for a reason, or exceed two turns at all |

None of these is a bug in the durability work. The staged-bytes property, the
per-turn digest, and the real-provider assertion that the adapter received
exactly the committed bytes are all correct and all worth preserving. They are
correct about a request that happens to contain one message. Widening the
request is therefore the change, and keeping the assertion exact while widening
it is the requirement.

The termination defect deserves separate emphasis because it is the one that
hides. A loop that stops because the second request cannot express a tool call
looks like a loop with a stopping rule. It has none. Replacing `tools: []` with
a real condition is what makes the run's terminal outcome a fact about the
model's behaviour rather than a fact about Loopex's request construction.

<a id="technical-adr-0010-decision"></a>
## Exact Request, Element, Projection, and Bound Contract

Concept: [Decision](0010-provider-continuation-and-context-staging.md#concept-adr-0010-decision).

### Canonical model request

```text
canonicalization_version   protocol version tag of the canonicalizing function
model                      exact model identity
messages                   ordered list of canonical messages
tools                      ordered list of active definition generations
sampling                   max_tokens and any other declared bound, all explicit
continuation               provider-native continuation binding, empty in M2
```

Canonical messages are the vision's provider-neutral types: system, user,
assistant, and tool roles carrying text content blocks, complete tool calls, and
complete tool results. No provider struct, renderer payload, terminal escape,
diagnostic, or raw exception enters a canonical message; the split payload rule
governs what the client sees separately.

Canonicalization is deterministic: ordered fields, sorted map keys by binary
value, explicit absence rather than omission, and the same protocol-versioned
encoding the request digest already uses. The digest covers the whole structure
including `canonicalization_version`, so a canonicalization change is visible in
every digest rather than silent.

Staging and dispatch preserve the `M1` sequence exactly and only widen its
payload:

1. Project the message list from committed journal elements.
2. Assemble injected blocks within budget and produce the ordered block
   descriptors.
3. Commit, in one transaction, the model-call intent, the staged request bytes
   and digest, and the context receipt.
4. Only after confirmed commit, hand exactly those bytes to the adapter.
5. On recovery, dispatch the same staged bytes. A provider retry is a new
   recorded attempt against the same bytes. Missing staged bytes fail closed as
   `unavailable(staged_context_missing)`; nothing is recomputed under the same
   operation identity.

The real-provider selector asserts equality between the committed bytes and what
the adapter received for the whole request — messages, tools, sampling, and
continuation — not only for the message the run started with.

### Durable conversation elements

Each element is a bounded plain-data record in the session mutation domain,
committed by the serial session owner:

```text
user_message      run_id, command_id, exact prompt bytes
assistant_message run_id, turn_number, ordered content blocks,
                  ordered tool_calls [{tool_call_id, generation, arguments}],
                  stop reason, usage
tool_result       run_id, turn_number, tool_call_id, terminal outcome,
                  bounded model-facing content, optional artifact references
```

Ordering invariants, each individually asserted:

- A `tool_result` element commits only when its `tool_call_id` names a tool call
  in the immediately preceding committed `assistant_message` of the same run.
- Results for one assistant message commit in that message's call order,
  whatever order the operations completed in.
- The next request may not be staged while any call of the latest
  `assistant_message` has no committed terminal result element.
- A malformed, truncated, or duplicated tool call never becomes a call entry,
  never receives a `tool_call_id`, and never reaches host policy or the
  executor.
- Every terminal outcome ADR 0009's cancellation algebra can produce —
  `completed`, `failed`, `denied`, `cancelled`, `outcome_unknown` — has a
  defined bounded model-facing content form, so no outcome leaves a hole in the
  conversation.

A cancelled run is the one case where results stop being projected: a late
result for a cancelled run is retained truthfully as an element of the record
but the run is terminal, so nothing projects it into a next turn that does not
exist.

### Projection

Projection is a pure function of committed elements to the canonical message
list:

```text
system    versioned reference system prompt and active tool definitions
[project_resource blocks, if an explicit trust decision admitted them]
user      the run's admitted prompt bytes
assistant turn 1 content and tool calls
tool      turn 1 results, in the assistant's call order
assistant turn 2 ...
```

It reads no process state, performs no retrieval, and derives no content. Given
the same committed elements it produces byte-identical output, which is what
makes recovery and succession safe: a successor owner projects the same list
from the same journal. This is exactly why no message may live only in
coordinator memory — under ADR 0008 the coordinator can be lost at any point,
and anything held only there is unrecoverable rather than merely stale.

### Termination and bounds

Checked in this order before staging the next request:

```text
if last assistant message has no tool calls   -> run completed
if turn_number + 1 > max_turns                -> budget_exhausted(:max_turns)
if cumulative tokens >= token_budget          -> budget_exhausted(:token_budget)
if now >= run_deadline                        -> budget_exhausted(:deadline)
otherwise                                     -> stage and dispatch
```

Because every bound is evaluated before staging, exceeding one costs no provider
call and commits no partial request. The terminal record names which bound was
reached and the observed value against the declared limit. Cumulative token
accounting uses the provider-reported usage from committed assistant messages;
where a provider reports no usage, the token bound is reported as unenforceable
for that model rather than silently estimated, and the turn and deadline bounds
still apply.

`budget_exhausted` is a terminal run outcome in the closed algebra and never a
tool-call outcome. The conversation remains durable and complete, so a new run
may continue from it; nothing is truncated to make the record fit the bound.

### Provenance, trust, and budget

| Provenance class | Source | Trust class | Budget |
| --- | --- | --- | --- |
| `session` | Lineage projection of committed elements | Session-owned durable truth | Counted in total; never dropped to fit |
| `system` | Versioned reference prompt and active tool definitions | Host-owned trusted brain content | Per-class ceiling, measured |
| `project_resource` | Fixed reference stage over the workspace | Untrusted behaviour-shaping data | Per-class ceiling; refused when over |

Every block descriptor records source reference, content digest, provenance
class, trust class, byte cost, and token cost, and the receipt records them in
final order together with the fixed reference provider identity and revision.

Project-local resources are admitted only by an explicit deterministic decision
binding canonical workspace identity, resolved resource-set manifest, and
digests. A changed root, resolved set, or digest invalidates the decision and
requires a new one. Headless operation without a matching positive decision
fails closed. Admitted content stays subject to tool policy: no block changes
the active tool set, the policy decision, the bounds, or a grant, and typed
delimiters around untrusted blocks are input structure rather than a security
boundary.

Total budget is enforced before dispatch. Over-budget fails closed as
`budget_exhausted` at staging time rather than dropping history, because
silently dropping a message would make the projection non-deterministic and
break the property the receipt exists to prove.

### Prompt budget measurement

The measurement is a repository-owned check, not a review reading:

1. Canonicalize the reference system prompt and the four active bootstrap tool
   definitions exactly as they would be staged.
2. Count tokens with a recorded tokenizer identity and version.
3. Report the count, the limit of 1,000, and the tokenizer identity as retained
   evidence.
4. Fail when the count is at or above the limit.

The number is reported on success as well as failure, so a later increase is
visible as a trend rather than discovered at the threshold.

### Evidence

- Byte equality between the committed staged request and what the real provider
  adapter received, for a multi-turn run with real tool results.
- Replay after a restart mid-run producing a byte-identical projection and
  dispatching the same staged bytes for an unresolved intent.
- Missing staged bytes failing closed as `unavailable(staged_context_missing)`
  rather than being recomputed.
- Source-order properties: results committed out of completion order still
  commit in call order; staging is refused while a call lacks a result; a
  malformed tool call never becomes an element.
- Each bound reached in isolation, asserting the exact terminal outcome, the
  named bound, that no provider call was made for the refused turn, and that no
  assistant message was fabricated.
- A run continued by a second run from the retained conversation.
- Provenance and budget: a project resource refused without a trust decision, an
  invalidated decision after a digest change, an over-budget assembly failing
  closed, and a receipt whose ordered descriptors match the staged request.
- An injected block attempting to name a tool, widen policy, or change a bound,
  proving none of them changes.
- The retained prompt budget measurement with its tokenizer identity.

<a id="technical-adr-0010-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0010-provider-continuation-and-context-staging.md#concept-adr-0010-alternatives).

**Provider-native continuation as durable truth.** Sending back a provider
response identifier is cheaper per turn, preserves reasoning signatures and
provider-side tool-call metadata exactly, and removes the quadratic token cost
of replay. Its cost is categorical: the durable truth becomes an opaque foreign
handle. Loopex could not project it, branch it, fork it, compact it, migrate it,
or replay it after the provider expires it, and a model or provider change would
invalidate it. It would make the restart property `M1` proved contingent on an
external service. The sidecar in §13.4 keeps the benefit reachable as an
adapter-private optimization bound to provider, model family, and source message
range, without ever being the truth; `M2` stores none because it has no evidence
about continuation compatibility to encode.

**Better synthesized summaries.** The current `"Tool <name> completed: completed"`
could become a richer generated description. This does not address the defect:
the model still never sees its own prior message, still never sees observed
output, and correctness still depends on a formatting choice. It also makes the
failure mode worse, because a plausible summary is harder to notice than an
obviously fixed string.

**One bound instead of three.** A token budget alone is simplest. It fails on
cheap loops: a run that calls a small tool repeatedly can burn hours inside a
modest token budget. A turn bound alone fails on expensive single turns. A
deadline alone fails to distinguish a stalled provider from a productive run.
The three are cheap to check and each catches what the others miss.

**Fabricating a terminal assistant message.** Rejected outright rather than
weighed: canonical history would contain a Loopex assertion in the model's
voice, and replay could not distinguish it from a real message. If a client
wants to display "the run hit its turn limit", that is client rendering of the
terminal outcome, which the split payload rule already permits.

**Building the pluggable pipeline now.** Candidate providers, transformers, and
selectors are already specified, so the work is known. Each abstraction would
unify exactly one implementation in `M2`, which is the speculative single-use
layer the minimalism budget excludes. The seam is protected instead by the
receipt shape, which carries provider and transformer identity and revision from
the start, so the pipeline lands additively rather than as a receipt migration.

**Compaction or summarization now.** It would let long sessions continue. It
embeds an unmeasured quality decision — what may be dropped from a coding
session's history — into the kernel, and it interacts with branching and
checkpoints that `M2` also does not have. Ending the run truthfully on budget is
smaller and honest, and the token cost `M2` measures is what will justify the
compaction design later.

<a id="technical-adr-0010-consequences"></a>
## Operational Consequences

Concept: [Consequences](0010-provider-continuation-and-context-staging.md#concept-adr-0010-consequences).

### If accepted

- Request canonicalization becomes versioned protocol truth. Every staged
  request records its `canonicalization_version`, and changing the function
  later requires a new version plus fixtures that prove old journals still
  project and verify.
- Session storage grows with tool output. Retaining complete results is what
  makes replay honest; the bounded-output ceiling and artifact spill from ADR
  0009 are what make it finite. Neither decision is safe without the other, and
  a future compaction policy inherits both.
- Token cost per run grows quadratically in turn count, because each turn sends
  the whole conversation. The bounds make it finite, not cheap. Measuring the
  real curve is the input to the eventual compaction decision.
- Long sessions end rather than degrade. `budget_exhausted` is the honest
  outcome and it will be experienced as a limitation; documentation must say so
  plainly rather than describe it as a safeguard.
- Explicit configuration replaces defaults for the token bound, the run bounds,
  and, with ADR 0009, the policy. Starting a session takes more configuration
  and fails earlier when it is missing.
- Receipts carry fixed reference provider and revision identities that look
  redundant until the pipeline lands. That is a deliberate small cost now
  against a migration of every retained receipt later.
- Refusing a mid-run model change keeps the reference CLI short of one of its
  eventual minimum flows. That flow returns with the continuation compatibility
  evidence that justifies it.

### If rejected

- The loop keeps a synthesized second turn and no history, so the v0.1 rung's
  central claim — a real agent loop — cannot be made honestly.
- Without a termination condition, either the two-turn arithmetic stays or the
  loop becomes unbounded. The first is not a loop and the second has no truthful
  terminal outcome.
- Without provenance and budget rules, the first project-resource stage would
  admit workspace content into model context with no trust decision and no
  accounting, which contradicts project-resource admission and would be much
  harder to retrofit once a receipt format exists.

<a id="technical-adr-0010-compatibility"></a>
## Format, Migration, and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0010-provider-continuation-and-context-staging.md#concept-adr-0010-compatibility).

The durable format gains user, assistant, and tool-result conversation elements,
the staged request record with its `canonicalization_version` and digest, the
context receipt with ordered block descriptors, the committed run bounds, and
the `budget_exhausted` terminal outcome. All are bounded plain data in the
session mutation domain and reach a public plane only through existing bounded
events.

There is no installed base and no published package. Version 0.1.0 is a tagged
source version, so the request format, element shapes, receipt, and bound
outcomes freeze nothing. `M1` journals are neither read nor migrated; the `M1`
synthesized second-turn record has no successor form, and `M1`-owned test roots
are discarded.

Rollback before closure removes the conversation elements, the projection, the
bounds, the budget outcome, and the context receipt together, restoring `M1`'s
single-message request and its two-turn arithmetic. It cannot be partial,
because the termination condition reads the assistant message shape and the
assistant message shape exists only as a conversation element.

After the 0.1.0 tag, a canonicalization change, an element shape change, or a
receipt change is an additive versioned change carrying fixtures and a
projection rule for journals written under the previous version. Adding a
provenance class, adding a bound, or making the continuation binding non-empty
each change what a recorded receipt or digest meant and therefore require a
successor decision rather than an edit.
