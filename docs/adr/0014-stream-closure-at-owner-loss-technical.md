# 0014. Stream closure at owner loss — technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Stream closure at owner loss](0014-stream-closure-at-owner-loss.md#concept).

<a id="technical-adr-0014-context"></a>
## The Unowned Interval

Concept: [Context](0014-stream-closure-at-owner-loss.md#concept-adr-0014-context).

This decision supersedes only these clauses of ADR 0011:

- the universal Concept claim that every domain the coordinator opens emits
  exactly one closure, whose enumerated terminal examples omit abrupt owner
  death even though the universal wording covers every opened domain;
- the Technical depth claim that the coordinator emits exactly one closure for
  every domain it opened where the coordinator can die or lose authority before
  emitting it; and
- the Concept and Technical depth ordering that every closure precedes the
  attempt outcome's publication, solely where a terminal fact commits before
  handoff while its Store or `post_commit` reply reaches the originating
  coordinator afterwards; and
- the matching evidence obligations wherever they require an observed closure
  after the process that alone knew the disposition and count no longer has
  standing to send it, or require the retained closure to precede independently
  delivered durable outbox publication.

ADR 0011 separately says a closure is transient, can be lost with its plane when
the owner changes, and that missing closure means an incomplete view. Those
consumer rules stay unchanged and become the governing recovery behavior for
the owner-loss cases this ADR names.

ADR 0011's event-validation rule also remains unchanged. An executor event
rejected by its identity, epoch, digest, attempt, fence, or payload increments
the relay's private refused counter and is not projected. If owner loss ends the
plane before ordinary closure, that non-durable counter ends with the relay;
ADR 0011 promises no durable refusal record and says the refused event is never
journaled. A Control owner-loss verdict is not one of those event-validation
refusals: it ends the stale session owner's transient plane, projects nothing,
and authorizes that stale coordinator to retain no new refusal accounting.

ADR 0006 governs durable commit, current-cache mutation, durable public and
outbox publication, and dispatch. Transient progress is a distinct truth plane
in the vision. A retained terminal operation fact can therefore make its
originating relay's transient closure truthful without authorizing the stale
coordinator to mutate the current cache, publish a durable public event or
outbox fact, dispatch, emit new progress, retain refusal accounting, or perform
later run work. A diagnostic about progress already refused is admitted only
after a fresh Control owner check, and its private record remains atomically
Store-fenced. No ADR 0006 clause is narrowed.

The irreducible death windows are:

```text
durable reply or receipt commits
owner dies
closure was not emitted
```

and:

```text
closure is emitted
owner dies before any transferable emission record exists
successor cannot distinguish this from the first window
```

A monitor sees only the death. A successor sees the durable journal but cannot
observe the old transient mailbox or prove whether the closing send happened.
The progress sink has no idempotent closure acknowledgement. No process can
select `complete` or `abandoned` and guarantee exactly one emission across both
windows from those inputs.

Live executor succession adds two orderings which are both owner loss:

```text
Control removes the predecessor from the runtime-local current-owner slot
successor advances durable ownership
predecessor later receives the supersession notification
```

and:

```text
successor advances durable ownership
predecessor receipt meets the Store's stale-owner fence
supersession notification is still queued
```

The effectful worker may have crossed its effect boundary, may be constructing a
receipt, or may already have returned one that the fenced owner can no longer
retain. Neither a Control refusal nor a stale-owner Store refusal proves the
effect absent. A model worker has no corresponding host effect, so the live
owner can terminate and drain it after receiving the handoff before selecting
`abandoned`.

<a id="technical-adr-0014-decision"></a>
## Normative State and Ordering

Concept: [Decision](0014-stream-closure-at-owner-loss.md#concept-adr-0014-decision).

For a domain whose owner remains authoritative:

1. a completed model attempt retains its assistant message before emitting one
   `complete` closure carrying the reply's `delta_count`;
2. a completed executor attempt retains its receipt before emitting one
   `complete` closure carrying the receipt's `progress_count`;
3. a known failed, refused, cancelled, or retried attempt that produced no
   durable artifact emits one `abandoned` closure carrying the relay's observed
   count; and
4. the relay is the only emitter, so that closure is the last item in its domain
   and later producer messages are dropped.

The runtime-local Control owner slot is the admission boundary for transient
items and closures that have no retained terminal fact. Checking the exact
owner and sending to or closing the relay are one serialized Control operation.
Starting acquisition removes the predecessor from that slot before the
successor's Store transaction, so the old transient plane is fenced no later
than durable ownership advancement. A separate current-owner check followed by
a relay send is non-conforming because acquisition can linearize between them.

The delivered live-model supersession notification is the second deliberate
admission rule. The old coordinator first terminates and drains the effect-free
model worker and then closes that model domain directly as `abandoned`. It does
not pass that closure through Control because Control has already admitted the
handoff; the terminated worker and the coordinator's own relay count are what
make the abandoned disposition truthful. A prior Control or Store fence may
have marked the coordinator stale without ending model work, so that boolean
cannot suppress the notification's idempotent termination, drain, and closure.

A closure backed by a retained terminal operation fact is the other deliberate
admission rule. The originating coordinator may close its own relay directly
after retention because the durable fact fixes the disposition and producer
count; the successor never closes or reuses that domain. The closure is
transient progress rather than cache mutation, durable public or outbox
publication, or dispatch, so it creates no ADR 0006 exception. It authorizes no
new progress, refusal record, or later run work. If terminal model-result or
executor-fact retention instead
meets a stale-owner Store refusal, the predecessor recognizes owner loss,
discards the relay without closure, and performs no further progress or
refusal-record commit under the stale epoch.

An ordinary commit whose Store result was delayed can become durable before the
successor reaches Control. When that result is finally processed, the old
coordinator's `post_commit` fence may answer `superseded_owner`. A retained model
reply or executor receipt remains true and recoverable: the originating
coordinator applies the committed reducer result, closes its own relay
`complete` with the fact's producer count, marks itself superseded, and performs
no later run work. The closure is admitted by the retained fact rather than by
stale owner authority. The Control refusal is therefore neither an executor-fact
failure nor a reason to discard a truthful terminal item.

When a model predecessor receives live supersession, it performs these local
steps:

1. stops and drains the model worker;
2. disarms the old owner's deadline timer;
3. closes the old domain once as `abandoned` at the relay's observed count; and
4. emits no item under that domain after its closure.

Independently, the successor durably abandons and charges the inherited attempt,
then dispatches only under the incremented attempt and a distinct domain. There
is no ordering promise between the predecessor's closure and the successor's
items; their distinct domain labels are what make overlap unambiguous.

For abrupt owner death:

1. the relay ends with its owner without processing queued backlog;
2. no closure is emitted;
3. the successor does not reuse or close the old domain;
4. durable recovery decides whether the operation completed, is abandoned, or
   requires reconciliation; and
5. any replacement attempt uses a distinct committed attempt identity.

For recognized live authority loss with an executor in flight:

1. a Control ownership refusal or terminal stale-owner Store refusal recognizes
   the loss even before the supersession notification is delivered;
2. when the refusal occurs in the executor worker's progress callback, report
   that verdict to the coordinator that owns the relay;
3. stop projecting the old domain and end its relay without a closure;
4. do not terminate the effectful worker merely because ownership changed;
5. do not label its stream `abandoned` unless a retained terminal operation fact
   proves that disposition;
6. let fencing prevent the old owner from committing as current authority; and
7. let successor recovery reconcile the dispatched operation before any retry.

The live-result transaction and a solicited reconciliation are different
decisions. A stale predecessor can terminally consume the deterministic
live-result transaction ID with `stale_owner_epoch`; ADR 0006 then requires a
different binding under that ID to conflict forever. A current successor
therefore derives the retained-receipt reconciliation transaction from the
validated `reconciliation_query_id`, never from the predecessor's live-result
identity. The query already binds the current owner epoch and original job, so
the new identity neither permits a second executor attempt nor weakens receipt
validation.

A model retry presents the same staged request bytes and the same
`staged_request_digest`, as ADR 0010 requires, but it is a new recorded attempt.
Its result transaction therefore binds both that unchanged digest and the
recorded attempt. Exact re-presentation within one attempt keeps one stable
identity, while a successor retry after a terminal stale-owner non-commit uses
the new transaction ID ADR 0006 requires instead of colliding with the prior
attempt's immutable non-commit.

A superseded coordinator remains alive only while it owns evidence-producing
executor, cleanup, or fault work, or a stream that still owes its permitted
ending. It performs no new run work. Once those workers, pending facts, and
streams are settled, it stops normally so repeated succession does not retain
obsolete coordinator processes or Control monitors.

`stale_journal_version` alone is not owner loss. It may be a current-owner
version conflict, so it remains on the ordinary unretained-result path rather
than silently acquiring succession semantics.

`stale_owner_incarnation_id` has the same fail-closed meaning when a Store
returns it for an ordinary transaction. It is defensive normalization here, not
a separate live-succession ordering: a conforming succession increments the
epoch atomically with the incarnation change, and ADR 0006 compares epoch first,
so a predecessor in that ordering receives `stale_owner_epoch`. Store
conformance, rather than a synthetic runtime succession, proves the distinct
same-epoch incarnation refusal.

No closure or delta is durable. The missing-closure case therefore adds no
journal record. The durable operation, assistant message, receipt, attempt
abandonment, and run-terminal records remain the only recovery authority.

<a id="technical-adr-0014-alternatives"></a>
## Why the Alternatives Expand or Weaken the Boundary

Concept: [Alternatives](0014-stream-closure-at-owner-loss.md#concept-adr-0014-alternatives).

A durable solution needs more than writing `closure_pending`. If the owner sends
the transient item and dies before recording `closure_sent`, a successor can
duplicate it; if it records first and dies before sending, the item is omitted.
The protocol therefore also needs an idempotent closure identity at the sink or
an acknowledgement whose transaction is reconciled. That expands ADR 0006's
Store contract, session recovery, progress sink behavior, and compatibility
surface.

An independent relay cannot infer disposition. Giving it the candidate
disposition before durable retention lets it announce uncommitted truth; giving
it the disposition afterwards recreates the owner-death window. An `owner_lost`
disposition avoids the lie but changes ADR 0011's two-member public algebra and
still does not provide the exact terminal count.

A check-then-send fence is insufficient even when both operations query the
same Control process. The answer says only what was current when it was read; a
queued acquisition may change the owner before the later relay message. The
admission and send must share one serialization point.

Discarding every predecessor relay inside the serialized Control handoff would
remove the per-item round trip only by destroying information the decision must
preserve. A terminal model reply or executor receipt can already be durable
while its Store or `post_commit` result is delayed past the handoff. The
originating coordinator must still close that relay `complete` with the retained
producer count. A delivered live-model supersession notification likewise needs
the relay after the coordinator terminates and drains the model worker so it can
close `abandoned` truthfully. Killing either relay at handoff loses a closure
whose disposition is later known rather than fencing only stale progress.

Control also does not currently own the relay link or retain a relay registry.
`StreamRelay.discard/1` is an owner operation: it removes the caller's link,
terminates the relay, and waits for its death. Calling that function from Control
would leave the coordinator's link in place, so the relay's shutdown could also
terminate the evidence-producing coordinator. A registered relay state that
synchronously seals new items but preserves a later terminal close could avoid
that problem, but it is a new protocol with its own handoff, lifecycle, and
mutation evidence rather than the proposed discard.

Killing an executor worker can destroy the evidence needed to decide an effect
that may already have happened. It also violates the cancellation and
reconciliation ordering established by ADR 0009 and ADR 0012. Stream tidiness
does not outrank truthful effect accounting.

<a id="technical-adr-0014-consequences"></a>
## Compatibility, Evidence, and Rollback

Concept: [Consequences](0014-stream-closure-at-owner-loss.md#concept-adr-0014-consequences).

**Compatibility.** Closure item shape, domain derivation, sequence kinds,
counts, and dispositions do not change. The source and progress protocols are
unreleased. An embedder already has to tolerate a missing closure because the
transient plane may drop one, so this changes the producer liveness guarantee
rather than the consumer input algebra. The compatibility inventory must name
that exact distinction. The query-bound reconciliation transaction is internal
Store coordination; it changes no public query, receipt, event, or record
shape. The attempt-bound model-result transaction identity is likewise internal
Store coordination and changes neither the staged request digest nor its
provider-facing bytes.

**Fence cost.** `Control.project_progress/5` is one runtime-wide serialization
point for every model delta and executor progress item. It uses an
`:infinity`-bounded `GenServer.call`, and the executor invokes its progress
callback inline, so that worker waits while Control is occupied. The wait is
deliberate: a timeout or unreachable Control supplies no ownership verdict and
must not be normalized to `superseded_owner`. Adding a timeout would therefore
need a separate unavailable result whose branch projects nothing, closes
nothing, and does not mark the coordinator superseded. This decision keeps the
unbounded serialized fence because the simpler handoff-discard alternative
cannot preserve retained-fact and notified-model closures.

**Closure evidence.** M2 must lock separate, non-vacuous cases proving:

- ordinary complete and abandoned paths still emit one last closure with the
  correct count;
- a Store refusal of a model result emits no `complete` closure before the
  assistant message is durable;
- recognized live model supersession terminates and drains the old worker
  before it emits one `abandoned` closure, permits no later item under that
  domain, and gives the successor a distinct attempt domain;
- an earlier ownership fence that marks a model coordinator stale cannot
  suppress the later supersession notification's worker termination, drain,
  abandoned closure, relay ending, or coordinator reaping;
- a model error released after durable owner advancement but before notification
  cannot bypass the ownership fence to close the old domain `abandoned`; the
  successor owns the durable abandonment and retry decision;
- a complete model result that meets the stale-owner Store fence before the
  notification ends the predecessor normally without a closure, and the
  successor alone records abandonment and retries the same staged bytes under a
  new attempt-bound result transaction;
- a model result held after Store linearization while the successor reaches
  Control still closes its originating domain `complete` exactly once with its
  retained producer count, dispatches no replacement, and records no
  abandonment;
- a model result whose Control `post_commit` succeeds before ownership moves but
  whose reply is held until afterwards still closes that retained domain
  `complete`, and the settled predecessor is reaped;
- recognized live executor supersession after notification emits no false
  `abandoned` closure, permits no old progress after the plane ends, leaves the
  effectful worker alive until it returns, reaps the settled predecessor, and
  reconciles before replacement dispatch;
- a durable owner handoff held after linearization but before notification
  refuses old progress and a stale-epoch receipt closure, leaves the effectful
  worker alive, reaches successor reconciliation before any retry, and accepts
  a valid retained receipt under a query-bound reconciliation transaction even
  if the stale live-result transaction was already terminally refused;
- a progress-side Control refusal in that pre-notification window reaches the
  coordinator, ends the old relay without a closure, leaves the effectful worker
  alive to produce its receipt, emits no stale refused-progress diagnostic, and
  reaps the predecessor after settlement;
- an unavailable Control returns `runtime_unavailable` from per-item admission
  without inventing an owner-loss verdict or changing the real owner's standing;
- an unavailable Control returns `runtime_unavailable` from ordinary closure
  admission without inventing an owner-loss verdict or changing the real
  owner's standing;
- a model progress call held at the admission boundary until after durable
  ownership advancement projects no predecessor item, proving the owner check
  and relay send cannot be separated by the handoff;
- a malformed executor receipt released in that same pre-notification window is
  rejected without letting its local invalidity bypass the ownership-fenced
  close or authorize later stale-owner work, and the settled predecessor is
  reaped;
- an executor receipt held after Store linearization while the successor reaches
  Control remains durable and recoverable when the predecessor's delayed
  `post_commit` is refused as `superseded_owner`; the predecessor closes the old
  domain `complete` with the retained receipt count, records no stale refusal
  consequence, is reaped after settlement, and causes no retry;
- an executor receipt whose Control `post_commit` succeeds before handoff but
  whose reply reaches the predecessor afterwards still closes its originating
  domain `complete`, starts no stale refusal-accounting transaction, and causes
  no retry;
- a non-receipt executor answer after notified supersession emits no stale
  unproven-effect diagnostic or terminal transaction, leaves its effect worker
  alive until the answer arrives, and leaves reconciliation to the successor;
- a superseded coordinator remains alive while a cleanup disposition is pending
  even when it has no in-flight worker, stream, or fault hook, then is reaped
  once that pending cleanup is settled;
- abrupt owner death ends the relay ahead of queued backlog, leaks no relay, and
  fabricates no closure;
- abrupt model owner death in the full runtime gives the successor a distinct
  attempt domain and projects no late predecessor item or closure;
- a successor never emits a closure under the predecessor's domain; and
- a consumer seeing missing closure falls back to the durable record without a
  timeout or an inferred abandonment.

Mutation evidence must fail when model work is allowed to outlive recognized
supersession, when notified model closure is moved before worker termination
and drain, when a prior stale-owner boolean suppresses notified model cleanup,
when a model stream closes complete before its result commits,
when a model error bypasses the ownership-fenced close, when a retained model
reply or executor receipt is treated as uncommitted or its truthful close is
guarded by current ownership, when the successor reuses the predecessor's
attempt domain, when a stale model-result non-commit is treated as a generic
failure or a provider retry reuses its transaction ID, when a relay survives
its owner, when an unavailable progress fence is normalized to
`superseded_owner`, when an unavailable ordinary closure fence is normalized
to `superseded_owner`, when progress admission is split into check then send,
when a stale owner closes its executor domain
abandoned, when a malformed receipt bypasses the ownership-fenced close, when
an executor worker is killed merely to end its stream, when a progress-side
ownership refusal is not reported to the coordinator, when reconciliation
reuses the terminally refused live-result transaction identity, when a stale
coordinator records refusal accounting after a retained receipt, when an
admitted retained receipt is put through a second ownership-gated close, when a
stale non-receipt executor answer performs diagnostic or terminal work, when a
progress-side owner-loss verdict emits a refused-progress diagnostic, when
pending cleanup is ignored by the owner-loss reaper, when a settled superseded
coordinator is retained, or when a client treats missing closure as
abandonment.

The abrupt-death test must suspend the relay, queue items, kill the owner, and
prove the relay dies before projecting the backlog. The live tests must use the
full runtime rather than only the relay so that fencing, attempt advancement,
effect reconciliation, and successor domain derivation are exercised together.
The pre-notification case must hold the successor immediately after durable
owner advancement, release the old receipt before delivering that result, and
observe the old relay directly so waiting for the notification cannot hide a
fabricated closure.

**Rollback before closure.** Remove this decision and the corresponding M2
amendment only together with a durable, transferable, idempotent closure
protocol and its Store, recovery, consumer, fault-injection, migration, and
rollback evidence. Reinstating the absolute prose while retaining process-local
ownership is not a rollback; it recreates the contradiction.
