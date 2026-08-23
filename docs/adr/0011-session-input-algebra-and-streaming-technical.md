# 0011: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Session input algebra and streaming progress](0011-session-input-algebra-and-streaming.md#concept).

<a id="technical-adr-0011-context"></a>
## What M1 Admits, What the Loop Needs, and What the Port Lacks

Concept: [Context](0011-session-input-algebra-and-streaming.md#concept-adr-0011-context).

`M1`'s session state machine proposes exactly two command types. A `prompt`
while `active_run_id` is set commits a durable rejection recorded as
`rejected_run_active`; an `abort` while a run is active commits the abort fact
and clears the active run. There is no third shape, no queue, and no place a
command can wait.

| Vision requirement | `M1` today | Consequence for `M2` |
| --- | --- | --- |
| §10.3 `steer` applies to the active run before the next model request | Not representable; a prompt is rejected while a run is active | An operator can only stop a run that is going wrong |
| §10.3 `follow_up` creates a run after the current one settles | Not representable | Queued work has nowhere to live across a terminal outcome |
| §10.2 step 11 gives steering one application point | No application point exists | The first implementation would fix the point by accident |
| §10.2 step 13 starts the next run from the queue | `run_terminal` always leads to settled | The transition has no recovery story because there is nothing to recover |
| §10.3 Loopex never guesses steer versus follow-up | Vacuous — there is one input | The guess becomes tempting exactly when two inputs exist |
| §13.1 canonical streamed call deltas and complete streamed messages | `complete/2` returns a whole reply | A minutes-long run prints nothing until it ends |
| §11.2 deltas are transient and the complete message is durable | No delta exists to misclassify | Adding streaming without the boundary makes progress durable by accident |
| §11.5 lists `tool.stdout_delta`, `tool.stderr_delta`, and `tool.progress` as transient progress | `execute/4` returns one receipt and has no progress channel | A tool-progress delta kind has no producer until a decision gives it one |
| §15.1 every executor event echoes the complete identity and fence | Only the receipt carries the tuple, and only the receipt is validated | Progress from a superseded executor would be unrefusable |

The `M1` shapes that already exist are the ones this decision builds on rather
than replaces. Command admission is idempotent on `(session_id, command_id)`,
fenced by owner epoch and journal version, and answered once. An attachment
already carries a transient progress sink, and `Runtime.progress/2` already
delivers to it without touching a durable plane. Neither needs a new mechanism;
they need new content and new ordering rules.

<a id="technical-adr-0011-decision"></a>
## Exact Command, Queue, Transition, and Delta Contract

Concept: [Decision](0011-session-input-algebra-and-streaming.md#concept-adr-0011-decision).

### Admitted commands

```text
prompt     {type, command_id, content}
steer      {type, command_id, run_id, content}
follow_up  {type, command_id, content}
abort      {type, command_id}
```

All four are bounded plain data. `content` is exact bytes, never a rendered or
summarized form, and is retained as submitted. Admission resolutions are
exhaustive and durable:

| Command | Session state | Resolution |
| --- | --- | --- |
| `prompt` | settled | accepted; run starts |
| `prompt` | run active | `{:error, :run_active}`, durably recorded as today |
| `steer` | run active, `run_id` matches, no `queued` steer | accepted; queued for the single application point |
| `steer` | run active, `run_id` matches, one steer already `queued` | `{:error, :steer_pending}` |
| `steer` | run active, `run_id` does not match | `{:error, :run_mismatch}` |
| `steer` | settled | `{:error, :no_active_run}` |
| `follow_up` | run active, no follow-up queued | accepted; queued |
| `follow_up` | run active, one follow-up queued | `{:error, :follow_up_pending}` |
| `follow_up` | settled | `{:error, :no_active_run}` |
| `abort` | run active | accepted; cancellation begins and both queues are cancelled |
| `abort` | settled | accepted and terminal, as `M1` records it |

Re-presenting any `command_id` returns its original durable resolution. A
rejection is as durable as an acceptance, so a client that lost its reply learns
the same answer and never converts a refusal into a second queued item.

### Queue states

One steer slot per run and one follow-up slot per session, each holding a
committed command in exactly one state:

```text
queued    -> applied     a committed staged request carries the steer
queued    -> unapplied   the run ended with no request carrying it
queued    -> cancelled   abort admitted
queued    -> promoted    follow-up became a new run at the terminal transition
```

`applied` commits only in the same transaction as the request that carries the
steer, so the slot is never `applied` on the strength of an intention.

Every transition is a committed record naming the `command_id`, the reason, and
the run it was bound to. No transition is inferred at read time, so a successor
owner recovers queue state by projection rather than by re-deciding it.

### The single application point

Per turn, in order:

1. All tool results of the latest assistant message commit, in the assistant's
   call order, under ADR 0010's ordering invariants.
2. Evaluate ADR 0010's termination and bound checks. If the model requested no
   tool, or the maximum turn count, the cumulative token budget, or the
   wall-clock deadline is exhausted, the run ends here and any `queued` steer
   resolves `unapplied` with that exact reason.
3. Otherwise build the next request: project the committed conversation, append
   a `queued` steer's exact bytes as a user-role element, canonicalize, and
   digest.
4. Commit, in **one** transaction, the steer's `applied` transition, its
   user-role conversation element, and the staged request bytes and digest. If
   that transaction does not commit, neither does the element: the steer stays
   `queued` and resolves `unapplied` when the run reaches its terminal outcome.
5. Dispatch exactly the staged bytes.

Steps 2 and 4 are ordered deliberately, and the order is the opposite of the
convenient one. `applied` means a model call carried the steer, not that it
reached a projection, so nothing commits applied before the request that carries
it commits with it. A steer admitted while step 1 is still in progress is
applied at step 4 of that same turn. A steer admitted after step 5 waits for the
next turn — unless the run ends first, which is an unapplied case below.

The atomicity is what removes the window. There is no interval in which the
element is committed and the request that carries it is not, so a successor
owner never recovers an applied steer no request carried, and no operator is
ever told a steer landed that no model call saw.

### The unapplied cases

Admission, staging, and terminal commit are all serialized by the one session
owner, so exactly one order is durable. The rule follows the journal:

| Durable order | Outcome |
| --- | --- |
| Steer admitted, then a request carrying it commits at step 4 | `applied`, in that same transaction |
| Steer admitted, then the run commits a terminal outcome with no further staging | `unapplied(run_terminal)` |
| Steer admitted, then step 2 ends the run on a bound | `unapplied(max_turns)`, `unapplied(token_budget)`, or `unapplied(deadline)` |
| Steer admitted, then step 4 fails closed and the run reaches a terminal outcome | `unapplied` with that terminal reason |
| Steer admitted after the terminal outcome commits | `{:error, :no_active_run}` at admission |

`applied` is therefore true of exactly the steers some committed canonical
request carries, and every other admitted steer of that run is `unapplied`,
`cancelled`, or still `queued`. There is no third reading of the record.

An `unapplied` steer emits a public event carrying its `command_id`, the run it
named, and the reason. It never enters a projection, is never auto-promoted to a
follow-up, and its bytes are retained so a client can offer them back to the
operator for resubmission under a new `command_id`.

### Run-terminal transition

One transaction commits:

```text
terminal outcome for the run
run.finished public fact
  + follow-up queued    -> promotion record: command_id, new run_id
  + no follow-up queued -> session.settled public fact
```

The promoted run's request is staged afterwards in the ordinary way, so
`run.started` still commits with the staged bytes and the model intent as §10.2
step 4 requires. Recovery covers the window between them: a promoted run with no
committed staged request is staged by the recovering owner under the same
`run_id`, and because promotion is a durable transition of one committed
`command_id`, a replayed recovery cannot start a second run for it. A promoted
run whose staging fails closed reaches a terminal outcome like any other run and
the session settles.

`run.finished` and `session.settled` stay distinct exactly as the vision
requires: a finished run whose follow-up was promoted publishes no settled fact.

### Abort and the queues

A durably admitted abort commits the cancellation of both slots in the same
transaction that begins ADR 0009's cancellation sequence. Each cancelled slot is
recorded against its own `command_id`, so re-presenting that command returns
`cancelled` rather than queueing it again. Nothing about ADR 0009's cleanup
sequence, grace period, or terminal algebra changes; this decision only fixes
what happens to work that had not started.

### The model port

```text
@callback complete(request(), keyword(), (delta() -> :ok)) ::
            {:ok, reply()} | {:error, term()}
```

The progress function is an ordinary in-VM function reference supplied by the
coordinator's supervised model task. It is not boundary data: it never enters a
journal, a public event, a snapshot, or an executor job, and the deltas it
carries are plain bounded data. An adapter calls it zero or more times and then
returns the complete reply. The reply gains two statistics:

```text
delta_count   number of deltas this attempt emitted
streamed      whether this adapter emitted any
```

Both describe one model attempt. They are retained on that private attempt
record beside its usage and timing, and they are **not** fields of the
`assistant_message` element ADR 0010 commits: the canonical durable element
carries conversation content only. `delta_count` is what lets a consumer prove
it saw the whole stream without core ever reconstructing anything, and it
reaches that consumer as the closing progress item defined below rather than as
a field of a durable element.

### The executor port

```text
@callback execute(reference(), job_request(), grant(), keyword(),
                  (executor_progress_event() -> :ok)) ::
            {:ok, receipt()} | {:error, term()}
```

`execute/4` becomes `execute/5` and gains nothing else. The fifth argument is
the same shape of in-VM bounded function the Model port receives, supplied by
the dispatching coordinator for exactly one job; it is not boundary data, never
enters a journal, a public event, a snapshot, or a job request, and is invalid
once that job reaches a terminal receipt. An executor that emits nothing is
conformant. ADR 0009's and ADR 0007's grant bindings, job request, receipt
schema, deduplication rule, cancellation sequence, and terminal algebra are
unchanged, with one additive private field named under executor progress below.

### Executor progress events

The executor emits complete executor events, echoing the identity and fence the
vision requires of every executor event:

```text
executor_progress_event
  protocol_version
  job_id
  operation_id / attempt
  session_id / run_id / turn_id / tool_call_id
  origin_session_epoch / origin_executor_epoch
  executor_identity
  canonical_request_digest
  fencing_token
  progress_sequence
  stream            stdout | stderr | progress
  byte_offset       per stream, contiguous
  chunk             bounded bytes, or a bounded structured payload
```

Before projecting anything narrower, the coordinator validates each binding
against state it already holds for the live attempt, never against the event:

| Binding | Validated against |
| --- | --- |
| `job_id`, `operation_id`, `attempt` | The operation attempt this coordinator dispatched and journaled |
| `canonical_request_digest` | The digest journaled for that attempt |
| `session_id` / `run_id` / `turn_id` / `tool_call_id` | The live run's current turn and one of its committed tool calls |
| `origin_session_epoch` | The current session epoch |
| `origin_executor_epoch` | The executor epoch recorded for this dispatch |
| `executor_identity` | The executor this job was dispatched to |
| `fencing_token` | The current fence for that workspace lease |
| `progress_sequence` | The next expected sequence for that operation attempt |

Validation is fail-closed in both directions and identical in consequence: a
missing binding and a present, well-formed, wrong binding are both refused. A
refused event is dropped and counted on the attempt's private record as refused
progress with the binding that failed. It is never projected, never journaled,
never published, and never affects an outcome, a bound, or a receipt. This is
ADR 0007's receipt discipline with a weaker consequence, because progress
carries no authority: a superseded executor cannot make a client render its
bytes, and it also cannot make the coordinator commit anything.

The retained receipt gains one additive private field,
`final_progress_sequence`, the last sequence the executor emitted for that
attempt. It bounds the progress
domain the same way `delta_count` bounds the model domain, so a consumer detects
a truncated tail rather than only an interior gap.

### Delta shapes

The client-facing deltas are projections. They carry the anchors a consumer
needs and none of the administrative material validation consumed, because
leases, epochs, receipts, and fences are private or administrative in the public
vocabulary:

```text
text_delta       {turn_id, model_sequence, base_event_sequence,
                  content_index, text}
reasoning_delta  {turn_id, model_sequence, base_event_sequence,
                  content_index, text}
tool_call_delta  {turn_id, model_sequence, base_event_sequence, call_index,
                  tool_call_id | nil, name | nil, arguments_fragment | nil}
tool_progress    {turn_id, tool_call_id, progress_sequence,
                  base_event_sequence, stream, byte_offset, chunk}
```

One `tool_progress` kind carries a `stream` discriminant rather than reproducing
§11.5's three named kinds `tool.stdout_delta`, `tool.stderr_delta`, and
`tool.progress`. That is a deliberate narrowing and is recorded as one: the three
differ only in which stream a chunk came from, they share one
`(operation_id, attempt)` sequence domain, and they carry the identical identity,
epoch, digest, and fence tuple that must be validated before any of them is
projected. Three kinds would mean three shapes validated three ways and three
independent gap analyses over one ordered byte stream. §11.5 opens its list with
"transient progress begins with", so the set is extensible; this ADR spends that
room on a discriminant rather than on kinds, and a surface that wants the vision's
three names projects them from `stream` without another decision.

Each domain is closed on the same plane it streamed on, by one item that carries
no content:

```text
model_stream_closed  {turn_id, base_event_sequence, delta_count}
tool_stream_closed   {turn_id, tool_call_id, base_event_sequence,
                      final_progress_sequence}
```

These are stream closures, not content deltas, and they are how a client learns
a total it must not read from a durable element: the reply's `delta_count` and
the receipt's `final_progress_sequence` are private evidence, and the
coordinator projects each as one closing item after the attempt or operation
terminates. A closure is itself progress and may be dropped; a consumer that
never receives one falls back to the durable message exactly as it does for a
gap.

Rules:

- `model_sequence` starts at 0 for each model attempt and increases by one per
  emitted delta across the three model kinds, so one counter orders that reply.
  The reply's `delta_count` closes it.
- `progress_sequence` starts at 0 for each `(operation_id, attempt)` and
  increases by one per emitted executor progress event for that attempt. The
  receipt's `final_progress_sequence` closes it. It is the executor's own
  sequence, carried through the projection unchanged, so a consumer's gap is the
  same gap the coordinator would see.
- The two domains are independent. A model attempt's stream is complete or lossy
  regardless of any operation's progress, and no order is promised between them
  beyond `base_event_sequence`. One shared per-turn counter is not available:
  the reply publishes `delta_count` before the turn's first tool is dispatched,
  so a shared counter could only reserve numbers that may never be used.
- `base_event_sequence` is the public event sequence the progress is anchored
  to, as §11.2 requires of the progress plane.
- Each payload is bounded by a declared ceiling; a producer that would exceed it
  splits into more items rather than emitting one large one.
- `stream` is a closed enumeration of `stdout`, `stderr`, and `progress`, and
  `byte_offset` is contiguous per stream, so a consumer detects a dropped chunk
  within a stream as well as a dropped event.
- `reasoning_delta` carries summary text only. No signature, token blob, or
  provider continuation material is admitted, because nothing in `M2` retains
  it and a value that cannot be retained must not be transported.
- No delta carries a provider struct, pid, port, reference, function, module
  atom, stack trace, terminal escape sequence, or credential.
- A `tool_call_delta` is progress about a call being assembled. It never
  executes anything: only the complete tool calls in the returned reply reach
  resolution, policy, and dispatch, as §10.2 step 6 requires.

### Cancellation mid-stream

```text
abort admitted through the facade and committed, also resolving any queued
                steer and follow-up (M1 admission, extended by this ADR)
  -> cooperative cancel to the supervised model task
  -> adapter stops emitting deltas
  -> no assistant_message element is committed for this turn
  -> model operation: cancelled, with delta_count and observed bytes as
                      attempt evidence; usage recorded as unknown
  -> run: ADR 0009's derived outcome — cancelled only when every owned
          operation reached a validated terminal fact and every owned process
          tree was confirmed cleaned, otherwise outcome_unknown
  -> a later complete reply for that attempt is retained as attempt evidence
     and never becomes a canonical assistant message
```

There is no partial assistant message and no partial content block. A turn is
durable in full or not at all, which is what keeps ADR 0010's projection a
function of complete elements. Unknown usage for the cancelled attempt is
accounted under ADR 0010's rule for an incomplete turn, which charges the
committed canonical request bytes plus that turn's committed `max_tokens`
allowance in full, marked `estimated`. The observed byte count above is attempt
evidence and never the charge: charging what was observed would make a
generation cancelled at the last moment cost about what an empty turn costs, and
a run could then stay inside a token budget indefinitely by aborting every turn.

### Provider conformance

The suite is the same reusable one every model adapter runs, extended with:

- `complete/3` returns, for a given committed request, the same reply the
  adapter would return with a no-op progress function;
- emitted deltas, replayed in order, reconstruct byte-identical content to the
  returned reply's content blocks and tool calls;
- `delta_count` equals the number of deltas actually emitted, and equals the
  count in the attempt's `model_stream_closed` item;
- `model_sequence` is gapless, starts at 0, and never appears on a committed
  `assistant_message`, which carries no stream statistic at all;
- a non-streaming adapter emits zero deltas, returns the complete reply, and
  reports `streamed: false`;
- cancellation mid-stream stops emission and returns a cancellation error, with
  no delta emitted after the cancel was observed;
- no delta contains a provider struct, pid, credential, or unbounded payload;
- the committed canonical request bytes reach the adapter unchanged, which is
  ADR 0010's assertion applied to this callback.

The deterministic test adapter satisfies the suite with a scripted delta script:
fixed chunk boundaries, a fixed count, and fixed content, so ordering,
reconstruction, gap detection, and cancellation are exact and do not depend on a
provider's chunking.

### Executor conformance

The reusable executor suite gains, and every executor implementation runs:

- an executor that emits no progress is conformant, returns the same receipt,
  and reports `final_progress_sequence` as the empty domain;
- emitted progress events carry every binding in the tuple above, checked
  against a literal expected set so a field omitted from an implementation is
  detectable;
- `progress_sequence` is gapless from 0 per `(operation_id, attempt)` and
  `byte_offset` is contiguous per stream;
- `final_progress_sequence` on the receipt equals the last sequence emitted, and
  equals the value in the operation's `tool_stream_closed` item;
- no progress event is emitted after the terminal receipt for its attempt;
- no progress event carries a credential, a workspace absolute path outside the
  declared output policy, an unbounded payload, a pid, or a provider or host
  struct.

Coordinator-side negatives are separate, because they test the validator rather
than the executor: for each binding, an otherwise-valid progress event with that
single binding altered to a present, well-formed, wrong value — another
executor's identity, the previous attempt, a superseded fence, a stale executor
epoch, another request's digest, a tool call from an earlier turn — is refused
individually, the refusal names that binding, and the covered set equals the set
the schema requires so two guards cannot mask each other.

### Evidence

- Admission conformance for all four commands across every row of the
  resolution table, each asserting the exact durable resolution and that a
  re-presented `command_id` returns it unchanged.
- A steer applied at the single application point, asserting that the element
  commits after the last tool result of its turn, in the same transaction as the
  staged request, and that the staged request's projection contains it.
- A steer queued for a turn whose bound check ends the run, once per bound,
  asserting `unapplied(max_turns)`, `unapplied(token_budget)`, and
  `unapplied(deadline)`, that no conversation element was committed, and that no
  request was staged. This is the ordering property: an operator is never told a
  steer applied when no model call carried it.
- A coordinator killed at the application point, asserting that the applied
  transition, the conversation element, and the staged request are all present
  or all absent, and that the all-absent recovery resolves the steer truthfully.
- A steer admitted during an in-flight last turn that ends without further
  staging, asserting `unapplied(run_terminal)`, the public event, an unchanged
  projection, and no auto-promotion.
- Second steer and second follow-up refused with their exact reasons, with the
  first still intact.
- A queued follow-up promoted at the terminal transition, asserting one
  transaction for outcome, `run.finished`, and promotion, and no
  `session.settled`.
- A coordinator killed between promotion and staging, asserting recovery stages
  the same `run_id` once and that a replayed recovery starts no second run.
- An abort cancelling a `queued` steer and a queued follow-up, asserting each
  `command_id` resolves `cancelled`, that no run starts afterwards, and that ADR
  0009's cleanup and terminal algebra are unchanged.
- Model conformance for streaming and non-streaming adapters, including
  reconstruction equality, gapless sequence, `delta_count` agreement, and
  cancellation.
- A cancelled stream committing no `assistant_message` element, with the
  attempt evidence retained and the usage accounted as estimated.
- A progress consumer that drops deltas under backpressure, asserting in each
  domain separately that the gap is detectable — an interior `model_sequence`
  gap and a tail short of `model_stream_closed`, an interior `progress_sequence`
  gap and a tail short of `tool_stream_closed` — that the durable assistant
  message is complete, and that no delta or closure was journaled or published
  as a durable event.
- Executor progress from a superseded executor, a stale executor epoch, a
  previous attempt, and a mismatched digest, each asserting that the event is
  refused, counted as refused progress, and never projected to a client, and
  that the live operation's outcome is unchanged.
- Source inspection proving core never reconstructs an assistant message from
  deltas, that no delta type appears in a durable or public payload, that no
  client-facing delta carries executor identity, an epoch, a digest, or a fence,
  and that `delta_count` and `streamed` appear on no committed conversation
  element.
- The reference command admitting all four inputs from one foreground process:
  a `steer` and a `follow_up` typed while a run streams, each reaching the
  public facade with its kind named by the operator, the refusal of a second
  queued item rendered, an `unapplied` outcome rendered, and an input naming
  neither kind refused rather than inferred.

<a id="technical-adr-0011-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0011-session-input-algebra-and-streaming.md#concept-adr-0011-alternatives).

**`prompt` and `abort` only.** Genuinely the smallest option, and nothing about
it is unsafe. Its cost is paid later and by someone else. The application point
is defined by where the coordinator happens to check for input, and once a
protocol milestone serializes that behaviour it becomes the contract. Defining
it while the turn machine is open costs one queue slot and one transition
record; defining it afterwards costs a versioned change to what a recorded run
meant.

**Inferring the input kind.** The rule would have to be "steer while a run is
active, follow-up otherwise", which is exactly the guess §10.3 forbids and is
wrong in both directions. An operator who types a new task while a run is
finishing gets it spliced into the current run's context; an operator who types
a correction just after the last request gets a whole new run against a
conversation that already went wrong. Neither failure is visible in the moment,
and both are indistinguishable from the model behaving oddly.

**Deliver-all queues.** Each additional queued item multiplies cases: ordering
between two steers and one tool batch, what an abort does to items three and
four, what recovery replays after a crash between two applications. The vision
asks for an explicit session option and an ordering proof for exactly that
reason. One slot with an explicit refusal is provable now and widens additively.

**Immediate steering.** The two available shapes are both wrong for `M2`.
Abandoning a running tool contradicts §10.3's statement that steering does not
pretend to reverse an effect already started, and interleaving a steer between
tool results creates a second application point whose ordering against the
committed result sequence is undefined — which would make ADR 0010's projection
depend on arrival timing rather than commit order.

**Silent discard of a late steer.** It costs nothing to implement and it removes
one record. It also removes the only evidence that the operator tried. The
durable `unapplied` record plus its event is two fields and one event type, and
it converts an invisible race into a visible outcome.

**Applying before the bound check.** The argument is that the steer is already
accepted and the conversation should show it. The consequence is that `applied`
stops meaning anything an operator can use. A run that exhausts its turn budget
immediately after committing the element reports the steer applied, the operator
reads that as "the model was told", and the model was never called again. Making
the element and the request one transaction costs nothing beyond writing them
together — they are already written in the same turn, to the same domain, by the
same serial owner — and it makes the record's two states exhaustive: carried by
a request, or not.

**Kernel-only exposure of `steer` and `follow_up`.** The technical argument for
it disappears once the foreground shape is fixed. There is no transport to
implement, no daemon, no second process, and no attachment negotiation: the
process that renders the stream is the process that reads the keyboard and holds
the facade reference. The residual work is concurrent input handling in one
command and two distinct affordances, which is smaller than the documentation
required to explain why a proved capability is unreachable.

**One sequence domain.** It fails on an ordering fact, not on taste. The model
reply returns with `delta_count` fixed, and the turn's tool dispatch happens
after that. A shared per-turn counter would have to publish a total before the
executor's contribution exists, so either the total is not a total or the
executor renumbers into reserved space it may not fill — and a reserved gap is
indistinguishable from a lost item, which is precisely the property the sequence
exists to provide. Two domains, each closed by its own producer's terminal
statement, keep gaplessness meaning one thing.

**Executor progress out of scope.** Dropping the delta kind is the smallest
change and leaves the executor port untouched. It also makes the milestone's
longest silences the ones the operator most wants to watch: a build or a test
suite streams nothing while the model's prose streams fully. And the kind would
return later against a protocol whose delta taxonomy, sequence semantics, and
executor callback had all frozen without it, which is a versioned change instead
of one parameter.

**Unvalidated projection of executor progress.** Progress commits nothing, so
the temptation is to treat a stale chunk as harmless noise. It is not harmless:
it is another operation's bytes rendered as this one's, at the moment an
operator is deciding whether to abort. Every binding needed to refuse it already
rides on the event because the vision requires every executor event to echo the
identity and fence, and the coordinator already holds the state to compare
against. Refusing costs a comparison; rendering costs the operator's trust in
what the terminal shows.

**Stream statistics on the committed message.** Putting `delta_count` and
`streamed` on the `assistant_message` makes one record self-describing at the
cost of making the canonical element depend on transport. Two adapters returning
identical content would commit different elements, a non-streaming replay of a
streamed run would differ in bytes that mean nothing semantically, and ADR
0010's projection would carry a field no request may include. The attempt record
already exists, already holds usage and timing, and is private, which is the
plane evidence about a call belongs on.

**Abort preserving the queue.** The argument for it is real: an operator may be
stopping one run, not the session. The argument against is what an abort means
in practice — something is going wrong and the operator wants it to stop. A run
starting seconds later, from work queued before the problem was noticed, is the
kind of surprise that makes people kill the process instead. Resubmitting is one
command; unstarting a run is not.

**Core-side reconstruction.** It sounds equivalent and is not. It makes the
durable assistant message a function of a plane the vision explicitly allows to
drop items, so any coalescing, backpressure decision, or slow-consumer policy
becomes a correctness hazard rather than a rendering one. It also pushes an
obligation onto every adapter that only a conformance suite could check, and the
symptom of a violation is a silently truncated conversation.

**Two callbacks.** Two code paths in core is the whole objection. The one that
does not stream would be the one every test uses, and cancellation and usage —
the two behaviours hardest to get right — would be implemented twice. A single
callback with a zero-delta degenerate case has one path and one set of tests.

**Durable deltas.** Perfect replay for a reconnecting client, at the cost of
making token-level progress part of the durable taxonomy forever, growing
storage with material §11.2 says is not owed, and creating a second ordering
relationship between progress and events that the four-plane model deliberately
refuses.

**A pull-based enumerable.** The consumer would drive demand, which moves
cancellation, timeout, and backpressure decisions out of the supervised model
task and into whoever iterates. The coordinator must own those, because it is
the thing that has to commit a truthful terminal outcome regardless of what the
consumer did.

<a id="technical-adr-0011-consequences"></a>
## Operational Consequences

Concept: [Consequences](0011-session-input-algebra-and-streaming.md#concept-adr-0011-consequences).

### If accepted

- The command taxonomy and its ordering rules become durable protocol from the
  first journal. Adding a command later is additive; changing the application
  point, a queue depth, or abort's effect on the queues is a versioned change
  with fixtures.
- Every future surface inherits two rendering obligations: the refusal of a
  second queued item and the unapplied-steer outcome. A surface that hides
  either will mislead an operator about what was accepted.
- The Model behaviour changes for every adapter simultaneously. That is free
  before publication and permanent afterwards, which is the reason to do it in
  this milestone rather than the next.
- Progress becomes a real operational surface. Bounded payloads, coalescing, and
  slow-consumer drops are visible as sequence gaps, and clients must treat a gap
  as loss rather than as the end of the message.
- Cancellation gets simpler and more honest at the same time. A cancelled turn
  commits nothing, so there is no partial message to reconcile, and the cost is
  that a nearly complete answer is lost rather than salvaged.
- The foreground command reads operator input for the whole length of a run
  while it renders deltas, and keeps `steer` and `follow_up` distinguishable at
  the keyboard. Every input path it offers must name its kind, because the
  runtime refuses to infer one.
- The Executor port gains one parameter that every implementation accepts,
  including those that emit nothing, and the coordinator gains a validator whose
  negative corpus grows with the progress tuple.
- Clients render two loss checks rather than one, and a complete model stream
  implies nothing about whether an operation's output arrived whole.

### If rejected

- The coordinator still needs some answer to "what happens to input during a
  run", and it will be answered by implementation rather than by decision. The
  protocol milestone then inherits it as a de facto contract.
- Without a decided boundary, streaming arrives either as no streaming at all —
  a coding harness that prints nothing for minutes — or as deltas that quietly
  become the source of the durable message.
- A cancelled stream with no rule about partial messages produces the worst
  available outcome: a conversation containing half an assistant turn that
  replay cannot distinguish from a complete one.
- Tool progress without a decided emission path and validation rule arrives as
  whatever the first executor implementation does, most likely unvalidated,
  which puts a superseded executor's output on an operator's terminal with no
  decision anywhere saying it should not be.

<a id="technical-adr-0011-compatibility"></a>
## Format, Migration, and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0011-session-input-algebra-and-streaming.md#concept-adr-0011-compatibility).

The durable format gains the `steer` and `follow_up` command records, the queue
slot states and their transitions, the applied steer conversation element, the
unapplied record, and the promotion record. All are bounded plain data in the
session mutation domain. The committed `assistant_message` element gains
nothing: `delta_count`, `streamed`, refused-progress counts, and
`final_progress_sequence` are private attempt and receipt evidence. The public
taxonomy gains the queue events additively; no delta enters a durable or public
payload.

There is no installed base and no published package, and `M2` tags no version:
`VERSION` stays `0.0.0` and the first version number belongs to the headless
session-protocol milestone. Command shapes, queue states, delta kinds, the
executor progress event and its validation, and the `complete/3` and `execute/5`
signatures freeze nothing. `M1` journals are neither read nor
migrated and its test roots are discarded, so no queue state and no delta
history exist to convert.

Rollback before closure removes `steer` and `follow_up` admission, the queue
records and transitions, the unapplied record, the promotion path, and the
progress emission together, and returns the Model behaviour to `complete/2` and
the Executor behaviour to `execute/4`, dropping `final_progress_sequence` from
the receipt.
Partial rollback is not available: the run-terminal transition reads the queue,
abort's truthful resolution depends on the queue states it cancels, and the
cancellation rule for a partially streamed turn only has meaning where a turn
can stream. Once a version is published, adding a command type or a delta kind
is additive with fixtures, while changing the application point, a queue depth,
the reconstruction obligation, the progress validation rule, or the rule that a
cancelled turn commits nothing changes what a recorded run meant and requires a
successor decision.
