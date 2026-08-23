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
continuation               continuation-ready binding, structurally present and empty in every M2 request
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
reached, the observed value against the declared limit, and the accounting
source that produced it.

Cumulative token accounting has exactly two sources and one rule:

| Turn evidence | Accounted value | Recorded source |
| --- | --- | --- |
| Assistant message carries provider usage | The reported prompt and completion totals | `reported` |
| Assistant message carries no usage, or partial usage | Token count of the committed canonical request bytes plus the committed assistant message bytes, under the recorded tokenizer identity | `estimated` |
| Model operation ended without a complete reply | The committed canonical request bytes only, under the same tokenizer identity | `estimated` |

The tokenizer is the same repository-owned tokenizer identity the prompt budget
measurement records, and its declared direction is conservative: for the
canonical byte encoding it must never return fewer tokens than a provider would
charge for the same content. The run's cumulative counter is a sum over
committed turns, so it is recoverable rather than held in process state, and a
run that mixes sources keeps both subtotals. `budget_exhausted(:token_budget)`
records the cumulative value, the limit, and whether any turn was estimated.
Nothing anywhere disables the bound: there is no configuration, provider
capability, or adapter return that makes the token check skip.

`budget_exhausted` is a terminal run outcome in the closed algebra and never a
tool-call outcome. The conversation remains durable and complete, so a new run
may continue from it; nothing is truncated to make the record fit the bound.

### Resuming a run versus prompting a session

These are separate operations and the difference is load-bearing, because one
inherits committed state and the other must not.

| | Resume an interrupted run | Prompt a completed session |
| --- | --- | --- |
| Admission | Not a session command; recovery of an unresolved committed intent | A `prompt` command, admitted only while the session is settled |
| Identity | Same `run_id`, same `operation_id`, next attempt | New `run_id`, new `command_id`, first attempt |
| Request bytes | The staged bytes already committed; missing bytes fail closed as `unavailable(staged_context_missing)` | Newly projected, assembled, and committed |
| Bounds | The bounds committed with that run, unchanged | Freshly committed with the new run |
| Deadline | The absolute instant committed with the run; downtime counts against it, and an elapsed deadline terminates on recovery before any provider call | A new absolute instant computed at admission |
| Token counter | Continues from the committed per-turn sum | Starts at zero |
| Ownership | The recovering owner already holds the session under ADR 0008 | Live ownership acquired through a fresh resume command identity |
| Projection | Unchanged; the same committed elements project the same bytes | Whole retained lineage across every prior run |

A resumed run therefore cannot gain time, turns, or tokens by being interrupted,
and a new run cannot be charged for a previous one. The one case operators will
notice is a run whose deadline expired while its host was down: recovery commits
`budget_exhausted(:deadline)` with the committed instant and the observed
recovery instant, and the operator's remedy is a new run over the same durable
conversation.

### Provenance, trust, and budget

| Provenance class | Source | Trust class | Budget |
| --- | --- | --- | --- |
| `session` | Lineage projection of committed elements | Session-owned durable truth | Counted in total; never dropped to fit |
| `system` | Versioned reference prompt and active tool definitions | Host-owned trusted brain content | Per-class ceiling, measured |
| `project_resource` | Fixed reference stage over the workspace | Untrusted behaviour-shaping data | Per-class ceiling; refused when over |

Every block descriptor records source reference, content digest, provenance
class, trust class, byte cost, and token cost, and the receipt records them in
final order together with the fixed reference provider identity and revision.

### Project-resource discovery, manifest, and trust

Discovery is a pure function of the canonical workspace root and the filesystem,
and it runs before any admission question is asked:

1. Resolve the canonical workspace root to its real path. This is the same root
   the workspace lease names, and the same containment rule ADR 0009 applies to
   tool paths applies here.
2. Resolve exactly one candidate: `AGENTS.md` directly under that root. No
   recursion, no glob, no configured path list, no user-level or
   home-directory resource, no revision-history resource.
3. Refuse a candidate whose real path leaves the root, including through a
   symlinked component, naming path containment rather than the target.
4. Read each surviving candidate once, at the moment of manifest construction,
   and digest exactly the bytes read. Absence is not an error; it produces an
   empty manifest.

Limits are declared, and every one of them fails closed rather than trimming:

```text
per_resource_bytes   64 KiB
class_total_bytes    64 KiB
class_token_ceiling  the project_resource per-class budget above
```

The manifest is canonical plain data in path order:

```text
entries        [{relative_path, byte_size, content_digest}]
workspace      {root_real_path, repository_origin | nil, revision | nil}
manifest_digest digest over the canonical encoding of entries and workspace
```

Content never influences discovery. An `@import`, include directive, or link
inside `AGENTS.md` is inert text; the resolved set is what step 2 produced and
nothing an admitted file says can add to it.

The trust decision is host-owned and Loopex-bound. Core exposes the manifest and
its digest as a read-only projection so a client can display it without
admitting anything; the decision is supplied at session start as bounded plain
data:

```text
manifest_digest    exact digest the decision was made about
workspace          exact canonical workspace identity
trust_scope        project_resource in M2
decision_source    interactive_operator | host_supplied
issued_at          instant
expires_at         null in M2
revocation_state   active in M2
```

Resolution is exhaustive and fails closed toward withholding content, never
toward refusing the runtime:

| Observation | Resolution |
| --- | --- |
| Decision present and `manifest_digest` matches exactly | Blocks staged within budget; receipt records the manifest digest and decision source |
| Decision absent | Class staged empty; receipt records `project_resource_declined(no_decision)` |
| Decision present, digest differs | Class staged empty; receipt records `project_resource_declined(binding_changed)` |
| Manifest over any declared limit | Class staged empty; receipt records `project_resource_declined(over_limit)` with observed sizes |
| Interactive client, no decision yet | Client displays each entry's path, size, and digest plus the manifest digest, asks once, and supplies the answer at session start |

The interactive reference command persists nothing on Loopex's behalf; whether a
host remembers an answer between sessions is host retention policy, and a
remembered answer is admitted only when its `manifest_digest` still matches.

Admitted content stays subject to tool policy: no block changes the active tool
set, the policy decision, the bounds, or a grant, and typed delimiters around
untrusted blocks are input structure rather than a security boundary.

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
- A provider reply with no usage field, asserting that the token bound is still
  enforced from the committed canonical bytes, that the accounted value is
  marked `estimated`, that the estimate is not below the reported value for a
  control turn of the same content, and that no path exists by which the check
  is skipped.
- A run interrupted and resumed, asserting the same `run_id`, the same committed
  bounds, the same staged bytes, and a token counter that continues rather than
  restarts; and a run whose committed deadline elapsed while its owner was down,
  asserting `budget_exhausted(:deadline)` on recovery with no provider call.
- A completed session prompted again, asserting a new run identity, freshly
  committed bounds, a zeroed token counter, refusal while a run is still active,
  and a projection covering both runs.
- A model change refused: no `set_model` command exists, and every run of one
  session stages the model identity committed at session creation.
- Provenance and budget: a project resource refused without a trust decision, an
  invalidated decision after a digest change, an over-budget assembly failing
  closed, and a receipt whose ordered descriptors match the staged request.
- Discovery determinism: the same workspace produces a byte-identical manifest
  and digest across runs; a symlinked `AGENTS.md` pointing outside the root is
  refused for containment; an over-ceiling file is declined rather than
  truncated; a decision bound to a stale manifest digest admits nothing; and an
  import directive inside an admitted file adds no resource.
- A headless run with no supplied decision proceeding with the class staged
  empty and a journalled declined receipt entry, rather than refusing to start.
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

**Refusing a session whose provider omits usage.** The check cannot run where it
would need to. Usage reporting is a property of a response, not a declarable
capability, so the earliest honest refusal point is after a completed first turn
— which means refusing a session the operator has already been billed for. The
next-earliest is a provider allowlist, which is a maintained list of names
standing in for an observed behaviour. Conservative accounting has one real
weakness: an over-estimate ends a run slightly early. That is the direction a
bound should err in, and the recorded `estimated` marker keeps it visible rather
than mysterious.

**Glob or recursive project-resource discovery.** The mechanics are easy and the
trust consequences are not. Whatever the resolved set is, the operator has to be
shown it before answering, and a recursive walk over a real repository produces
a list nobody reads. It also makes the manifest digest a function of repository
size and layout, so ordinary unrelated file churn invalidates admission and
retrains the operator to approve without looking — the exact failure mode the
admission decision exists to prevent. One file at the root is displayable in
full, and widening the rule later is an additive decision.

**A fresh deadline for a resumed run.** More useful and considerably more
machinery: an active-time bound must accumulate durable spans across
incarnations, and every crash point becomes a question about whether the span
that was open is counted. `M2` has no evidence for those cases and would be
inventing them under a bound whose purpose is to protect an operator from a
stalled provider. The absolute instant is one committed field with no recovery
question, and its worst case is a truthful terminal outcome plus a new run.

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
- Fixing the model per session keeps the reference command short of the
  `/model` flow §18.4 expects. That flow returns with the continuation
  compatibility evidence that justifies it, and until then a stronger model for
  one turn costs a new session.
- Token accounting carries a provenance field forever. Reported and estimated
  values coexist in one durable counter, every renderer must distinguish them,
  and the conservative tokenizer will sometimes end a run slightly early against
  what a provider would have charged. Ending early is the deliberate direction.
- Discovery is now a fixed rule rather than an implementation detail. Widening
  it later is additive but is a decision, because operators will have trusted
  manifests produced under the narrow rule and a wider rule produces a different
  digest for the same repository.

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

There is no installed base and no published package, and `M2` tags no version:
`VERSION` stays `0.0.0` and the first version number belongs to the headless
session-protocol milestone. The request format, element shapes, receipt, trust
binding, and bound outcomes freeze nothing. `M1` journals are neither read nor
migrated; the `M1` synthesized second-turn record has no successor form, and
`M1`-owned test roots are discarded.

Rollback before closure removes the conversation elements, the projection, the
bounds, the budget outcome, and the context receipt together, restoring `M1`'s
single-message request and its two-turn arithmetic. It cannot be partial,
because the termination condition reads the assistant message shape and the
assistant message shape exists only as a conversation element.

Once a version is published, a canonicalization change, an element shape
change, or a receipt change is an additive versioned change carrying fixtures
and a projection rule for journals written under the previous version. Adding a
provenance class, adding a bound, or making the continuation binding non-empty
each change what a recorded receipt or digest meant and therefore require a
successor decision rather than an edit.
