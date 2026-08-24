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
tools                      ordered list of complete tool definitions
sampling                   max_tokens and any other declared bound, all explicit
deadline                   the run's committed absolute deadline instant
continuation               reserved field, structurally present and empty in every M2 request
```

Each `tools` entry carries the complete immutable definition, not a pointer to
one:

```text
tool_id, tool_version, definition_digest   generation identity
name, description, parameter_schema        the provider-facing definition bytes
result_shape, effect_class,
idempotency_class, budgets                 the remaining definition record fields
```

The entry carries every field of ADR 0009's tool definition record, not only the
three a provider request renders. That is what makes `definition_digest`
checkable here: ADR 0009 canonicalizes and digests the whole nine-field record,
so an entry carrying a subset could be compared against nothing. The bytes are
canonicalized by the same protocol-versioned function and are covered by the
request's `staged_request_digest`. `definition_digest` binds the entry to the
generation the
registry held at staging time and is verified against those bytes; it does not
replace them. Consequently the staged request is fully
reconstructible and independently verifiable from the journal alone, with no
registry read, after the tool has been edited, version-bumped, or removed
entirely. Projection and replay never consult the registry.

Canonical messages are the vision's provider-neutral types: system, user,
assistant, and tool roles carrying text content blocks, complete tool calls, and
complete tool results. No provider struct, renderer payload, terminal escape,
diagnostic, or raw exception enters a canonical message; the split payload rule
governs what the client sees separately.

Canonicalization is deterministic: ordered fields, sorted map keys by binary
value, explicit absence rather than omission, and the same protocol-versioned
length-aware encoding Loopex's other canonical digests use. The digest over this
structure is the record's `staged_request_digest`. It covers the whole structure
including `canonicalization_version`, so a canonicalization change is visible in
every digest rather than silent.

The two digests this milestone touches are distinct and are named distinctly
wherever either appears:

| Digest | Covers | Behaviour across attempts of one operation |
| --- | --- | --- |
| `staged_request_digest` | The canonical model request above — model identity, messages, complete tool definitions, sampling, the run deadline, and the reserved continuation field. No operation or attempt identity is a member | Unchanged. A provider retry dispatches the same staged bytes under a new recorded attempt and reuses their digest; nothing is recomputed |
| Attempt-bound `canonical_request_digest` | [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept)'s `JobRequest` for an executor effect, whose canonicalization covers the immutable semantic job fields *including operation and attempt identity* | One value per attempt. Each executor attempt computes its own digest and is reconciled against it |

`operation_id` is the stable identity across attempts for both. The difference is
entirely a consequence of what each canonicalization covers, and no site may
assert one kind's rule about the other.

Staging and dispatch preserve the `M1` sequence exactly and only widen its
payload:

1. Project the message list from committed journal elements.
2. Assemble injected blocks within budget and produce the ordered block
   descriptors.
3. Commit, in one transaction, the model-call intent, the staged request bytes
   and their `staged_request_digest`, and the context receipt.
4. Only after confirmed commit, hand exactly those bytes to the adapter.
5. On recovery, dispatch the same staged bytes. A provider retry is a new
   recorded attempt against the same bytes and therefore against the same
   `staged_request_digest`. Missing staged bytes fail closed as
   `unavailable(staged_context_missing)`; nothing is recomputed under the same
   operation identity.

The real-provider selector asserts equality between the committed bytes and what
the adapter received for the whole request — messages, complete tool
definitions, sampling, deadline, and the reserved continuation field — not only
for the message the run started with.

The `continuation` field is reserved and nothing in `M2` writes it. It exists so
that a later adapter-private sidecar becomes a populated field rather than a
canonicalization change, and its presence is what keeps the recorded digest's
meaning stable across that later change. It confers no continuation: a turn
continues its predecessor solely because projection replays committed elements.
`M2` evidence therefore asserts that the field is empty in every staged request
and that dispatch succeeds against a real provider with it empty; there is no
`M2` behaviour in which it is carried, compared, or invalidated.

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
last assistant message has no tool calls -> run completed
turn_number + 1 > max_turns              -> bound_reached, :max_turns
cumulative tokens >= token_budget        -> bound_reached, :token_budget
now >= run_deadline                      -> bound_reached, :deadline
otherwise                                -> stage and dispatch
```

Because every bound is evaluated before staging, exceeding one makes no further
provider call and commits no partial request. The deadline is the exception in
the other direction: it also bounds work already in flight, so a deadline reached
mid-call aborts a request the provider may already have billed, and only the
pre-staging check is free. The `bound_reached` outcome carries the bound and the
observed value; the declared limit and the accounting source that produced the
value are sibling fields of the same terminal record.

The order is load-bearing at the top as well as the bottom. The no-tool check
precedes every bound check, so a run whose model stopped on its own is
`completed` and stays `completed`; a bound evaluated afterwards has nothing left
to decide. Below it, `:max_turns` and `:token_budget` are decided from committed
counters and can commit as soon as they are observed, because no owned work is in
flight at a pre-staging check. `:deadline` is different only in that it can also
fire while owned work *is* in flight, and then it waits: the run commits
`bound_reached` after every owned operation reaches a validated terminal fact and
every owned process tree is confirmed cleaned, or commits `outcome_unknown`
instead when one of those cannot be proved.

`bound_reached` is a member of the vision's closed run terminal set, not a
category of `failed(category, retryable?)`. It therefore carries no failure
category and no `retryable?` flag. Its payload is the vision's exact
`bound_reached(bound, observed)`: the bound name — `:max_turns`,
`:token_budget`, or `:deadline` — and the observed value, and nothing else. The
declared limit that value was measured against and the accounting source that
produced it are sibling fields of the run's terminal record, recorded beside the
outcome rather than inside it, so the algebra's shape stays the one the vision
fixes. A retryable flag would be
the wrong shape as well as the wrong grouping: the bounds are committed with the
run, so a retry under the same run identity re-evaluates the same committed
limits against the same committed counters and stops again without a provider
call, leaving the flag nothing to say. The operator's remedy is a new run, which
is a new identity with freshly committed bounds over the same durable
conversation rather than a retry.

### Deadline enforcement over every owned operation

The pre-staging check bounds the gaps between calls; it cannot bound a call, and
it cannot bound a tool. The same committed absolute instant therefore reaches
both kinds of owned work:

```text
run_deadline (absolute instant, committed with the run)
  -> checked before staging the next request
  -> carried in the staged request, covered by its staged_request_digest,
     and passed to the supervised model call
       -> the supervising process arms an abort at that instant
       -> the adapter receives the same instant and bounds its own transport wait
  -> canonicalized into every JobRequest the run dispatches, and therefore
     covered by that attempt's attempt-bound canonical_request_digest
       -> the attempt's effective deadline is derived at dispatch as
          min(run_deadline, dispatch_instant + tool.budgets.wall_time)
          and carried alongside the digested request, never inside it,
          because it is dispatch-local wall-clock rather than an
          immutable semantic job field
       -> at expiry ADR 0009's cancellation sequence terminates and confirms
          the owned process tree
```

There is no independent per-call timeout and no independent per-tool timeout
that can outlast the run. Any adapter-level, transport-level, or tool-level bound
is the minimum of its own configuration and the run deadline, so no mechanism can
extend owned work past the instant the operator declared and no two enforcement
points can disagree about when the run ends.
[ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) owns the job field,
the minimum rule, the executor's expiry behaviour, and the receipt; this decision
owns why the instant must arrive there at all and what the run does with the
result.

A run's owned work is therefore bounded in both directions:

| Owned operation | Bounded by | Ended at expiry by |
| --- | --- | --- |
| Supervised model call | The committed instant carried in the staged request | The supervising process arming an abort; no assistant message is written |
| Executor job | `run_deadline` canonicalized into the `JobRequest`, and the attempt-local `min(run_deadline, dispatch_instant + tool wall-time budget)` derived at dispatch and carried alongside it | ADR 0009's cancellation sequence: cooperative cancel, declared grace period, owned process-tree termination, confirmed cleanup |
| A tool call whose run deadline already passed at intent commit | Not dispatched at all | Terminal `cancelled` with no owned tree; cleanup is confirmed trivially |

`bound_reached(:deadline, observed)` commits only after every owned operation
above has reached a validated terminal fact and every owned process tree has been
confirmed cleaned. One `outcome_unknown` among them finishes the run
`outcome_unknown` with that reconciliation reference instead; the precedence is
unconditional and matches the paired decision's rule for `cancelled`.

### The deadline race

The race is decided by the coordinator's committed journal order, which is the
rule the vision already fixes for completion against cancellation: a run that has
committed a validated terminal fact keeps it. Three cases follow, and they are
three different endings rather than one:

| Committed first | Turn | Run | Late evidence |
| --- | --- | --- | --- |
| A complete validated reply **with no tool calls** | `completed`; the assistant message becomes canonical history and its usage is accounted normally | `completed`. The no-tool check precedes every bound check, so the run has already reached its terminal fact; a deadline firing afterwards is a no-op and never rewrites it | None; the reply is the committed fact and the run is terminal |
| A complete validated reply **with tool calls** | `completed`; the assistant message and its complete tool calls become canonical history | Each call is dispatched only if the run deadline is still in the future at its intent commit; a call whose deadline has passed commits no intent, mints no grant, and takes a terminal `cancelled` fact. Once every call has a committed terminal result the run takes one of three endings, decided by the deadline at that moment and not by the reply: the deadline still in the future **continues the loop** into the next turn; the deadline reached before the next request is staged commits `bound_reached` naming `:deadline`; and any call whose effect or cleanup could not be proved commits `outcome_unknown` instead, outranking both | A late receipt for a cancelled call is retained truthfully and projected into no next turn |
| The **deadline admission** | No assistant message is written; the attempt is retained as evidence with its abort reason | `bound_reached(:deadline, observed_instant)` after cleanup is confirmed; the committed deadline instant is a sibling field of the same terminal record, never a second member of the outcome | A reply arriving after admission is retained truthfully as attempt evidence and never becomes a canonical assistant message |

Partial or streamed output never becomes a canonical assistant message under any
of the three, so the race cannot produce a half-message in canonical history.

The governing principle is one sentence, and both defects this table replaced
were violations of it: **the committed journal order decides, and a validated
terminal fact is never overwritten.** A run that completed because the model
stopped on its own stays `completed` no matter what fires afterwards. A turn that
committed a tool-calling reply keeps that message, because the reply is a fact
the provider produced, and the deadline governs what may still be *dispatched*
rather than what may be *remembered*. Only the third case — where nothing was
committed for the turn — leaves the conversation without an assistant message,
and that is exactly the case where the model produced none inside the bound.

The second row is the one that needed a rule rather than an implication, and it
is the row an earlier draft got wrong by committing `bound_reached`
unconditionally once the calls finished. A committed tool-calling reply is not a
stopping condition. It is an ordinary turn, and the ordinary loop decides what
happens next: the three endings in the row are reached by evaluating the
deadline where every other bound is evaluated, immediately before the next
request would be staged. A run whose tools finished with time still on the clock
keeps running, and a run terminated at that point would be a healthy loop killed
by its own race rule.

The dispatch boundary inside the row is checked once, at intent commit, with no
minimum-remaining-time threshold: with time left the call is dispatched under its
effective job deadline, and with the deadline passed it is not dispatched at all.
Both branches end in a committed terminal result for every call, which preserves
the ordering invariant that no next turn may be staged while a call lacks one and
keeps every committed call element paired with a result element — an invariant
that now does real work, because a next turn is one of the three endings.

### Token accounting

Cumulative token accounting has exactly two recorded sources and one rule:

| Turn evidence | Accounted value | Recorded source |
| --- | --- | --- |
| Assistant message carries provider usage | The reported prompt and completion totals | `reported` |
| Assistant message carries no usage, or partial usage | Token count of the committed canonical request bytes plus the committed assistant message bytes, under the recorded tokenizer identity | `estimated` |
| Model operation ended without a complete reply — cancelled, deadline-aborted, or failed after dispatch | The committed canonical request bytes plus the turn's committed `max_tokens` allowance in full, under the same tokenizer identity | `estimated` |

The third row is the one that decides whether the token bound can be evaded.
Charging only the request bytes for an incomplete turn would leave a long
generation cancelled at the last moment costing roughly what an empty turn
costs, and a run could then stay inside a token budget indefinitely by aborting
every turn. Observed output is not an available answer: streamed partial output
is transient progress under the split payload rule, no durable record retains
it, and a count derived from it would not survive a restart. The committed
`max_tokens` value is the maximum output the provider was authorized to bill for
that turn, it is already in the committed request bytes, and it is recoverable
by a successor owner, so it is charged in full and marked `estimated`. It
over-charges an early abort, which is the direction a bound must err in, and the
`estimated` marker keeps the over-charge visible rather than mysterious. This is
also why an implicit `max_tokens` is not merely untidy: without a declared
allowance an aborted turn would have no conservative number to charge.

The tokenizer is the same repository-owned tokenizer identity the prompt budget
measurement records, and its declared direction is conservative: for the
canonical byte encoding it must never return fewer tokens than a provider would
charge for the same content. The run's cumulative counter is a sum over
committed turns, so it is recoverable rather than held in process state, and a
run that mixes sources keeps both subtotals. A `bound_reached`
outcome naming `:token_budget` carries the bound and the cumulative observed
value and nothing else; the limit and whether any turn was estimated are sibling
fields of the same terminal record, recorded beside the outcome. Nothing anywhere
disables the bound: there is no
configuration, provider capability, or adapter return that makes the token check
skip.

`bound_reached` is a run terminal outcome and never a tool-call outcome. The
conversation remains durable and complete, so a new run may continue from it;
nothing is truncated to make the record fit the bound.

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
`bound_reached(:deadline, observed_recovery_instant)`, with the committed
deadline instant recorded beside it in the same terminal record, and the
operator's remedy is a new
run over the same durable conversation. The precedence rule applies here as
everywhere else — recovery reaches `bound_reached` only once every operation
that run owned has a validated terminal fact, so a run whose in-flight executor
effect cannot be resolved through ADR 0007's reconciliation path finishes
`outcome_unknown` on recovery rather than reporting a bounded stop over an
effect nobody can prove.

### Provenance, trust, and budget

| Provenance class | Source | Trust class | Budget |
| --- | --- | --- | --- |
| `session` | Lineage projection of committed elements | Session-owned durable truth | Counted in total; never dropped to fit |
| `system` | Versioned reference prompt and active tool definitions | Host-owned trusted brain content | Per-class ceiling, measured |
| `project_resource` | Fixed reference stage over a host- or hand-supplied workspace manifest | Untrusted behaviour-shaping data | Per-class ceiling; refused when over |

Every block descriptor records source reference, content digest, provenance
class, trust class, byte cost, and token cost, and the receipt records them in
final order together with the fixed reference provider identity and revision.

### Project-resource discovery, manifest, and trust

Discovery happens where the filesystem is. Core holds `workspace_ref`, which
§15.2 makes opaque to it; core never canonicalizes, joins, stores, or opens a
path, and no durable core record contains one. The supplier is the host or the
hand that interprets `workspace_ref` — in the `M2` single-machine topology, the
local hand — and it crosses the same boundary tool execution already crosses.

Responsibilities split as follows, and neither side can do the other's job:

| Step | Owner | Data crossing the boundary |
| --- | --- | --- |
| Interpret `workspace_ref` and locate its root | Host or hand | Nothing; the resolution stays on that side |
| Resolve the one permitted label, `AGENTS.md` at the workspace root | Host or hand | — |
| Enforce path containment, including through a symlinked component | Host or hand | Per-entry `contained: true` or a bounded refusal reason naming containment, never the target path |
| Read each resolved resource once and digest exactly the bytes read | Host or hand | `{relative_label, byte_size, content_digest}` per entry, plus the bounded content bytes |
| Verify content against digest and size, enforce ceilings, order, digest the manifest, bind the trust decision, stage | Core | — |

The supplier reads each resource once, at manifest construction, and digests
exactly the bytes it read, so the digest and the content core admits describe
the same read. Absence is not an error; it produces an empty manifest. Core
rejects the whole manifest — it does not repair it — when an entry carries a
label other than the one permitted, when content does not match digest or size,
or when an entry is not reported as contained. Core cannot verify containment
itself, which is exactly why it must fail closed on a missing containment report
rather than assume one.

Limits are declared, and every one of them fails closed rather than trimming:

```text
per_resource_bytes   64 KiB
class_total_bytes    64 KiB
class_token_ceiling  the project_resource per-class budget above
```

The manifest is canonical plain data in label order:

```text
entries        [{relative_label, byte_size, content_digest, contained}]
workspace      {workspace_ref, repository_origin | nil, revision | nil}
manifest_digest digest over the canonical encoding of entries and workspace
```

`workspace_ref` is the opaque identity core already holds, carried verbatim and
never interpreted. `repository_origin` and `revision` are bounded host-supplied
strings; core treats them as opaque labels that participate in the digest, not
as things it resolves. `relative_label` is a bounded display string: it appears
in the manifest so an operator can see what they are trusting, and core never
joins it to anything.

Content supplied ahead of a decision is held only as unstaged bounded data: it
is verified against its digest, counted against the ceilings, and discarded
without ever entering a request when the decision is absent, stale, or negative.
A supplier may equally send the manifest first and the content on admission; core
requires only that whatever it stages matches the digest the decision was made
about.

Content never influences discovery. An `@import`, include directive, or link
inside `AGENTS.md` is inert text; the resolved set is the one permitted label and
nothing an admitted file says can add to it. Because core verifies the label set
rather than trusting it, a supplier that widens discovery on its own does not
widen what core stages.

The trust decision is host-owned and Loopex-bound. Core exposes the manifest and
its digest as a read-only projection so a client can display it without
admitting anything; the decision is supplied at session start as bounded plain
data:

```text
manifest_digest    exact digest the decision was made about
workspace_ref      the opaque canonical workspace identity, carried verbatim
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
| Manifest rejected: unpermitted label, digest or size mismatch, or missing containment report | Class staged empty; receipt records `project_resource_declined(manifest_rejected)` with the failing reason |
| No manifest supplied at all | Class staged empty; receipt records `project_resource_declined(no_manifest)`; core discovers nothing on its own |
| Interactive client, no decision yet | Client displays each entry's label, size, and digest plus the manifest digest, asks once, and supplies the answer at session start |

The interactive reference command persists nothing on Loopex's behalf; whether a
host remembers an answer between sessions is host retention policy, and a
remembered answer is admitted only when its `manifest_digest` still matches.

Admitted content stays subject to tool policy: no block changes the active tool
set, the policy decision, the bounds, or a grant, and typed delimiters around
untrusted blocks are input structure rather than a security boundary.

Total budget is enforced before dispatch. An assembly that cannot fit its
declared total ends the run `failed`, naming the exceeded ceiling and the
observed size, rather than dropping history, because silently dropping a message
would make the projection non-deterministic and break the property the receipt
exists to prove. It is deliberately not `bound_reached`: the run's declared
bounds are the three stopping controls its operator chose — turns, tokens, and
deadline — and reaching one is a run finishing where it was told to. A context
assembly that cannot be built inside its ceiling is a staging fault, and calling
it a reached bound would hide a configuration defect inside the outcome an
operator reads as normal completion of a bounded run.

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

### Real-call attestation

The reply value carries one further field beside the assistant content and the
usage report:

```text
provider_attestation ::
  {:reported, %{response_id: binary(), input_tokens: non_neg_integer(),
                output_tokens: non_neg_integer()}}
  | :unreported
```

`response_id` is the provider's own identifier for that response, copied
verbatim and never rewritten. The values are bounded plain data under the
boundary rule: no provider struct, no reference, no atom derived from provider
input. The deterministic adapter returns `:unreported` unconditionally; it has
no identifier to copy and must not invent one.

Where the attestation goes, and where it must not:

| Plane | Carries the attestation |
| --- | --- |
| Diagnostic and retained evidence | Yes. This is its only home |
| Durable conversation element, staged request, canonical bytes, digest | No |
| Reserved continuation field | No. It is empty in every `M2` request |
| Projection, replay, any later request | No. Nothing reads it back |
| Run admission, bound enforcement, outcome | No. `:unreported` is a normal run |

Retained records use one line per real-provider role, in the locked role order,
with this exact key order:

```json
{"role":"<demonstration_db|inherited_5c|inherited_8b>","selector":"<safe tracked path>","provider":"<lowercase provider>","model":"<printable>","endpoint":"<printable>","adapter_build":"<printable>","calls":<positive integer>,"response_id_form":"<prefix>:<min>-<max>","provider_response_ids":"<id>+<id>...","input_tokens":<positive integer>,"output_tokens":<positive integer>,"candidate":"<40 lowercase hex>","recorded":"<RFC3339 UTC>"}
```

`provider_response_ids` names every provider response the role observed, in
order, and `calls` is their count. `input_tokens` and `output_tokens` are the
totals the provider reported across exactly those responses. The record names no
credential, no prompt text, and no workspace content.

The identifier form is declared by the record, not enumerated by the checker.
`response_id_form` carries the shape the named provider documents, written
`<prefix>:<min>-<max>`:

| Part | Admitted values |
| --- | --- |
| `prefix` | One to sixteen characters from `[A-Za-z0-9_-]`, non-empty |
| `min`, `max` | Integers with `1 <= min <= max <= 128` |
| Remainder | `min` to `max` characters from `[A-Za-z0-9_-]` |

Anthropic's documented form is written `msg_:16-64`; OpenAI's chat-completions
form is `chatcmpl-:8-128`. Neither is named in any checker. Every record in one
retention declares the same form, since all of them already agree on the
provider that run sealed.

A checker carrying a provider allowlist would make adding an adapter a
governance event, which contradicts the replaceable model boundary this
repository builds on. Declaring the form instead is weaker — a fabricator
declares their own — and the weakness is recorded here rather than papered over,
because what the mechanism is worth was never the form.

What a checker proves, and what it cannot, stated so nothing infers more:

| Proved mechanically | Left to a person |
| --- | --- |
| The record exists, is exactly three canonical lines in the locked role order, and names each role's locked selector | That any network call happened at all |
| Each identifier matches the form its own record declares for the provider the bound selector runner sealed in the same run, that form is well shaped, and every record in the retention declares it identically | That each identifier exists in the provider account, and that the declared form is the one the provider actually documents |
| No identifier is reused within or across roles | That the reported usage matches the billed call |
| The record's provider, model, endpoint, and adapter build are byte-identical to the identity that same run sealed | That the record describes *this* run rather than an earlier one |
| `calls` equals the identifier count and meets the floor its role's locked cases imply, and the reported totals are internally consistent with it | Whether the demonstration was a genuine task |

The right-hand column is the honest content of the mechanism. A fabricator who
is willing to write a fake adapter can still emit a well-formed identifier of
the correct shape, a plausible usage pair, and a consistent count, and the
checker will accept all of it. What changes is that the fabrication is now
externally falsifiable: the identifiers either appear in the provider account
for that window or they do not, and the reviewer who looks is checking a
specific claim rather than reading prose.

### Evidence

- One real-provider reply asserted to carry a `provider_attestation` whose
  `response_id` matches the form the retained record declares for that provider,
  with the deterministic adapter asserted to return `:unreported` for the
  identical request, so the distinguishing property is proved rather than
  assumed.
- A real-provider evidence case fed a reply whose attestation is `:unreported`,
  asserting that the case fails; and the same reply driven through an ordinary
  run, asserting that the run proceeds normally and is accounted conservatively,
  so the requirement lives in the evidence claim and becomes a provider
  allowlist neither at runtime nor in the checker.
- The attestation asserted absent from every durable element, staged request,
  canonical digest input, projection, and the reserved continuation field.
- Byte equality between the committed staged request and what the real provider
  adapter received, for a multi-turn run with real tool results.
- Replay after a restart mid-run producing a byte-identical projection and
  dispatching the same staged bytes for an unresolved intent.
- Missing staged bytes failing closed as `unavailable(staged_context_missing)`
  rather than being recomputed.
- Source-order properties: results committed out of completion order still
  commit in call order; staging is refused while a call lacks a result; a
  malformed tool call never becomes an element.
- Each bound reached in isolation, asserting `bound_reached` carries the named
  bound and the observed value and nothing else, with the accounting source
  retained beside it in the same commit; that no provider call
  was made for the refused turn; that no assistant message was fabricated; and
  that the committed outcome is neither `failed` nor `completed` and carries no
  failure category or retryable flag.
- The deadline firing while a reply is in flight, run in all three journal
  orders. A **no-tool** reply committed before the abort is admitted ends the run
  `completed`, and the later deadline firing is asserted to be a no-op that
  neither rewrites the outcome nor emits a second terminal event. A
  **tool-calling** reply committed first keeps its assistant message and complete
  tool calls in canonical history, dispatches no call whose intent would commit
  after the deadline, gives every such call a terminal `cancelled` result, and
  ends the run `bound_reached` naming `:deadline`. An **abort admitted first**
  leaves no assistant message, and a reply delivered afterwards is retained as
  attempt evidence without entering canonical history. The supervised call is
  asserted to end at the committed instant rather than when the provider chooses
  to.
- The run deadline reaching executor jobs, driven by a real long-running job
  rather than a stub: the committed instant appears on every `JobRequest`; a job
  whose tool wall-time budget exceeds the remaining run deadline is bounded at
  the run deadline; the job is cancelled at that instant and its owned process
  tree is confirmed cleaned; the run commits `bound_reached` naming `:deadline`
  only after that confirmation; and the same case with cleanup made unconfirmable
  by injection commits `outcome_unknown` with a reconciliation reference instead,
  proving the precedence rather than assuming it.
- A turn aborted after dispatch, asserting that the cumulative counter grows by
  the request bytes plus the full committed `max_tokens` allowance, that the
  value is marked `estimated`, and that repeated aborts therefore exhaust the
  token budget instead of running free.
- A staged request replaying byte-identically after the tool registry is edited,
  version-bumped, and emptied, asserting that projection and verification read no
  registry and that the full definition bytes are what the adapter received.
- The reserved continuation field empty in every staged request of a multi-turn
  real-provider run, with the run's continuity attributable to projection alone.
- A provider reply with no usage field, asserting that the token bound is still
  enforced from the committed canonical bytes, that the accounted value is
  marked `estimated`, that the estimate is not below the reported value for a
  control turn of the same content, and that no path exists by which the check
  is skipped.
- A run interrupted and resumed, asserting the same `run_id`, the same committed
  bounds, the same staged bytes, and a token counter that continues rather than
  restarts; and a run whose committed deadline elapsed while its owner was down,
  asserting `bound_reached` naming `:deadline` on recovery
  with no provider call.
- A completed session prompted again, asserting a new run identity, freshly
  committed bounds, a zeroed token counter, refusal while a run is still active,
  and a projection covering both runs.
- A model change refused: no `set_model` command exists, and every run of one
  session stages the model identity committed at session creation.
- Provenance and budget: a project resource refused without a trust decision, an
  invalidated decision after a digest change, an over-budget assembly failing
  closed, and a receipt whose ordered descriptors match the staged request.
- Discovery determinism: the same workspace produces a byte-identical manifest
  and digest across runs; a supplier report of an `AGENTS.md` that escapes the
  root through a symlinked component is refused for containment; an over-ceiling
  file is declined rather than truncated; a decision bound to a stale manifest
  digest admits nothing; and an import directive inside an admitted file adds no
  resource.
- Core's filesystem abstinence: no core module resolves, joins, or opens a
  workspace path, no durable core record contains one, a manifest carrying an
  unpermitted label or content that mismatches its digest is rejected whole, an
  entry without a containment report is refused, and a session with no supplied
  manifest stages the class empty rather than reading anything itself.
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

**Collecting the attestation live from the running selector.** A checker-owned
directory, one file per role, written by the real case and read after it. The
appeal is real: it is the only shape that binds a retained identifier to the run
that produced it, and it would make a copied-forward record impossible rather
than merely detectable. The arithmetic still fails. The file would be written by
the same test code that writes the identity report, so the set of things a
fabricator must produce is unchanged and only their location moves. Against
that, it adds an unauthenticated channel beside `M1`'s sealed result — the one
path deliberately made authoritative, and the one whose singularity the reused
runner's own corpus protects — and it makes a checker-owned environment variable
part of a product test's contract. The staleness it prevents is visible to the
reviewer comparing timestamps and identifiers against the provider account,
which is the step that must happen regardless.

**Cross-checking reported input tokens against the committed canonical bytes.**
Superficially the strongest available check: both quantities exist, and a
mismatch would be damning. It is not available. The checker holds neither a
provider tokenizer nor the finished run's journal, so it could only compare the
reported count against a repository-owned estimate through a tolerance band, and
that band would be a configured number with no evidence behind it — the same
objection this decision raises to a minimum-remaining-time threshold. Worse, the
band is public: a fabricator computes it from the same estimator and lands
inside it. Reported usage is retained for the auditor, who can look up one
response identifier and compare, and the gate records it as retained evidence
rather than as enforcement.

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

**Checking the deadline only between turns.** The cheapest rule, and the one
`M1`'s shape suggests. It fails on the exact case the deadline exists for: a
provider that accepts a request and then holds the connection. Between-turn
sampling bounds idle time and leaves the busy time unbounded, so a run could pass
its declared instant by an arbitrary margin with every check reporting compliance.
Propagating the instant costs one field in the staged request, one armed abort in
the supervising process, and one explicit race rule; the alternative costs the
bound its meaning.

**Bounding the model call but not the executor job.** Half the plumbing for most
of the benefit: the model call is where a run stalls longest, and tools already
declare wall-time budgets. The arithmetic defeats it. Independent budgets add
rather than compose, so the run's worst case is its deadline plus the longest
tool budget still dispatchable, and during that overrun the run cannot reach a
terminal outcome at all, because it holds an unresolved owned operation. The
observable result is a run whose printed wall-clock bound is not the bound it
respects — precisely the defect the in-call enforcement above was added to fix,
surviving in the other half of the run's owned work. The minimum rule costs one
field on the job and reuses ADR 0009's cancellation sequence unchanged.

**One race rule: whatever the deadline catches becomes `bound_reached`.** It
keeps the table to two rows and needs no case analysis. It is rejected because it
overwrites validated terminal facts. A no-tool final reply that committed first
is a completed run; restating it as a bounded stop contradicts the immutability
the terminal set depends on, and produces a transcript whose final answer sits
under an outcome saying the run was cut short. Splitting the cases costs one more
row and one more selector.

**Discarding a post-deadline tool-calling reply, or dispatching its calls
anyway.** The two opposite shortcuts for the middle case. Discarding the reply
removes a fact the provider produced and was billed for, leaving the last
committed turn absent from a history whose purpose is replay. Dispatching its
calls admits effectful work after the instant the run declared, and there is no
path by which it could happen: dispatch legality is decided once at the
tool-operation intent commit, and past the deadline no intent commits, so no
grant is minted and no job exists for the executor to accept or refuse. Keeping
the message and cancelling its calls is the only option that neither fabricates
history nor admits unbounded work.

**A minimum-remaining-time threshold before dispatch.** Refusing to start a tool
with less than some margin left avoids obviously doomed work. The margin is the
problem: any value is an unevidenced constant, per-tool values multiply the
decision, and the rule adds a second reason a call never ran that operators would
have to tell apart from the first. Checking `now < run_deadline` at intent commit
and bounding whatever is admitted keeps one rule and one code path.

**Encoding a reached bound as a `budget_exhausted` category of `failed`.** It
leaves the terminal set alone, it is additive inside a set conformance vectors
and event consumers will treat as exhaustive, and `failed(category,
retryable?)` has a slot the fact fits mechanically: a named category and
`retryable?` of `false`. It is refused on what consumers can see rather than on
naming. Grouping by terminal value is the cheapest and most common thing done
with a run outcome, and this encoding puts a configured stop and a genuine
breakage in one bucket, separable only by a consumer that reads the category —
which is precisely the distinction an operator most needs from a list of
sessions. A public value that is truthful only one level down misleads by
default. `retryable?` is a second problem: the bounds are committed with the run,
so a retry under the same identity re-evaluates the same limits and stops again,
and the flag has no honest content to carry.

**Charging an aborted turn only observed output, or nothing.** The most accurate
rule where output is observable. It is not available here: streamed partials are
transient progress that nothing durable retains, so an observed count would not
survive a restart and would not be recoverable by a successor owner, and where
nothing was observed the charge is zero — making abort-and-retry the cheapest
way to stay inside a token budget forever. The committed `max_tokens` allowance is
already in the committed bytes, is recoverable, and is never below what the
provider could bill for that turn. Its weakness is over-charging an early abort,
which is the direction a bound must err in.

**Core resolving the workspace path and reading `AGENTS.md` itself.** In `M2` the
brain and the hand share a machine, so core could open the file with no protocol
at all, and the reference stage would be a few lines. It contradicts §15.2: core
would hold a POSIX path, require brain-local filesystem access, and own a
containment check it cannot perform once the hand is a container, a remote
checkout, or a volume snapshot. It would also make the first remote hand a
migration of durable records rather than a placement change, since a real path
would already be inside committed manifests and bindings. Requiring bounded
manifest entries and content evidence from the supplier costs one boundary
crossing and one verification step, and keeps every filesystem fact on the side
that can prove it.

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
- Long sessions end rather than degrade. `bound_reached` is the honest outcome
  and it will be experienced as a limitation; documentation must say so plainly
  rather than describe it as a safeguard. A consumer grouping runs by terminal
  outcome now shows a configured stop as its own ending without reading a reason
  code, which is the point of the value, but only once it has a case for it.
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
- Every staged request carries the full active tool definitions, so request size
  and per-turn token cost grow with definition size on every turn rather than
  once. In exchange a staged request means something without the registry, and
  terse tool descriptions become a cost decision rather than a style one.
- The reference stage needs a supplier. Core discovers nothing, so the local hand
  and the reference CLI each gain a small manifest responsibility, and a host that
  supplies nothing gets an empty class with a journalled reason rather than an
  error. This is the same shape the executor boundary already has, and it is what
  keeps the first remote hand a placement change rather than a record migration.
- The deadline reaches into the model call, so an in-flight reply can be
  discarded after the provider has billed for it, and the supervised call gains
  one more abort path with its own crash cases. The alternative was a wall-clock
  bound that does not bound the only part of a run that is slow.
- The deadline also reaches every executor job, so it can kill OS work in
  progress. A tool's declared wall-time budget becomes a ceiling the run can
  lower but never raise, a definition no longer determines a job's maximum
  duration on its own, and shortening a run deadline shortens every tool call
  inside it. Because the bounded stop waits for confirmed cleanup, a deadline is
  not instantaneous, and a run that hit its deadline can finish
  `outcome_unknown`. Every surface rendering a run outcome carries that second
  deadline ending, and no documentation may describe a deadline as a clean stop.
- A run can end with an assistant message whose tool calls all read `cancelled`.
  It is the honest record of a model asking for tools with no time left, and it
  costs a transcript that reads like a run which did nothing until the reader
  reaches the run outcome. That is one more consumer obligation on
  `bound_reached` rather than a new one.
- An aborted turn is charged its whole `max_tokens` allowance, so a run with
  several cancellations can exhaust its token budget having been billed for
  considerably less. Over-charging is the deliberate direction and the
  `estimated` marker keeps it inspectable, but operators comparing Loopex's
  counter with a provider invoice will see the gap.
- `bound_reached` is a new member of the run terminal set, so the rules a
  failure category would have inherited have to hold for it explicitly and be
  asserted rather than assumed: exactly one initial `run.finished` carries it,
  it is terminal for the run, it never rewrites a tool-call outcome, it never
  overwrites a validated terminal fact the run already committed, and a
  reconciliation fact about an in-flight effect still appends rather than
  replacing it.

### If rejected

- The loop keeps a synthesized second turn and no history, so the v0.1 rung's
  central claim — a real agent loop — cannot be made honestly.
- Without a termination condition, either the two-turn arithmetic stays or the
  loop becomes unbounded. The first is not a loop and the second has no truthful
  terminal outcome.
- Without provenance and budget rules, the first project-resource stage would
  admit workspace content into model context with no trust decision and no
  accounting, which contradicts project-resource admission and would be much
  harder to retrofit once a receipt format exists. The likely shortcut is core
  opening a path directly, which would put a filesystem dependency inside the
  kernel and a real path inside durable records.

<a id="technical-adr-0010-compatibility"></a>
## Format, Migration, and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0010-provider-continuation-and-context-staging.md#concept-adr-0010-compatibility).

The durable format gains user, assistant, and tool-result conversation elements,
the staged request record with its `canonicalization_version` and digest, the
context receipt with ordered block descriptors, the committed run bounds, and
the `bound_reached` run terminal outcome with its bound name and observed value,
and the sibling fields of that terminal record carrying the declared limit, the
accounting source, and the reported and estimated subtotals. All are bounded
plain data in the session mutation domain
and reach a public plane only through existing bounded events.

There is no installed base and no published package, and `M2` tags no version:
`VERSION` stays `0.0.0` and the first version number belongs to the headless
session-protocol milestone. The request format, element shapes, receipt, trust
binding, and bound outcomes freeze nothing. The one thing that is not
experimental is the vision's closed run terminal set, and it changed by explicit
maintainer decision rather than by this ADR: the vision pair now holds
`bound_reached` as a member, and `M2` implements that decision. Nothing migrates.
No version is released, no public protocol yet carries a run outcome, and no
session record exists in which a reached bound was written as a failure
category, so there is no consumer to update and no journal to project forward.
The set stays closed with `bound_reached` in it, and a later decision wanting a
further terminal is a vision change of the same kind, needing its own evidence
and consumer analysis and, by then, a migration for consumers written against
the set as it now stands. `M1` journals are neither read nor migrated; the `M1`
synthesized second-turn record has no successor form, and `M1`-owned test roots
are discarded.

The run's committed absolute deadline also reaches durable form outside this
decision's records: it is carried in the staged request here and canonicalized
into every `JobRequest` under
[ADR 0009](0009-tool-executor-and-grant-contracts.md#concept), where it is
covered by that attempt's attempt-bound `canonical_request_digest` and adds no
grant binding.
It qualifies because it is an immutable semantic field of the run. The effective
job deadline ADR 0009 derives per attempt is durable operational state carried
alongside that digested request and is deliberately outside the digest, because
it is dispatch-local wall-clock rather than an immutable semantic job field: it
records when this dispatch stops waiting, not what work was authorized.

That is a different question from retry identity, and the two must not be
conflated. Retry identity is itself two rules, one per digest kind, and this
milestone states both rather than generalizing either. For an executor effect,
the job canonicalization the
[technical vision](../vision-technical.md#technical-depth) fixes covers operation
*and attempt* identity, so two attempts of one operation carry two different
attempt-bound `canonical_request_digest` values by construction; each attempt is
reconciled against the digest recorded
for that attempt, and ADR 0007's retained tuple already names the original
attempt alongside its journaled digest. Nothing about the executor job digest
depends on, or may assert, digest sameness across attempts. For a model call, the
same technical vision fixes the opposite rule for the opposite reason: the
canonical model request has no operation or attempt member, so a retried attempt
dispatches the same staged bytes under the same `staged_request_digest`, and
nothing about the model request may assert digest difference across attempts.
`operation_id` is the stable identity across attempts in both cases, and it is
the only identity either rule shares.

Rollback before closure removes the conversation elements, the projection, the
bounds, the deadline's propagation into the supervised model call and onto every
executor job, the `bound_reached` outcome, and the context receipt together,
restoring
`M1`'s single-message request and its two-turn arithmetic. It cannot be partial,
because the termination condition reads the assistant message shape and the
assistant message shape exists only as a conversation element.

Once a version is published, a canonicalization change, an element shape
change, or a receipt change is an additive versioned change carrying fixtures
and a projection rule for journals written under the previous version. Adding a
provenance class, adding a bound, changing what an incomplete turn is charged,
or making the reserved continuation field non-empty each change what a recorded
receipt, counter, or digest meant and therefore require a successor decision
rather than an edit. Widening the permitted discovery label set is the same kind
of change, because the manifest digest an operator trusted was computed over the
narrow set.
