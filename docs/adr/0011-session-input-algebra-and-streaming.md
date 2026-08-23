# 0011. Session input algebra and streaming progress

<a id="concept"></a>
## Concept

Technical depth: [Command, queue, and delta mechanics](0011-session-input-algebra-and-streaming-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-23
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` acceptance

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0011-context"></a>
## Context

`M1` admits two session commands: `prompt` and `abort`. A prompt submitted while
a run is active is durably rejected as `run_active`. That is correct for a loop
that runs exactly two turns and finishes in seconds. It stops being correct the
moment a run edits files and runs a test suite for several minutes, because the
only thing an operator can do while it works is stop it.

The vision does not leave this open. §10.2 makes "pending steering is applied
before the next model request" step 11 of one run and "if follow-up work is
queued, the next run starts" step 13. §10.3 names four input paths and states
plainly that Loopex never guesses whether new input is steering or a follow-up.
§18.4 lists steering and queued follow-up among the minimum flows of a reference
CLI. None of those words appears in the `M2` plan or in
[ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) or
[ADR 0010](0010-provider-continuation-and-context-staging.md#concept), not even
as a non-goal. An omitted core loop semantic is not the same as a deferred one:
the first gets decided by whoever writes the coordinator, the second gets
decided here.

The second half of this decision has the same shape. `Loopex.Model` exposes one
callback, `complete/2`, returning a whole reply. A coding harness that runs for
minutes and prints nothing until it finishes is not a usable product, and §13.1
already names streamed call deltas and complete streamed messages among the
canonical types Loopex owns. §11.2 puts those deltas on the transient progress
plane, where they may be dropped and need not replay, while the complete
assistant message is durable truth a reconnecting client is owed. Adding
streaming without deciding that boundary first is how progress becomes truth by
accident. The same gap runs through the other end of a turn: §11.5 names tool
output deltas as progress and §15.1 requires every executor event to echo the
complete identity and fence, while the executor port returns exactly one receipt
and offers no channel for anything in between. A delta kind whose producer no
decision names is an obligation on whoever implements first.

These two belong in one decision because they are the same question asked at two
ends of a turn: what may enter a running run, and what may leave it. Both are
answered by the coordinator, both are ordered against the same committed
journal, and both are the shape the headless session-protocol milestone will
build a wire protocol on top of. Its transport contract already lists the same
command families and the same asynchronous events and progress; whatever `M2`
leaves here is what that protocol will have to serialize.

Technical depth: [What M1 admits, what the loop needs, and what the port lacks](0011-session-input-algebra-and-streaming-technical.md#technical-adr-0011-context).

<a id="concept-adr-0011-decision"></a>
## Decision

### The input algebra

- **`M2` admits exactly four session inputs: `prompt`, `steer`, `follow_up`, and
  `abort`.** Each is an explicit command type carrying its own `command_id`, and
  Loopex never infers which one a client meant from the state of the session.
  `respond_interaction` is not admitted, because ADR 0009 denies `defer` and an
  interaction can therefore never exist. Nothing else — no configuration change,
  no model change, no compaction — is an input this milestone accepts.
- **Every input is an ordinary durable session command.** Each is admitted or
  rejected by the one serial session owner, idempotent on `(session_id,
  command_id)`, fenced by owner epoch and journal version under
  [ADR 0006](0006-store-transaction-and-owner-epoch.md#concept), and answered
  with exactly one correlated admission response. Re-presenting a `command_id`
  returns the original durable result and never queues a second copy of the
  work.
- **`prompt` keeps `M1`'s refusal.** It starts a run only while the session is
  settled; while a run is active it is durably rejected as `run_active`, exactly
  as today. The refusal is what forces the client to say which of the other two
  it meant.
- **`steer` belongs to one named active run.** It is admitted only while that
  run is active and must name it. A steer naming a different run, or naming none
  while a run is active, is rejected rather than retargeted, so a steer typed
  for a run that has already finished can never land silently in the next one.
- **Steering has exactly one application point, and it is inside the transaction
  that stages the next request.** An admitted steer is applied after every tool
  result of the current assistant message has committed, and after
  [ADR 0010](0010-provider-continuation-and-context-staging.md#concept)'s
  termination and bound checks have decided that another request will actually
  be staged. That is §10.2 step 11 and nowhere else. The applied steer element
  and the staged request that carries it commit in one transaction, so ADR
  0010's projection stays a deterministic function of committed elements and a
  replay shows exactly what the model saw and when.
- **A steer is never recorded applied unless a request carried it.** Eligibility
  and bounds are checked before anything commits applied. If the maximum turn
  count, the token budget, or the wall-clock deadline ends the run at that
  point, or if staging itself fails closed, the steer commits `unapplied` with
  that exact reason instead. There is no window in which an operator is told
  their steer landed while no model call ever carried it, because the element
  and the request that carries it are the same commit.
- **Queues are one-at-a-time, and a full queue refuses rather than coalesces.**
  At most one `queued` steer exists per run and at most one follow-up is queued
  per session. A second is rejected with an explicit reason. Deliver-all
  batching is the vision's later session option and needs an ordering proof this
  milestone does not have; dropping or merging an accepted input instead would
  make the refusal silent.
- **A steer that no request carried is recorded, never discarded and never
  promoted.** If the run reaches a terminal outcome without staging a request
  that carries the steer — because the run ended before the application point,
  because a bound was exhausted at it, or because staging failed closed — the
  steer commits as unapplied with that exact reason, emits a public event saying
  so, and never enters the conversation projection. Loopex
  does not convert it into a follow-up, because that would be the guess §10.3
  forbids; the operator resubmits it as a follow-up under a new `command_id` if
  that is what they want.
- **`follow_up` queues one run and is refused when there is nothing to follow.**
  It is admitted while a run is active and starts a new run once that run
  reaches a terminal outcome. Submitted while the session is settled it is
  rejected as `no_active_run`, because a run that starts immediately is a
  prompt, and the two commands stay distinguishable rather than convenient.
- **The run-terminal transition is atomic and recoverable.** When a run reaches
  its terminal outcome the owner commits, in one transaction, the terminal
  outcome, the `run.finished` fact, and either the promotion of the queued
  follow-up to a new run identity or `session.settled`. A coordinator lost
  between promotion and staging recovers a promoted-but-unstaged run and stages
  it; the follow-up is neither lost nor started twice, because promotion is a
  durable idempotent transition of a committed command.
- **An abort cancels the queues as well as the run.** A durably admitted abort
  resolves any `queued` steer and any queued follow-up as cancelled, each
  recorded truthfully against its own `command_id`. Work an operator queued
  before stopping the task never starts after it. This is a real capability
  cost, taken because the alternative — a new run beginning moments after the
  operator stopped the last one — is the worse surprise.
- **Durable truth is the commands, the queue transitions, and the applied
  elements.** Admitted commands, applied steer elements, queue state
  (`queued`, `promoted`, `applied`, `unapplied`, `cancelled`), and terminal
  outcomes are durable and survive restart. A client's typed buffer, its pending
  indicator, and every streamed delta are not.
- **The kernel proves all four inputs, and the terminal surface exposes all
  four.** `M2` must prove admission, ordering, fencing, idempotency, the single
  application point, the unapplied-steer record, the promotion transition,
  restart recovery of a queued follow-up, and abort's cancellation of both
  queues, through the embedded facade. The reference command exposes `prompt`,
  `steer`, `follow_up`, and `abort`. None of the last three needs a transport:
  the run streams in the operator's own foreground process, so that process
  already owns the terminal a steering line arrives on and admits it through the
  same public facade. Withholding the surface would leave an operator watching a
  run they cannot redirect while the kernel underneath already accepts the
  redirection, which is the promise this milestone exists to keep. Because the
  runtime never guesses which of the two an input is, the surface must not guess
  either: `steer` and `follow_up` get distinct explicit affordances, and input
  that names neither is refused rather than resolved from the state of the
  session.

### Streaming progress

- **The Model port has exactly one completion callback, and it takes a progress
  function.** `complete/2` becomes `complete/3`, receiving the canonical
  request, options, and a bounded progress function, and returning the same
  complete reply it returns today. There is no second streaming callback and no
  second code path in core, so the streaming path is the tested path.
- **The returned reply is the only source of durable truth.** The assistant
  message ADR 0010 commits is built from the adapter's return value, never
  assembled from deltas. A delta is never journaled, never published as a
  durable event, and never replayed on reconnect; a reconnecting client is owed
  the complete message, as §11.2 requires. This is structural rather than a
  rule to remember: core has nothing to assemble from.
- **A reply's stream statistics are attempt evidence, not message content.** How
  many deltas an attempt emitted, and whether the adapter streamed at all,
  describe one model attempt and are retained on that private attempt record.
  They are not fields of the committed assistant message, which carries
  conversation content and nothing else: whether the same bytes arrived in one
  piece or four hundred is not part of what was said, and a canonical durable
  element must not carry transport-shaped metadata a replay would have to
  explain.
- **Four canonical delta kinds, all bounded plain data.** Text, reasoning,
  tool-call, and tool-progress deltas each have an exact shape carrying no
  provider struct, pid, function, module atom, exception, terminal escape, or
  credential. Tool-progress deltas are projections of executor progress rather
  than model output, and ride the same plane and envelope.
- **Progress has two sequence domains, not one.** A model-stream sequence is
  owned by one model reply and orders that reply's text, reasoning, and
  tool-call deltas; an executor-operation progress sequence is owned per
  executor operation attempt and orders that operation's output. They are not
  merged, because they cannot be: the model reply supplies its own delta total
  when it returns, which is before the first tool of that turn has even been
  dispatched, so no single per-turn counter can be gapless across both without
  one side reserving numbers it may never use.
- **Each domain proves its own loss, in its own terms, and each closes itself on
  the progress plane.** Model deltas carry a sequence that starts at zero for an
  attempt and increases by one per emitted delta across all three model kinds.
  Executor progress carries a sequence that starts at zero for an operation
  attempt and increases by one per emitted progress event, plus a contiguous
  per-stream byte offset. Each domain then ends with one closing progress item
  stating its total, projected from the reply and the receipt respectively, so
  both an interior gap and a truncated tail are detectable in both without any
  total appearing on a durable element. Every delta also carries the turn it
  belongs to and the public event sequence it is anchored to; beyond those
  anchors no order is promised between the two domains. Coalescing and dropping
  under backpressure stay permitted in both, closures included; the sequences
  are what make them visible instead of silent.
- **Executor progress is emitted as a complete executor event and validated
  before anything narrower is projected.** The dispatching coordinator passes a
  bounded progress function with the job, and the executor uses it to emit
  ordinary executor progress events that echo the complete identity and fence —
  job, operation and attempt, session/run/turn/tool-call identity, origin
  session and executor epochs, executor identity, the canonical request digest,
  and the fencing token. The coordinator validates every one of those against
  what it independently holds for the live attempt before it projects the narrow
  client-facing delta, which carries none of that administrative material.
  Progress that fails validation is dropped and counted as refused; it is never
  projected, never journaled, and never a reason to change a durable outcome.
  This is the fencing discipline ADR 0007 and
  [ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept)
  apply to receipts, and progress from a superseded executor must be refusable
  for the same reason a receipt from one is. Its consequence is one step weaker
  only because progress carries no authority and commits nothing.
- **The emission path is decided here, so it is not an obligation nobody owns.**
  The Executor port takes the same bounded progress function the Model port
  takes, in the same trailing position: `execute/4` becomes `execute/5`. That
  one parameter is the whole executor-boundary change. The grant bindings, the
  job request, the receipt, the deduplication rule, and the terminal algebra
  [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) and
  [ADR 0007](0007-local-executor-grant-job-receipt.md#concept) define are
  untouched, and an executor that emits nothing is conformant exactly as a model
  adapter that streams nothing is. The alternative was to keep a tool-progress
  delta kind whose producer no decision described, which is how an obligation
  becomes whatever the first implementation does.
- **Reconstruction is a conformance obligation, not a runtime dependency.**
  Replaying an adapter's emitted deltas in order must reproduce byte-identical
  content to the reply it returned. The suite asserts it. Core never performs
  that reconstruction in production, so an adapter that violates it produces a
  failing test rather than a corrupted conversation.
- **An adapter that cannot stream is conformant.** It emits no deltas, returns
  the same complete reply, and declares that it does not stream so a client can
  render accordingly. The deterministic test adapter satisfies the suite by
  emitting a scripted delta sequence with fixed boundaries, so ordering,
  reconstruction, and loss cases are exact and provider-independent.
- **A cancelled stream commits no partial assistant message.** Cancellation
  mid-stream stops deltas and commits no `assistant_message` element at all. The
  run is `cancelled`; the model operation is `cancelled` when cancellation
  caused its termination, with the observed partial progress retained as attempt
  evidence. A late complete reply for an aborted attempt is retained truthfully
  and never becomes a canonical assistant message. Unknown usage for such an
  attempt is accounted conservatively under ADR 0010 rather than ignored.
- **A model call is never `outcome_unknown` for lack of effect evidence.**
  Unlike an executor effect, an aborted model call leaves nothing in the world
  to reconcile; what may be unknown is its usage, which is recorded as unknown
  and accounted, not its occurrence.
- **Streaming does not weaken the committed-bytes property.** The canonical
  request is canonicalized, committed, and digested before the adapter is
  called, and `complete/3` receives exactly those bytes. ADR 0010's
  real-provider byte-equality assertion applies unchanged to the streaming
  path, a retry
  reuses the same staged digest, and no delta is ever an input to the next
  request.

This decision changes no rule in
[ADR 0006](0006-store-transaction-and-owner-epoch.md#concept),
ADR 0007, or ADR 0008. Every new command and queue transition is ordinary
session-domain content written by the one serial session owner under the same
fencing, and the progress plane is the transient sink `M1` already carries on an
attachment. Its one addition at the executor boundary is the progress function
and the events it carries, which are validated against those ADRs' identity and
fence rather than exempted from them.

Technical depth: [Exact command, queue, transition, and delta contract](0011-session-input-algebra-and-streaming-technical.md#technical-adr-0011-decision).

<a id="concept-adr-0011-alternatives"></a>
## Alternatives

**Ship `prompt` and `abort` only and call steering a later feature.** It is the
smallest possible `M2` and it matches what the plan currently describes. It is
not recommended: an operator watching a run go the wrong way can only stop it
and start over, which discards a partially correct run and its context, and the
loop semantics that make steering possible — one application point, ordered
against committed tool results — are cheapest to establish while the turn
machine is being rebuilt anyway. Leaving them out also hands the design to the
protocol milestone, which would then be inventing loop semantics inside a
transport.

**Infer from session state whether new input is a steer or a follow-up.** It
removes a decision from the operator and it is what a chat interface does. It is
rejected rather than weighed: §10.3 forbids the guess, and the failure mode is
silent in both directions. A follow-up treated as a steer contaminates a run
that was going fine; a steer treated as a follow-up lets a run the operator
tried to redirect finish wrong and then spends another run.

**Unbounded queues with deliver-all semantics.** More forgiving to a fast typist
and closer to what a mature product wants. It is not recommended now: the
vision makes queue mode one-at-a-time initially and requires an ordering proof
and an explicit session option before batching, and every extra queued item
multiplies the ordering cases against tool results, cancellation, and recovery.

**Apply a steer immediately, interrupting the in-flight tool batch.** It feels
more responsive. It is not recommended: it either abandons an effect already
started — which §10.3 says steering explicitly does not pretend to do — or
creates a second application point whose ordering against committed tool results
is ambiguous. One application point is what makes the projection deterministic.

**Discard an unapplied steer silently.** Simplest, and the race is rare. It is
rejected: the operator would believe they redirected a run that never saw a word
of it, and there would be no durable record to contradict them.

**Commit the steer applied first, then evaluate bounds.** It reads well — the
steer is part of the conversation the moment the tool results are in, and a
replay shows the operator's last word even when a limit ended the run. It is
rejected: `applied` would then mean "committed into the projection", not
"carried to the model", and a run that exhausts its turn budget at exactly that
point would report a steer applied that no model call ever saw. An operator
cannot act on a distinction that fine, so the record must mean the stronger
thing. The steer is still retained and still visible, as `unapplied` with the
bound that stopped it.

**Prove all four inputs in the kernel and expose only `prompt` and `abort` from
the reference command.** It is a smaller command surface and the kernel semantic
would still be proved. It is rejected: `M2`'s purpose is an operator redirecting
a run from their own terminal, and a foreground run already streams in the
operator's process, which therefore already owns the terminal a steering line
arrives on. There is no transport to build and no daemon to wait for, so the
only thing withholding buys is a milestone that proves a capability nobody can
use, described in documentation as unreachable.

**Keep one sequence domain across model deltas and executor progress.** One
counter per turn is simpler to explain and gives a consumer a single ordering.
It is rejected as unimplementable rather than merely awkward: the model reply
states its delta total when it returns, which is before the turn's first tool is
dispatched, so a shared counter would have to either reserve a range the
executor may never fill — making gaplessness meaningless — or renumber executor
progress against a total that is already published. Two domains with two
independent gaplessness properties cost one extra field and are provable.

**Leave executor progress out of `M2` and drop the tool-progress delta kind.**
Honest, smaller, and it avoids touching the executor port at all. It is not
recommended: a coding harness whose longest waits are a test suite and a build
would stream the model's prose and go silent for exactly the minutes the
operator most wants to watch, and the delta kind would return in the next
milestone anyway with a protocol already frozen around its absence. The cost of
including it is one parameter on one callback.

**Project executor progress into a client delta without validating the full
tuple.** Progress commits nothing, so a stale chunk looks harmless. It is
rejected: a superseded executor's output rendered as the current operation's is
a lie told to the operator at exactly the moment they are deciding whether to
abort, and the identity, epochs, digest, and fence needed to refuse it are
already on every executor event. Validating them costs a comparison against
state the coordinator already holds.

**Carry the executor identity, epochs, digest, and fence through to the client
delta.** It would let a client check the same things the coordinator checked. It
is not recommended: leases, epochs, receipts, and fences are private or
administrative in the public vocabulary, a client that re-derives trust from
them starts depending on internals, and the check belongs where the independent
state to compare against lives.

**Put the delta count and the streamed flag on the committed assistant
message.** They are cheap fields and it makes one record self-describing. It is
rejected: a canonical durable element would then carry transport metadata, two
adapters producing identical text would commit different bytes, and a replay
would have to explain a chunk count that has nothing to do with what was said.
The private attempt record is where evidence about a call belongs.

**Let an abort keep the queued follow-up.** Defensible — the operator might be
stopping only this run. It is not recommended: an abort is what an operator
reaches for when things are going wrong, and starting queued work seconds later
is the opposite of what they asked for. Where they do want it, resubmitting a
follow-up costs one command.

**Assemble the durable assistant message from deltas in core.** It is how many
harnesses work and it avoids asking adapters for a complete reply. It is not
recommended: durable truth would then depend on a plane that is explicitly
allowed to drop items, every adapter would owe a perfectly lossless stream, and
the failure would appear as a subtly truncated conversation rather than a
failing test.

**Add `stream/3` beside `complete/2`.** Two callbacks let non-streaming adapters
stay simple. It is not recommended: core would carry two paths, the
non-streaming one would quietly become the tested one, and the two would drift
in exactly the places that matter — cancellation and usage. One callback with a
degenerate zero-delta implementation gets the same result.

**Publish deltas as durable public events so a reconnecting client can replay
them.** It would make reconnection perfect. It is rejected: it contradicts the
four-plane model, puts token-level progress into the durable taxonomy
permanently, and grows durable storage with material the vision explicitly says
a reconnecting client is not owed.

**Expose the model stream as a pull-based enumerable.** Idiomatic in places. It
is not recommended: pulling inverts ownership of the supervised model task, and
cancellation, timeouts, and backpressure then belong to whoever is consuming
rather than to the coordinator that must commit a truthful outcome.

Technical depth: [Alternative analysis](0011-session-input-algebra-and-streaming-technical.md#technical-adr-0011-alternatives).

<a id="concept-adr-0011-consequences"></a>
## Consequences

Four command types and their ordering rules become durable protocol from the
first journal `M2` writes. Adding a fifth later is additive, but the rules
between them — one application point, one-at-a-time queues, abort cancelling
both — are part of what a recorded journal means, so changing them becomes a
versioned change with fixtures rather than an edit. This is permanent.

One-at-a-time will be felt as a limitation. An operator who types two follow-ups
gets a refusal on the second, and the refusal is correct rather than a bug to
work around. Deliver-all needs a session option and an ordering proof, and until
then clients must render the refusal rather than hide it.

The unapplied-steer record makes a race visible instead of hiding it. Every
client that admits a steer must render that outcome, because an operator who
does not see it will believe their steer landed. This is a permanent obligation
on every future surface, including the protocol milestone's.

Changing `complete/2` to `complete/3` changes the Model behaviour for every
adapter at once — the ReqLLM edge, the deterministic fake, and any future
adapter. That is free today because nothing is released, and it would not be
free later. It is also the last cheap moment to make the durable message come
from a return value rather than from a stream.

Streaming makes rendering a real concern for the first time. Bounded chunk
sizes, backpressure, and coalescing become operator-visible: a fast provider
against a slow terminal drops deltas, the sequence gaps say so, and the complete
message still arrives. Clients that ignore the gaps will display a plausible but
incomplete answer during the run.

Reasoning deltas carry summary text and no signature material, so a provider
whose continuation depends on reasoning signatures cannot be continued natively.
That stays with the sidecar ADR 0010 defers, and this decision does not create a
place to retain such material.

Exposing all four inputs makes the foreground command do two things at once. It
must render deltas and read operator input in the same process for the whole
length of a run, and it must keep `steer` and `follow_up` distinguishable at the
keyboard without guessing. That is a real cost in the command's input handling,
and it is the cost of the milestone's own purpose: an operator who can only
watch and abort does not have a coding agent they can work with.

The executor port grows a progress parameter, which every executor
implementation — the local one and any future remote hand — must accept even
when it emits nothing. Progress from an executor is now something the
coordinator validates and can refuse, so a superseded executor's output is
dropped rather than rendered, and a client sees a sequence gap rather than
another operation's bytes.

Two sequence domains mean every client renders two loss checks rather than one,
and neither implies the other: a complete model stream says nothing about
whether a tool's output arrived whole. The alternative was one number that could
not be gapless, which is worse than two that are.

Technical depth: [Operational consequences](0011-session-input-algebra-and-streaming-technical.md#technical-adr-0011-consequences).

<a id="concept-adr-0011-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists and no installed base exists. `M2` tags no version:
`VERSION` stays `0.0.0` and the first version number is reserved for the
headless session-protocol milestone. The command shapes, queue states, delta
kinds, the executor progress event, and the `complete/3` and `execute/5`
signatures are all experimental and freeze nothing, and the compatibility
contract's freeze machinery is not engaged.

`M1` journals are not migrated. `M1` recorded only `prompt` and `abort` and its
test roots are discarded, so there is no queue state to upgrade and no delta
history to convert. The `M1` public event taxonomy gains the queue events
additively.

Rollback before closure removes `steer` and `follow_up` admission, the queue
records, the unapplied record, the promotion transition, and the delta plane
usage together, returning `complete/3` to `complete/2`, `execute/5` to
`execute/4`, and the session to
`prompt` and `abort`. It cannot be partial: the run-terminal transition reads
the queue, and abort's truthful outcome depends on the queue states it cancels.
Once a version is published, adding a command type or a delta kind is additive,
while changing an application point, a queue depth, or the reconstruction
obligation changes what a recorded run meant and requires a successor decision.

Technical depth: [Format, migration, and rollback mechanics](0011-session-input-algebra-and-streaming-technical.md#technical-adr-0011-compatibility).

## Links

- [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) — the
  conversation elements an applied steer joins and the canonical request a
  streamed turn dispatches unchanged
- [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) — the
  cancellation algebra an abort drives and the tool calls whose progress streams
- [ADR 0006](0006-store-transaction-and-owner-epoch.md#concept) — the owner
  epoch and journal version every admitted command is fenced by
- [ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept) —
  the succession a queued follow-up must survive without starting twice
- [ADR 0007](0007-local-executor-grant-job-receipt.md#concept) — the identity,
  digest, and fence an executor progress event echoes and the coordinator
  validates before projecting a delta
- [Vision loop semantics](../vision-technical.md#technical-vision-loop-semantics) — one run, the four input paths, and the split payload rule
- [Vision public protocol](../vision-technical.md#technical-vision-public-protocol) — the four stream planes and what a reconnecting client is owed
- [Vision model and context boundary](../vision.md#concept-vision-model-boundary) — the canonical types and the provider conformance obligation
- [AGENTS.md](../../AGENTS.md) — truth planes, plain boundary data, one serial
  session owner, and the smallest sufficient system
