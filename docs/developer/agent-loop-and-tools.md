# Agent Loop and Tools

<a id="concept"></a>
## Concept

M2 turns M1's fixed two-turn trace into a loop that finishes a coding task. A
session runs as many model turns as the work needs; every request carries the
whole conversation the session has committed — the operator's prompt, the
model's own prior messages, and the real output of every tool it ran; deltas
reach the operator while a reply is still incomplete; and a named set of tools
acts on a real workspace under a host policy that can refuse.

Three declared bounds stop a run the model will not stop itself: a maximum
number of model turns, a cumulative token budget, and a wall-clock deadline.
Reaching one is not a failure. A run ends `completed` when the model stops
asking for tools, `bound_reached` when a declared bound decides, `cancelled`
when an abort proved every owned operation terminal and every captured executor
process group associated with those operations quiescent, and `outcome_unknown`
when it could not. Nothing infers an outcome from
silence.

Authority stays with the host. Every executor-backed call consults
`Loopex.Policy` — a read-only tool asks exactly as a process-spawning one does —
and anything that is not a well-formed allow is a denial, including a policy
that raises, blocks, or answers `defer`. A denial is a committed outcome the
model is told about and is never retried. A runtime that has any tool active and
no policy configured refuses to start.

A tool is bounded plain data, not a function or a module: an identity, the bytes
a model is shown, and the declared class of effect and cost that running it may
incur. Its identity is the generation triple `{tool_id, tool_version,
definition_digest}`, and a staged request carries the complete definition
records it used, so what a model was shown stays reconstructible from the
journal after the registry that held them has changed. Registration is
append-only and scoped to one runtime; being registered and being offered to a
model are separate facts.

None of these surfaces is frozen or labelled:
[Compatibility surfaces](compatibility-surfaces.md#concept).

Operator workflow: [Coding sessions](../operator/coding-sessions.md#concept).
Tool reach and policy selection:
[Tools and policy](../operator/tools-and-policy.md#concept).

<a id="technical-depth"></a>
## Technical depth

### Where the Loop Lives

| Module | Owns |
| --- | --- |
| `LoopexProtocol.ToolDefinition` | the nine-field tool record, its validation, normalization, narrowing report, and generation triple |
| `LoopexProtocol.Canonical` | the one plain-data encoding and digest this repository retains |
| `Loopex.ToolRegistry` | one runtime's registered generations; append-only, unnamed, resolved through the runtime reference |
| `Loopex.Conversation` | the pure projection from committed elements to the canonical message list |
| `Loopex.Model` | the provider-neutral request, its `staged_request_digest`, the reply shape, and the delta contract |
| `Loopex.Bounds` | the three declared bounds, the turn decision, and token accounting |
| `Loopex.StreamDomain` | attempt-scoped progress identity and the closing items a domain is owed |
| `Loopex.Policy` | the host authority port and its fail-closed resolution |
| `Loopex.ArtifactStore` | the spill port, its reference shape, and the truncation notice |
| `Loopex.ProjectResource` | manifest verification, the trust binding, and the staged or declined receipt |
| `Loopex.Runtime.SessionCoordinator` | the serial owner: the only process that commits, dispatches, and stamps a stream domain |
| `Loopex.Executor.Local.CodingTools` | the four shipped definitions and workspace-root resolution |
| `Loopex.Store.Local.Artifacts` | the local content-addressed artifact objects |

### The Tool Contract

Every definition carries these nine fields, all required, with binary keys:

| Field | Shape |
| --- | --- |
| `tool_id` | dot-segmented lowercase ASCII, at most 128 bytes; the `loopex.` prefix is reserved |
| `tool_version` | exact `major.minor.patch` |
| `name` | model-visible name matching `^[a-z][a-z0-9_]{0,63}$` |
| `description` | non-empty model-visible text, at most 4096 bytes |
| `parameter_schema` | the evaluable JSON-Schema subset below |
| `result_shape` | `content_type` of `text` or `json`, plus an optional description |
| `effect_class` | `read_only`, `workspace_write`, `process`, or `external_effect` |
| `idempotency_class` | `safe_retry`, `reconcile_then_retry`, or `never_blind_retry` |
| `budgets` | positive `wall_time_ms`, `output_bytes`, and `artifact_bytes` ceilings |

The schema subset is an object root, named properties, and a required-name list.
Property types are `string`, `integer`, `number`, `boolean`, or `array` of a
scalar item type, each with an optional description and an optional non-empty
string enumeration. Nested objects, unions, `$ref`, and conditional keywords are
refused at registration rather than ignored at dispatch.

`validate/1` is total and returns every reason it found, each a bounded binary
naming the field. `valid?/1` is the boolean form.

`normalize/1` completes a host's partial declaration: it accepts `input_schema`
as a name for `parameter_schema`, defaults `result_shape` to text, defaults
`idempotency_class` to `never_blind_retry`, and defaults `budgets` to 120000 ms,
65536 output bytes, and 8388608 artifact bytes. It then narrows the schema to
the keys the kernel can evaluate — the root keeps `type`, `properties`, and
`required`; each property keeps `type`, `description`, `enum`, and `items`.
A property whose *type* is outside the subset is refused by `validate/1` instead,
because dropping it would silently widen what the tool accepts.

`narrowing/1` reports what `normalize/1` would drop, as dotted paths such as
`parameter_schema.additionalProperties` or
`parameter_schema.properties.path.const`. `Loopex.ToolRegistry.init/1` sends one
`tool_schema_narrowed` item per affected declaration to the runtime's
diagnostics sink at start. That plane is transient: a runtime started with no
`:diagnostics_to` pid loses the notice, which is why the same limitation is
documented on `normalize/1` itself.

`canonical_bytes/1` covers the definition-version tag
`loopex.tool_definition.v1`, the canonical-encoding version, and all nine
fields, and raises on an invalid definition rather than returning bytes a caller
might retain. `definition_digest/1` is its lowercase hexadecimal SHA-256, and
`generation/1` returns `{tool_id, tool_version, definition_digest}` — the value a
staged request records, a tool intent journals, and a grant binds. `model_facing/1`
projects the three fields an adapter renders into a provider's own tool format;
core never stages that projection in place of the record.

### One Canonical Encoding

`LoopexProtocol.Canonical.encode/1` is `:erlang.term_to_binary/2` with
`:deterministic`, applied to a recursively ordered projection: maps become
key-sorted `{:loopex_map, pairs}` tuples, so an equal map encodes identically
regardless of insertion order. The walk is exhaustive over bounded plain data
and raises on a pid, port, reference, function, or improper list.
`digest/1` and `digest_bytes/1` return lowercase hexadecimal SHA-256, and
`version/0` returns `loopex.canonical.v1`, which is carried inside structures
that digest themselves so a retained digest always names the encoding that
produced it.

The encoding is length-aware and therefore injective over arbitrary binary
identifiers, which is what a delimiter-joined string cannot promise and what
`stream_domain_id` requires.

Its production callers are `LoopexProtocol.ToolDefinition` (generation digest),
`Loopex.Model` (staged request bytes and digest), `Loopex.StreamDomain`
(`stream_domain_id`), `Loopex.ProjectResource` (per-entry content digests and
the manifest digest), `Loopex.Policy` (the canonical byte ceiling on decision
attributes), and `Loopex.Store.Local.Artifacts` (content addressing). The
module's own documentation names four contracts that depend on one answer;
`Loopex.Executor` is the fourth by technique rather than by call — it computes
its job bytes as `:erlang.term_to_binary(ordered, [:deterministic])` over its own
`job_fields/0` projection, unchanged from M1, and digests them with `:crypto`
directly.

### The Runtime-Scoped Tool Registry

`Loopex.ToolRegistry` is an unnamed `GenServer` and the first child of
`Loopex.Runtime.Supervisor` under `:rest_for_one`, resolved through the retained
runtime reference by `Loopex.Runtime.tool_registry/1`. Two runtimes in one VM
hold independent tool sets and neither can observe or displace the other's:
there is no registered name, application-environment key, or persistent term
keyed by tool identity.

Admission is append-only and compares canonical bytes rather than digests:

| Offered | Result |
| --- | --- |
| A new `{tool_id, tool_version}` | `:ok`, retained |
| An identical definition under an identity already held | `:ok`, nothing changes |
| A different definition under an identity already held | `{:error, :tool_definition_conflict}` |
| A new `tool_version` of a known `tool_id` | `:ok`, admitted additively |
| A reserved `loopex.` identifier through `register/2` | `{:error, :reserved_tool_namespace}` |
| A name outside the declared charset | `{:error, :invalid_tool_name}` |

A reserved identifier enters only through the runtime's `:tools` start option,
which is the reference distribution declaring its own tools; the start option is
the boundary, so no trust flag is needed on the call. An invalid or conflicting
definition in that list refuses runtime start rather than leaving a runtime
half-composed. There is no unregistration and no replacement in M2.

`resolve/2` returns the highest version by numeric component order, so `0.10.0`
resolves above `0.9.0`; `resolve/3` distinguishes `:unknown_tool` from
`:unknown_tool_generation`. Registry contents are configuration, not session
truth: nothing here is journaled, and projection and replay never read this
process.

Name collisions are not refused at registration, because two generations may
legitimately claim one model-visible name as long as they are never
simultaneously active. `compose_active_set/2` is where the rule is enforced — it
resolves each selection, builds `name -> generation`, and refuses the whole
composition when a name is claimed twice, naming both claiming generations, with
no precedence and no disambiguation suffix. In the M2 runtime that function is
exercised by its own conformance corpus; the session's active set is composed at
runtime start by `Loopex.Runtime.Control`, which filters the configured `:tools`
by the `:active_tools` selections and hands the coordinator the resulting
definition records. Either way the mapping is fixed for the session's lifetime,
so a registration made mid-run can neither add, remove, nor repoint a name the
model has already been shown.

### The Conversation Projection

`Loopex.Conversation.project/2` is pure. It reads no process state, performs no
retrieval, consults no registry, and derives no content; given the same
committed elements it produces byte-identical output. That is what makes a
successor able to rebuild the request its predecessor would have staged.

Three committed element kinds project:

| Element | Carries |
| --- | --- |
| `user_message` | `run_id`, `command_id`, the exact prompt bytes |
| `assistant_message` | `run_id`, `turn_number`, content, ordered tool calls, stop reason, usage |
| `tool_result` | `run_id`, `turn_number`, `tool_call_id`, terminal outcome, bounded model-facing content |

The order is fixed: the versioned system block, then any admitted
project-resource blocks, then the run's prompt, then each turn's assistant
message followed by that turn's results *in the assistant's own call order*
regardless of the order they completed in. An element that cannot be placed
raises rather than being skipped, because a shorter conversation than the
journal describes is a defect, not a tolerance.

`turn_settled?/1` is false until every call of the latest assistant message has
a committed terminal result, and no next request may be staged while it is.
`admits_result?/3` admits a result only for the immediately preceding assistant
message of the same run and only when every earlier call in that message's order
already has one. `result_content/2` gives every outcome in
`[:completed, :failed, :denied, :cancelled, :outcome_unknown]` a bounded form; a
denial tells the model not to retry, and an `outcome_unknown` says plainly that
whether the call took effect is unknown.

### Two Request Digests

`Loopex.Model.request/3` builds one closed semantic projection —
`canonicalization_version` (`loopex.model_request.v1`), `model`, `messages`,
`tools`, `sampling`, `deadline`, and `continuation` — and returns it with
`canonical_request_bytes` and `staged_request_digest`. The coordinator commits
those bytes before an adapter sees them, and `validate_request/1` recomputes the
projection and requires both byte and digest equality, so replacing one
representation self-consistently is refused.

`:sampling` and `:deadline` are required and neither has a default here: a
request without a declared `max_tokens` is refused rather than truncated at
dispatch by a number no record names. `continuation` is structurally present,
always `nil`, and never read, written, or compared in M2; it exists so a later
adapter-private continuation handle can land without changing what the
canonicalization covers. The declared limits are a model identifier of 1 to 512
bytes, 1 to 1024 messages, at most 256 tool definitions, and `max_tokens` in
1..1_000_000. Tools are complete definition records, not the model-facing
projection.

The executor's `canonical_request_digest` is a different name for a different
rule, and the two were deliberately separated:

| Property | Model request | Executor job |
| --- | --- | --- |
| Digest name | `staged_request_digest` | `canonical_request_digest` |
| Covers attempt identity | no | yes, `operation_id` and `attempt` are job fields |
| A retry | opens a new durable attempt over the same staged bytes and digest only after exact pretransport refusal | canonicalizes its own attempt and therefore computes a new digest |
| Attempt limit in M2 | attempt one, then attempt two only after attempt one settles `not_dispatched` | governed by the effect's idempotency class and reconciliation |

One identifier carrying both rules carried two opposite retry meanings, which is
why the model side was renamed and the bytes kept their name.

The staged digest is identity, not dispatch authority. First staging commits
`model_request_committed` and `model_attempt_opened_v1` together; a request row
without its consecutive open row exposes no dispatchable request. After the
open fact is durable, Runtime Control validates the complete current owner,
operation, attempt, digest, journal position, worker, permit reference, and
deadline, samples the deadline again immediately before sending one fresh permit
directly to that worker, and spends the attempt with that send. The receiving
worker compares the same committed deadline immediately after receiving the
permit and before entering the adapter. The send remains the
provider-dispatch linearization point: a permit that arrives late is retained as
possibly dispatched and is never retried, even though the receiver makes no
provider call. The spent attempt identity survives
owner and worker replacement, so no timeout, lost reply, dead worker, or
successor can mint a second call for it.

The Store read that rebuilds the committed binding is owned by a guardian that
monitors Runtime Control. A timeout or Control death kills and awaits the exact
reader, and its successful result is forwarded only after that reader exits. A
model result likewise retains its worker-provenance wrapper through admission,
so adapter data cannot impersonate the receiver's private deadline result.

A conforming adapter may report `not_dispatched` only before it invokes or
hands bytes to provider transport. The coordinator proves the same fact for one
window of its own: between the attempt-open commit and the
`Control.provider_dispatch/3` that sends the permit, it holds the open attempt,
it has not asked for the identity to be spent, and no other process may ask for
it — so an abort or a deadline arriving there settles `not_dispatched` and
charges nothing. That claim needs both halves. An attempt inherited from a dead
predecessor was never adopted here and the predecessor may have reached Control
before it died; a request whose Control reply was lost is already past the send.
Both stay `dispatched_or_unknown`. Every other error, timeout, process death,
malformed answer, contradicted tag, and recovered open attempt is
`dispatched_or_unknown`: it ends that model operation without creating an
executor `outcome_unknown`, because a provider call is not a Loopex-controlled
effect that reconciliation can complete safely. A successful reply carries a
closed provider-neutral identity, normalized usage, tool calls, stream facts,
response identifier, and the exact staged digest; raw provider structures and
reasons cross no Core, Store, public, progress, diagnostic, or fixture plane.

A settlement is four closed enumerations and one result. `transport` is
`not_dispatched` or `dispatched_or_unknown`; `termination` is absent, `abort`,
`deadline`, or `owner_loss`; `conversation` is `canonical`, `evidence_only`, or
`none`; and `next` is `retry`, `continue`, or `terminal`. Their combinations are
validated rather than merely typed: a reply cannot be `not_dispatched`, a
`not_dispatched` attempt may charge nothing and enter no conversation, a
`dispatched_or_unknown` attempt may not charge nothing, `continue` requires a
canonical reply that actually asked for tools, and `retry` exists only for the
exact not-dispatched attempt that also carried no termination. Two more
combinations are refused by reading the attempt number and the reply together.
`retry` at the attempt limit is invalid history: admitting it would install
permission for an attempt three the attempt-open record then refuses, so the
owner would crash on history it had accepted. A reply carrying a termination is
admitted only as `evidence_only`, which is what the evidence plane is for — the
answer arrived, the ending was already chosen, and the reply is retained beside
the conversation rather than as it. A reply that carries a termination and
claims no conversation at all is a retained answer the run has no record of
having received, and is neither disposition the table admits.

`owner_loss` is the weakest of the three terminations and is claimed only where
neither an admitted abort nor an admitted deadline already won. A successor that
finds an attempt open on a run it did not adopt settles it that way: the staged
bytes are recovery identity, never redispatch authority, so no second call is
opened. The settlement is `dispatched_or_unknown`, no conversation, the whole
remaining allowance charged, and a `failed` run terminal whose reason is the
error category. A run's usage map is also closed to `input_tokens` and
`output_tokens`: an adapter that reports any other key produces
`unreadable_model_answer` rather than having an unrecognised number silently
ignored, while omitting either key stays legal and normalizes as unreported.
A reply Core cannot canonicalize settles under that same category. It keeps
reported accounting only where the raw usage subtree is an unambiguous exact
input/output pair and both values normalize as reported; every extra, missing,
colliding, or invalid shape charges the run's remaining allowance as unreported,
because the answer may still have been billed but Core cannot vouch for a
partial projection.

### Declared Bounds and the Split Deadline

`Loopex.Bounds.declare/1` refuses a missing or non-positive bound rather than
substituting one; the runtime supplies configured defaults of 16 turns, a
1_000_000-token budget, and a 600_000 ms deadline duration for a host that said
nothing, and refuses at start a host that explicitly said something malformed.
A command may name its own bounds, which are merged over the runtime's.

`decide/2` is a pure function of committed observations and the caller's clock
reading, checked in a fixed order whose order carries meaning:

```text
last assistant message has no tool calls  -> :completed
turn_number + 1 > max_turns               -> {:bound_reached, :max_turns, turn_number}
cumulative tokens >= token_budget         -> {:bound_reached, :token_budget, tokens}
now >= deadline                           -> {:bound_reached, :deadline, now}
otherwise                                 -> :continue
```

The no-tool check is first and unconditional, so a run whose model stopped on its
own is `completed` and stays `completed`. A non-integer `deadline` raises rather
than returning `:continue`, because Elixir orders numbers below atoms and
`now >= nil` would make an uncommitted deadline a silently unreachable bound.

Provider accounting settles atomically with the attempt result. The complete
raw usage subtree passes Store bounded-plain-data admission before projection. A
reply with a complete valid input/output pair charges those exact reported
values. Missing, partial, colliding, malformed, negative, non-integer,
unsigned-64-overflow, or extra-key usage is normalized as unreported; every
possibly dispatched attempt with unreported usage charges exactly the run's
remaining cumulative allowance. The private salvage path checks `map_size/1`
before fixed key fetches rather than traversing a hostile wide map. Exact
pretransport `not_dispatched` proof charges nothing. The settlement, accounting,
conversation disposition, retry/continue/terminal choice, and paired run
terminal where one is owed are one Store transaction, so commit-unknown replay
cannot apply cost without outcome or make retry authority reappear. Estimated
accounting that consumes the allowance is not itself a fabricated
`bound_reached`; the ordinary next pre-staging bound check remains the only
selector.

The deadline is declared as a *duration* (`deadline_ms`) and becomes an absolute
instant exactly once, when a run stages its first model request. A durable
command-admission record must be a deterministic function of its command,
because `commit_unknown` fencing re-presents it; a record rebuilt with a fresh
clock reading produces different bytes and the store correctly refuses to resolve
the transaction it is holding. Once fixed, the instant is read back from
committed history, so a recovering owner re-presents the deadline the run
actually had instead of being handed back the downtime it slept through.
`decide/2` therefore reads `:deadline`, the instant, while `declare/1` validates
`:deadline_ms`, the duration. ADR 0010 asks prompt admission to carry that
instant and ADR 0011 asks promotion to carry it; ADR 0013 replaces both timing
clauses with the first-staged-request boundary. The deviation and its bounded
consequence are recorded in
[M2 recorded limitations](../evidence/M2-recorded-limitations.md).

Reaching the deadline is not a promised clean stop. `settle_turn/2` commits
`bound_reached(:deadline)` only when the run has no committed effect intent
without a validated fact; otherwise the run ends `outcome_unknown` carrying its
reconciliation reference. A tool call whose intent would commit after the
deadline is not dispatched at all: it takes a terminal `cancelled` fact whose
cleanup is trivially confirmed, because nothing started. There is no minimum
remaining time, since inventing a threshold would refuse work the operator's
declared bound permits.

An elapsed deadline gets its own durable row before anything settles under it,
and an admission that did not commit settles nothing. A run whose attempt is not
open, or whose deadline was already admitted, has no row to propose and adds
nothing. A refusal is different: the settlement that follows reads the deadline
from applied state, so discarding a refused admission left `model_termination`
unset and the attempt selected a retry and a model-call failure for a run that
had reached `bound_reached(:deadline)`. A refusal that only says ownership moved
is the ordinary succession this coordinator already leaves, and the successor
rereads the deadline and admits it itself. Every other refusal makes the session
unavailable, with no settlement, accounting, conversation, or terminal invented
behind a commit that did not happen.

### Streaming and Stream Domains

A `stream_domain_id` names one *attempt*, never a turn. There are two kinds,
`:model` for a provider call and `:executor` for one tool operation attempt, and
a retry opens a new domain, so several domains under one turn are the ordinary
shape of a retried turn. The identifier is the lowercase hexadecimal of the first
sixteen bytes of the SHA-256 of the canonically encoded tuple
`{"loopex.stream_domain.v1", domain_kind, session_id, operation_id, attempt}`,
with `attempt` as the integer itself. It is 32 hexadecimal characters and opaque
by contract: a consumer compares it and never takes it apart.

The coordinator derives every domain from committed identity it already holds
and stamps it onto each item. An adapter supplies only content fields, and an
executor's event is stamped only after validation has proved it belongs to the
attempt that was dispatched — a domain an adapter could name is a domain an
adapter could misattribute. `Loopex.Model.valid_delta?/1` gates the progress
function: an item is forwarded and counted only when its `kind` is one of
`text_delta`, `reasoning_delta`, or `tool_call_delta`, it carries exactly the
fields that kind declares — no more, so nothing unbounded rides along, and no
fewer, so an item that says nothing is never sequenced and published — its
payload is plain data, and every field it carries totals at most 65536 bytes,
measured by encoding anything whose size the named clauses do not otherwise
know. Progress items reach a host as `{:loopex_progress, item}` messages to the
runtime's `:progress_to` pid; diagnostics arrive as `{:loopex_diagnostic, item}`.

While its coordinator remains authoritative, a domain is owed exactly one
content-free closing item — `model_stream_closed` or `tool_stream_closed` —
carrying a disposition and a count. A `:complete` domain closes with its
producer's retained figure — an adapter's `delta_count`, a receipt's
`progress_count` — and an `:abandoned` one with the count this coordinator
published. The two differ whenever an item was refused, and that difference is
the signal: a consumer comparing the stated total against what reached it learns
something did not arrive, and the refusal record that explains it is durable and
private.

`Loopex.Runtime.StreamRelay` is the sole emitter of a domain. It assigns every
sequence, emits every item, emits the closing item itself as the last thing it
does, and then ends — so a closure is the last item of a domain that receives
one, and an item handed to a closed domain reaches a process that no longer
exists. [ADR 0014](../adr/0014-stream-closure-at-owner-loss.md#concept) names the
owner-loss boundary: abrupt owner death and recognized executor owner loss
without a retained terminal fact end the relay without a closure; a successor
never reuses or closes that domain. A retained reply or receipt can still close
its originating domain `complete`, and delivered live-model supersession closes
`abandoned` only after the effect-free worker is terminated and drained.

Closure is an *emission* obligation while its owner can state it truthfully, not
a delivery guarantee. It rides the transient plane and may be coalesced away,
dropped, or lost with that plane. A consumer that receives no closure falls back
to the durable record exactly as it does for a sequence gap, and never reads an
absence as abandonment, because that inference needs a timeout and a timeout is
a guess.

Continuity, count agreement, and closure are evaluated strictly within one
domain; no comparison between two domains is defined.

Streaming is one extra argument on the same call, not a second code path. An
adapter or executor that emits nothing is conformant: it accepts the progress
function, returns the same result, and reports a count of zero.
`Loopex.Executor.Local` is currently such an implementation — it accepts the
progress function, never calls it, and reports `progress_count: 0`, so the
coordinator closes that operation's domain with a truthful count. The runtime
path that carries executor progress to a terminal before the tool finishes is
proved with a fixture executor that does emit.

### The Host Policy Port

One callback, `decide/1`, receives bounded plain data: session, run, and
tool-call identity, the resolved generation triple, validated arguments, effect
class, idempotency class, and the workspace lease reference. It carries no pid,
credential, or provider value.

`Loopex.Policy.decide/2` runs the callback in a supervised task with a fixed
5000 ms timeout, so a policy that blocks cannot block the session owner and one
that raises or exits produces a decision instead of a crash. Resolution is
exhaustive and every path that is not a well-formed allow ends in a denial:

| Observation | Resolution |
| --- | --- |
| `{:allow, context}` in the bounded shape or `nil` | grant issued |
| `{:allow, context}` outside the bounded shape | `{:deny, :policy_unavailable}` |
| `{:deny, category}` | durable denial, no dispatch |
| `{:defer, _}` | `{:deny, :interaction_unsupported}` |
| callback raises, exits, or times out | `{:deny, :policy_unavailable}` |
| any other return shape | `{:deny, :policy_unavailable}` |

`defer` is declared and refused in M2: the interactive round trip it implies
needs a durable interaction record, exact-response matching, expiry, and
resume-after-restart evidence, none of which this milestone builds. Declaring it
now means the shape a host returns will not change when that milestone arrives.

A decision context is bounded in every direction: an opaque `decision_ref` of at
most 256 bytes that Loopex never parses, at most sixteen attributes with binary,
integer, or boolean values, and at most 1024 canonically encoded attribute
bytes. The refusal categories are `policy_denied`,
`effect_class_not_permitted`, `workspace_not_permitted`,
`interaction_unsupported`, and `policy_unavailable`.

On an allow the coordinator mints one grant with
`Loopex.Executor.issue_grant/4`, expiring 60000 ms out, binding `operation_id`,
`attempt`, `canonical_request_digest`, `tool_id`, `tool_version`,
`effect_class`, `workspace_lease`, `executor_audience`, `expiry`, and
`fencing_token`. The executor revalidates job, grant, lease, audience, expiry,
epoch, identity, and fence at its own final serialized pre-start boundary.
A coordinator that somehow reaches dispatch with no configured policy denies
with `:policy_unavailable`.

Cancellation of a running job uses the required `Loopex.Executor.cancel/2`
callback, which stops one named job and reports `{:ok, :cleaned}`,
`{:ok, :unconfirmed}`, or `{:error, term()}`. Only the first answer confirms
cleanup. Production invokes it through configured `cancel/4`; one checked
formula derives the observation window from the session's committed cleanup
period. The facade maps every other answer, raise, exit, timeout, malformed
answer, and the defensive case of a legacy module missing the required callback
to unconfirmed cleanup. Retained `cancel/3` keeps its fixed defensive bound for
direct compatibility callers and is never selected by production coordination.

### Tool Output, Spill, and Artifacts

`Loopex.ArtifactStore` is both the Core-owned caller facade and the adapter
behaviour. Callers use `put/3`, `fetch/2`, `stat/2`, `describe/2`, and
locator-only `retrieve/2`; after Core normalization an adapter implements
`put/3`, `fetch/2`, `stat/2`, and `describe/2`. The `handle` is edge-private
placement state that is never journaled, published, or transported.

The compact `artifact_reference` has exactly eight members. Object identity is
`digest`, `size`, and opaque `locator`; public interpretation is `media_type`
and `role`; immutable use identity is `use_canonicalization_version`,
`use_digest`, and the digest-derived `use_locator`. Exact session, run,
operation, positive attempt, and tool-call provenance is retained only in the
private use record and never crosses the public boundary. `roles/0` is the
closed list `["tool_output"]`.
`truncation_notice/3` is the bounded model-facing form that names how much was
kept, how much there was, and the artifact that holds the rest, because a bound
that silently discards the remainder is data loss dressed as a bound.

`Loopex.Store.Local.Artifacts` implements the port over a resolved root. Object
paths are derived from the content's own SHA-256 with a two-hex-character
fan-out directory. It durably publishes the immutable object first, then the
canonicalization-versioned immutable use sidecar. Concurrent identical
publications converge; an existing different object or use fails unavailable;
and success is returned only after both are durable. A failed use publication
may leave an unreachable object orphan, never a reference whose required use is
missing. `stat/2` returns only the object triple, `fetch/2` accepts that object
truth and verifies exact bytes, and `describe/2` resolves the use locator. The
declared object ceiling is 64 MiB, the exact canonical use ceiling is 131,072
bytes, and nothing is collected automatically in M2.

Core computes digest and size from the exact input, validates every adapter
answer, reconstructs and checks the complete use, and immediately resolves the
returned use locator before success. A substituted locator, digest, size, use,
version, role, or media type; missing or corrupt sidecar; unknown object; or
malformed legacy five-member reference fails closed. Public `retrieve/2` accepts
only the opaque object locator, calls validated `stat` then `fetch`, and neither
reconstructs nor accepts private provenance.

`Loopex.Executor.Local` bounds its own output through `CodingTools.bound_output/2`,
collects at most the tool's declared 8 MiB artifact ceiling and drops the rest,
and hands what it collected to the Core facade its host composed, with the exact
validated session, run, operation, attempt, and tool-call identities. A
truncated result carries `ArtifactStore.truncation_notice/3` naming the compact
reference, and the receipt carries that reference in `artifacts`. The reference
reaches the public plane on `tool.finished`; the terminal prints it; and
`loopex artifact <reference>` extracts its object locator and reads exact bytes
back through the same Core facade.

Two paths do not spill, and both keep the marker instead. A host that composed no
artifact store — the executor's `:artifacts` option is optional — and a store
that refuses the write both fall back to `truncation_marker/2`, which names no
reference. **In both cases the bytes beyond the bound are gone**, not merely
unretrievable: nothing else holds them. The receipt then records an empty
artifact list, which is true rather than a silent absence. The shipped
composition always supplies a store, so an operator using `loopex` does not take
that path.

`CodingTools.present/1` remains conformance-only: nothing in the production path
calls it.

### The Four Bootstrap Coding Tools

`Loopex.Executor.Local.CodingTools.definitions/0` ships four reference-distribution
declarations in the reserved namespace:

| `tool_id` | Effect class | Idempotency | Output ceiling |
| --- | --- | --- | --- |
| `loopex.read` | `read_only` | `safe_retry` | 65536 bytes |
| `loopex.write` | `workspace_write` | `safe_retry` | 4096 bytes |
| `loopex.edit` | `workspace_write` | `never_blind_retry` | 4096 bytes |
| `loopex.bash` | `process` | `never_blind_retry` | 65536 bytes |

Containment is checked against the *resolved* path, not the requested one.
`resolve/2` resolves the workspace root, expands the requested path against it,
resolves the deepest ancestor that exists on disk while following symlinks, and
then compares against the resolved root with a trailing separator, so a relative
escape, an absolute path, a symlink pointing elsewhere, and a sibling directory
whose name shares a prefix all fail the same single comparison. A path that does
not exist yet resolves its existing parent instead, which is what lets `write`
create a file while still being confined.

`read` returns bounded content and reports truncation. `write` creates or
replaces a file beneath the root, creating intermediate directories. `edit`
replaces one exact occurrence and, on a mismatch, distinguishes absent from
ambiguous and reports the nearest line it did find. `bash` takes either an argv
vector, passed through without a shell, or an explicit raw `command`, which asks
for a shell and gets one; collapsing the two would surprise a caller who supplied
arguments safely. A job dispatched past its effective deadline is refused before it begins rather
than interrupted while running: the three filesystem tools do not use deadline
expiry as a mid-call verdict, so `run_coding_tool/5` compares the instant against
the clock and returns `the effective deadline passed before this tool began`. No
process is terminated because none was started. `bash` is the tool whose deadline
governs a running child, and its expiry enters the termination and
cleanup-confirmation sequence. Independently, loss of the Local instance that
admitted a filesystem effect terminates its owner-aware worker and reports the
effect unproven.

The three filesystem tools start no operating-system process.
A child runs in a process group of its own, established by the spawn itself
rather than by any helper program, announces the group the operating system
actually assigned before doing anything else, and is terminated by group rather
than by leader. No launcher in the executor's chain may fork or replace that
identity: the Port, command, and descendants that remain in the inherited group
keep one owned group from spawn through receipt, so exit status, termination,
and cleanup confirmation all describe the same work. A descendant that calls
`setsid` or `setpgid` can deliberately leave that boundary, as ADR 0009 records.
The effective deadline of a job is the earlier of the run's deadline and the
tool's own wall-time budget.

### Context and Durable-Record Admission

Context policy and Store capacity are independent. Runtime requires one positive
unsigned-64-bit `:context_token_budget` at the top level; it is not a fourth run
bound and can never produce `bound_reached`. The reference composition and
command resolve omission to `8_192`, while direct Runtime omission and every
explicit invalid value fail before Runtime Control, session state, or Store.
Recovery and promoted follow-up work reuse the committed value. Prepared
`resume` and `cancel` compare an explicit value only after cleanup configuration
matches, abandon before activation or abort on conflict, and treat a settled
session's nil active value as no comparison rather than as the reference
default.

`loopex.context_bytes.v1` measures the exact final provider-visible messages and
active model-facing tool projections. Store separately normalizes and measures
each private record and unstamped public-event payload against its exact 65,536-
byte item ceiling before that value can commit or authorize later work. The
reference fixture makes the distinction concrete: system plus four projected
tools is 2,393 canonical bytes and 799 estimated tokens; the system message
plus the four full canonical definitions occupy 4,382 component bytes and
measure 1,462 estimator tokens when each component is measured separately;
a 65,536-byte project file wraps to a 65,653-byte provider message and 21,885
estimated tokens. None of those estimates claims provider capacity, billing, or
tokenizer equality.

Admission is checked in a fixed order and the first failure decides:
`system_class_tokens` against a strict ceiling of 1,000 — a host-owned class
measuring exactly 1,000 refuses — then `context_tokens` against the committed
budget, then the candidate record's `context_record_depth` (12) and
`context_record_cardinality` (1,024), then `context_record_bytes` against the
65,536-byte item ceiling. Those five names are the closed dimension set, and a
refusal is exactly `dimension`, `observed`, `limit`, and `record_byte_cost`,
which is the observation itself for the byte dimension and `nil` for the other
four. The system-class ceiling is why adding a tool is a context decision:
the system message plus every active model-facing projection is charged against
it before any budget the operator named is consulted.

Optional project content that alone exceeds context is withheld whole with a
compact declined receipt — the whole class is removed and the request
re-canonicalized, never trimmed. Required system, history, steer, or tool
context overflow commits `context_admission_refused_v1` and the run's `failed`
terminal in one transaction, opens no model attempt, and publishes exactly five
members: `category`, `retryable: false`, `dimension`, `observed`, and `limit`.

Every retained refusal is decided on and built from a required-only candidate.
The compact record's four counts — system, session, steer, tool — have no member
for an optional project descriptor, so a dimension no withholding can cure (the
strict system-class ceiling, record depth, record cardinality) is re-decided over
the required-only set before anything is retained. That is what makes the counts
partition the exact descriptor sequence behind `ordered_descriptor_digest` and
makes `not_evaluated_required_failure` the truth about a project whose budget
contribution was never reached. A required-only candidate admitted at that point
is discarded rather than staged, because its receipt still claims the project
resolution that produced the optional block it no longer contains. Optional
content cannot be the sole cause of a structural refusal in M2, so reaching that
state means the invariant is broken and the session is unavailable rather than
an operator verdict being invented; a required-only candidate whose own counts
and sequence disagree is the same kind of broken invariant. The staged source
list names the blocks the request actually carries rather than the ones its
receipt's resolution would imply. The residual gap here is recorded at
[M2 recorded limitations](../evidence/M2-recorded-limitations.md#adr-0017-step-five).

The candidate record's own byte cost is a fixed point, and one that does not
converge is Store-unavailable rather than a measurement. Continuing without it
would stage a request whose receipt states a byte cost of zero, so the session
becomes unavailable and no dimension, terminal, or dispatch is manufactured from
it. A record that breaches Store depth or cardinality has no convergent
self-size at all: it is handed to the admission boundary unresolved, which is
where it is refused by its exact structural dimension.
The descriptors and source references that caused the refusal reach no public
plane. Every content-bearing prompt, steer, and follow-up also preflights its
exact accepted record and reachable event/terminal shapes. Replay is consulted
before current defaults and current run state, so a retried command reproduces
the durable answer instead of being reinterpreted under a later process
configuration.

Every descriptor carries provenance rather than position. Each one names a
structured `source_reference` — a system identity, a tool generation triple, a
project-resource workspace/manifest/label triple, or a steer's run and command
— alongside a `provenance_class` of `system`, `session`, or `project_resource`
and the trust class that class fixes:
`host_owned_trusted_brain_content`, `session_owned_durable_truth`, and
`untrusted_behavior_shaping_data` respectively. The receipt's totals carry all
three provenance buckets, zero-filled, summing to the outer total, so what an
operator was charged for is attributable by origin and not only in aggregate.

### Project Resources

Discovery is shallow and content-independent: the reference stage names exactly
one resource, `AGENTS.md` at the root of the canonical workspace. There is no
recursion, globbing, home-directory resource, or configured path list, and an
import or link inside an admitted resource is inert text.

Core never resolves, holds, or opens a filesystem path. The host or hand locates
and resolves the resource, enforces containment, and supplies a manifest; core
verifies each entry's content against its declared digest and size, refuses any
entry not reported `contained`, enforces the ceilings of 64 KiB per resource and
64 KiB per class, orders entries by label, and digests the manifest — including
`workspace_ref`, `repository_origin`, and `revision` — into the value one trust
decision binds. Nothing is ever truncated into context.

Resolution is exhaustive, and every request's receipt names exactly one
disposition from a closed set of nine. `staged` is the admitted one; the eight
that stage the class empty are `no_manifest`, `manifest_rejected`,
`over_limit` with its dimension and observed size, `no_decision`,
`binding_changed`, `staged_empty` for a matching manifest that truthfully
resolved no entries, `context_token_budget` and `context_record_bytes` for a
trusted block withheld whole by a dimension it alone exceeded, and
`not_evaluated_required_failure` where required context had already failed and
the optional class was never reached. Each carries its own bounded detail:
`manifest_rejected` names label and reason, `binding_changed` names the two
digests that disagreed, `no_decision` names the manifest digest a decision would
have had to bind, and the two budget dispositions name dimension, observation,
and limit. `manifest_rejected` reasons are themselves closed —
`invalid_manifest`, `too_many_entries`, `invalid_workspace`,
`entry_not_bounded_plain_data`, `unpermitted_label`,
`entry_not_reported_contained`, `declared_size_mismatch`, and
`declared_digest_mismatch` — as are `binding_changed`'s `invalid_decision`,
`digest_mismatch`, and `workspace_mismatch`. A changed workspace identity,
revision, resolved set, or content digest produces a different manifest digest,
so a decision bound to the old one admits nothing; there is no partial match and
no staleness window.
Blocks are resolved per turn from the same manifest and decision, so an edited
resource stops being admitted at the next turn rather than at the next run.

Failing closed here withholds *content*, never the runtime: a headless run with
no matching decision stages the class empty, journals the declined receipt, and
goes on to do the coding task, because refusing to start would make an absent
decision look like a broken installation. An admitted block is typed input
structure inside `<project_resource label="...">` delimiters and changes no tool
set, policy decision, bound, or grant.

### Commit Ordering for One Turn

The coordinator is the sole serial writer. Its pending-work stages are committed
facts, so a successor resumes from the journal rather than from anyone's memory:

1. `model_pending` — project the conversation from committed elements, append any
   admitted project blocks and at most one pending steer, measure the exact final
   provider context and exact normalized Store records independently, and refuse
   either dimension before dispatch when it exceeds its committed ceiling. A
   successful first staging commits the exact request bytes, digest, applied
   steer, context receipt, and `model_attempt_opened_v1` for attempt one in one
   ordered transaction before any adapter sees them.
2. `model_attempt_open` — start a worker that cannot call the adapter until
   Runtime Control validates the current owner, attempt, journal position,
   worker, fresh reference, and deadline, takes a final pre-send clock sample,
   and sends that worker its one-use permit. The worker checks the same deadline
   again immediately after receipt and before adapter entry. The send opens
   exactly one attempt-scoped model stream domain and is the provider-dispatch
   linearization point even where late receipt prevents the provider call.
3. On reply or failure — validate the provider-neutral result and atomically
   commit `model_attempt_settled_v1` with its accounting, conversation
   disposition, and retry/continue/terminal choice. A valid canonical reply
   closes from its own `delta_count` and commits the assistant message and
   event. Exact pretransport `not_dispatched` on attempt one charges nothing and
   permits one separately committed attempt-two open. Every ambiguous, timed
   out, malformed, dead, or recovered-open attempt charges the exact remaining
   allowance, enters no conversation, and ends the model operation without
   redispatch. Late abort/deadline replies are evidence-only; a successor never
   fabricates the dead predecessor's stream closure.
4. `effect_pending` — take the head of the turn's remaining calls, in the
   assistant's own order; refuse dispatch past the run deadline; otherwise
   resolve the model's tool name against the session's active set, build the
   job, consult the policy, mint the grant, and commit effect intent *before*
   dispatch. That record emits `tool.started`. A denial, an unresolvable name,
   or a passed deadline commits a terminal `tool_result_committed` record
   instead, which emits `tool.finished`, and the loop continues.
5. `effect_dispatched` — the Local executor first reserves or joins the job
   without granting effect authority, then answers one serialized permit request
   only after revalidating the exact live reservation holder, complete shared
   root, job, grant, lease, audience, expiry, epoch, identity, and fence. New
   work publishes admission and the operation-owner token under the same claim,
   runs under that exact Local authority, and retains its receipt. This state is
   never restarted by recovery; an intent without a fact is reconciled.
6. On receipt — one `executor_receipt_committed` record matches the receipt
   against the dispatched job, appends the `tool_result` element, and emits
   `tool.finished`. The turn returns to `effect_pending` while calls remain and
   reaches `turn_settled` when the last one is answered.
7. `turn_settled` — ask `Loopex.Bounds.decide/2`, and either stage the next
   request or commit the run's terminal record and one `run.finished` event.

Public events are projections of committed facts, and delivery is fenced by
resolution as well as by commit. An attached reader is handed outbox rows only
up to the position Runtime Control has recorded as resolved, so a row that is
durably linearized while its owner still holds an unresolved transaction
publishes nothing until re-presentation settles it. An attaching reader's own
snapshot scan is bounded by the same watermark, because it reaches the outbox by
a second path: an unfenced scan would anchor on the durable tail, answer with
truth every already-attached consumer is withheld from, and set `seen` past rows
the event plane then never delivers. The watermark is pushed to
the dispatcher rather than pulled from it, is applied to the read rather than to
the queue, and is dropped when this runtime stops owning the session — a
dormant session's history therefore reads and scans without a fence. Progress items and
diagnostics are transient, are not fenced, and are never durable truth.

### Verification Entry Points

- `mix test --exclude real_provider` — complete credential-free suite.
- `mix loopex.deps_budget` — eight-application inventory, roles including
  `:composition`, dependency budget, and direction.
- `mix loopex.core_only` — core has no adapter resolution or environment-held
  runtime state.
- `mix loopex.docs_check` — compiled public documentation orders Concept before
  Technical depth.
- `mix loopex.status` — governance rows, indexes, links, and bound artifacts.
- `bash scripts/check-m2-gate.sh` — locked milestone gate. Real-provider
  roles receive their credential through the gate's bounded stdin protocol; do
  not export it to the gate's initial environment or put it in argv.

The exact selectors, minima, and evidence grammar are locked in
[the M2 gate](../plans/M2-gate.md). Retained evidence is indexed in
[docs/evidence](../evidence/README.md).
