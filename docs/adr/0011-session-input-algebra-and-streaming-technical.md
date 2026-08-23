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
| `steer` | run active, `run_id` matches, no unapplied steer | accepted; queued for the single application point |
| `steer` | run active, `run_id` matches, one steer already unapplied | `{:error, :steer_pending}` |
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
queued    -> applied     steer reached its application point
queued    -> unapplied   run reached a terminal outcome first
queued    -> cancelled   abort admitted
queued    -> promoted    follow-up became a new run at the terminal transition
```

Every transition is a committed record naming the `command_id`, the reason, and
the run it was bound to. No transition is inferred at read time, so a successor
owner recovers queue state by projection rather than by re-deciding it.

### The single application point

Per turn, in order:

1. All tool results of the latest assistant message commit, in the assistant's
   call order, under ADR 0010's ordering invariants.
2. If a steer is `queued` for this run, commit it as `applied` together with a
   user-role conversation element carrying its exact bytes.
3. Evaluate ADR 0010's termination and bound checks.
4. Stage and dispatch the next request, whose projection now contains the
   applied element.

Steps 2 and 3 are ordered deliberately: an applied steer is part of the
conversation even when the immediately following bound check ends the run, so a
replay shows the steer that was accepted rather than losing it to a limit. A
steer admitted while step 1 is still in progress is applied at step 2 of that
same turn. A steer admitted after step 4 waits for the next turn's step 2 —
unless the run ends first, which is the unapplied case below.

### The unapplied race

Admission and terminal commit are both serialized by the one session owner, so
exactly one order is durable. The rule follows the journal:

| Durable order | Outcome |
| --- | --- |
| Steer admitted, then at least one further request staged | `applied` at that turn's step 2 |
| Steer admitted, then the run commits a terminal outcome with no further staging | `unapplied(run_terminal)` |
| Steer admitted after the terminal outcome commits | `{:error, :no_active_run}` at admission |

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
returns the complete reply. The reply gains two fields:

```text
delta_count   number of deltas emitted for this turn
streamed      whether this adapter emitted any
```

`delta_count` is what lets a consumer prove it saw everything without core ever
reconstructing anything.

### Delta shapes

```text
text_delta       {turn_id, sequence, base_event_sequence, content_index, text}
reasoning_delta  {turn_id, sequence, base_event_sequence, content_index, text}
tool_call_delta  {turn_id, sequence, base_event_sequence, call_index,
                  tool_call_id | nil, name | nil, arguments_fragment | nil}
tool_progress    {turn_id, sequence, base_event_sequence, tool_call_id,
                  operation_id, attempt, stream, byte_offset, chunk}
```

Rules:

- `sequence` starts at 0 for each turn and increases by one per emitted delta,
  across all kinds, so one counter orders the whole turn.
- `base_event_sequence` is the public event sequence the progress is anchored
  to, as §11.2 requires of the progress plane.
- Each payload is bounded by a declared ceiling; an adapter that would exceed it
  splits into more deltas rather than emitting one large item.
- `stream` for tool progress is a closed enumeration of `stdout` and `stderr`,
  and `byte_offset` is the executor-side offset so a consumer detects a dropped
  chunk the same way it detects a dropped delta.
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
abort admitted (ADR 0009 admission, unchanged)
  -> cooperative cancel to the supervised model task
  -> adapter stops emitting deltas
  -> no assistant_message element is committed for this turn
  -> model operation: cancelled, with delta_count and observed bytes as
                      attempt evidence; usage recorded as unknown
  -> run: cancelled
  -> a later complete reply for that attempt is retained as attempt evidence
     and never becomes a canonical assistant message
```

There is no partial assistant message and no partial content block. A turn is
durable in full or not at all, which is what keeps ADR 0010's projection a
function of complete elements. Unknown usage for the cancelled attempt is
accounted conservatively from the committed canonical request bytes under ADR
0010's estimation rule, so cancelling a run does not make its tokens free.

### Provider conformance

The suite is the same reusable one every model adapter runs, extended with:

- `complete/3` returns, for a given committed request, the same reply the
  adapter would return with a no-op progress function;
- emitted deltas, replayed in order, reconstruct byte-identical content to the
  returned reply's content blocks and tool calls;
- `delta_count` equals the number of deltas actually emitted;
- `sequence` is gapless and starts at 0;
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

### Evidence

- Admission conformance for all four commands across every row of the
  resolution table, each asserting the exact durable resolution and that a
  re-presented `command_id` returns it unchanged.
- A steer applied at the single application point, asserting that the element
  commits after the last tool result of its turn and before the staged request,
  and that the staged request's projection contains it.
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
- An abort cancelling an unapplied steer and a queued follow-up, asserting each
  `command_id` resolves `cancelled`, that no run starts afterwards, and that ADR
  0009's cleanup and terminal algebra are unchanged.
- Model conformance for streaming and non-streaming adapters, including
  reconstruction equality, gapless sequence, `delta_count` agreement, and
  cancellation.
- A cancelled stream committing no `assistant_message` element, with the
  attempt evidence retained and the usage accounted as estimated.
- A progress consumer that drops deltas under backpressure, asserting that the
  gap is detectable, that the durable assistant message is complete, and that
  no delta was journaled or published as a durable event.
- Source inspection proving core never reconstructs an assistant message from
  deltas and that no delta type appears in a durable or public payload.

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
- Deferring the operator-facing steer and follow-up surface leaves proven kernel
  semantics unreachable from the shipped command. Documentation must say so.

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

<a id="technical-adr-0011-compatibility"></a>
## Format, Migration, and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0011-session-input-algebra-and-streaming.md#concept-adr-0011-compatibility).

The durable format gains the `steer` and `follow_up` command records, the queue
slot states and their transitions, the applied steer conversation element, the
unapplied record, the promotion record, and the `delta_count` and `streamed`
fields on a committed assistant message. All are bounded plain data in the
session mutation domain. The public taxonomy gains the queue events additively;
no delta enters a durable or public payload.

There is no installed base and no published package, and `M2` tags no version:
`VERSION` stays `0.0.0` and the first version number belongs to the headless
session-protocol milestone. Command shapes, queue states, delta kinds, and the
`complete/3` signature freeze nothing. `M1` journals are neither read nor
migrated and its test roots are discarded, so no queue state and no delta
history exist to convert.

Rollback before closure removes `steer` and `follow_up` admission, the queue
records and transitions, the unapplied record, the promotion path, and the
progress emission together, and returns the Model behaviour to `complete/2`.
Partial rollback is not available: the run-terminal transition reads the queue,
abort's truthful resolution depends on the queue states it cancels, and the
cancellation rule for a partially streamed turn only has meaning where a turn
can stream. Once a version is published, adding a command type or a delta kind
is additive with fixtures, while changing the application point, a queue depth,
the reconstruction obligation, or the rule that a cancelled turn commits nothing
changes what a recorded run meant and requires a successor decision.
