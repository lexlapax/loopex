# 0014. Stream closure at owner loss

<a id="concept"></a>
## Concept

Technical depth: [Closure ownership, failure windows, and evidence](0014-stream-closure-at-owner-loss-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-29
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` closure
- **Supersedes:** 0011

The supersession is limited to two ADR 0011 promises when the transient plane's
owner dies or loses authority before it can truthfully close the domain: that
every domain the coordinator opens emits exactly one closure, and that every
closure precedes publication of the attempt outcome. A terminal operation fact
can commit before handoff while its Store or post-commit reply reaches the
originating coordinator afterwards; durable outbox delivery may then precede
the retained fact's truthful transient closure. ADR 0006 governs durable commit,
current-cache mutation, durable public and outbox publication, and dispatch.
The vision separates transient progress as a distinct truth plane, so emitting
that originating closure narrows no ADR 0006 clause. The stale coordinator still
cannot mutate the current cache, publish a durable public event or outbox fact,
dispatch, emit new progress, retain refusal accounting, or perform later run
work. ADR 0011's domain identity, sequence, count, last-item, retry,
durable-fallback, event-binding validation and refusal, and consumer rules also
remain in force.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0014-context"></a>
## Context

ADR 0011 gives each model or executor attempt one transient stream domain. It
requires the coordinator to emit one final closure for every domain it opens,
including an abandoned domain. It also says the transient plane ends with its
owner and that a consumer which receives no closure has an incomplete view and
must fall back to durable truth.

Those statements conflict when the owner dies between a durable commit and the
transient closure that reports it. A different process cannot know whether the
dead owner emitted a closure before dying, which count it stated, or whether a
reply or receipt committed immediately before death. Emitting `abandoned` can
therefore contradict the durable record; emitting `complete` can invent a
record that never committed; re-emitting either can duplicate a closure already
sent.

The same uncertainty exists when a live owner loses authority while an executor
effect remains in flight. That loss can be recognized by the runtime's ownership
fence or by a Store refusal of the stale owner before its supersession
notification is delivered. Neither observation proves that the effect did not
happen. By contrast, a live model owner can terminate and drain a model worker
after it receives the handoff because model work has no host effect to
reconcile.

Technical depth: [The unowned interval](0014-stream-closure-at-owner-loss-technical.md#technical-adr-0014-context).

<a id="concept-adr-0014-decision"></a>
## Decision

**A stream closure is owed only while an authoritative plane owner can state it
truthfully.** Transient progress and any closure that lacks a retained terminal
fact cross the plane only through the runtime's serialized ownership fence. A
handoff therefore either follows that emission or refuses it; it cannot move
between a separate ownership check and send. Recognized live model supersession
is the deliberate second admission rule: after the old model worker is
terminated and drained, the old coordinator may close that model domain
directly as `abandoned` even though the handoff has already moved authority.

When the owner reaches a successful, refused, failed, cancelled, or retried
attempt terminal while authoritative, it still emits exactly one content-free
closure as the final item of that domain. A retained reply, receipt, or other
terminal operation fact may also make its originating domain's disposition and
count truthful even if ownership moves before the closure is emitted. A failure
or ownership refusal before either condition follows the owner-loss rule below.

A live model owner that receives the supersession notification terminates and
drains its model worker, then closes that domain once as `abandoned`. An earlier
Control or Store fence may already have marked it stale, but cannot suppress
that later notified cleanup. Before the notification, an unretained model result
that meets the stale-owner Store fence ends the relay without a closure; the
successor owns durable abandonment and retry. The successor may already be
advancing its distinct replacement attempt; ADR 0011 orders items inside one
domain and promises no ordering across domains.

Abrupt owner death ends every relay linked to that owner without emitting a
closure or draining queued transient items. A successor never emits a closure
for the predecessor's domain. The missing closure means only that the transient
view is incomplete; the consumer falls back to the durable record without
starting a timeout or inferring abandonment.

A live owner that loses authority while an executor effect is in flight likewise
ends the old transient plane without a closure unless a retained terminal
operation fact already makes the disposition and count truthful. Recognition
does not depend on receipt of a supersession notification: a runtime ownership
fence or a terminal stale-owner Store refusal is sufficient. The owner does not
kill the effectful worker merely to obtain a tidy stream ending. The successor
reconciles the durable operation under the current reconciliation query rather
than reusing the stale live-result transaction, and opens a different domain for
any new attempt it is authorized to dispatch. The superseded coordinator stays
alive only while effect, cleanup, or fault evidence may still arrive; once that
work and its streams are settled, it is reaped.

Neither a relay, a successor, nor an independent monitor fabricates the dead or
superseded owner's disposition or count. Exact closure across owner loss would
require durable, transferable closure ownership and an idempotent emission
protocol; this decision does not add that persistence boundary.

Technical depth: [Normative state and ordering](0014-stream-closure-at-owner-loss-technical.md#technical-adr-0014-decision).

<a id="concept-adr-0014-alternatives"></a>
## Alternatives

**Persist closure ownership and emission state.** A durable closure intent,
transferable ownership, and idempotent emission identity can let a successor
finish the predecessor's obligation. This changes the Store schema, recovery
transactions, progress protocol, and every consumer's duplicate handling. It is
the conforming alternative if exact closure across crashes becomes an operator
requirement, but it is not taken in `M2`.

**Check authority and then emit in two operations.** The successor can begin a
handoff between the answer and the send, admitting a stale item or fabricated
closure. This is the race this decision closes and is not taken.

**Discard every predecessor relay inside Control's ownership handoff.** This
would make the handoff itself the one fence and remove Control from the per-item
progress path. It fails because a reply or receipt may already be durable while
its Store or post-commit result is delayed past the handoff. Killing that relay
would erase the truthful `complete` closure which the retained terminal fact
still proves. It would also erase the relay a notified live model owner closes
only after terminating and draining its worker. Keeping the relay alive but
sealed against new items is a different relay-state protocol, not this discard
alternative, and is not added in `M2`.

**Let a monitor emit `abandoned`.** A monitor knows that a process died, not
whether its reply or receipt committed immediately beforehand. This can publish
a false terminal disposition and is not taken.

**Let the successor emit the predecessor's closure.** The successor does not
know whether the predecessor already emitted it and does not own the
predecessor's transient count. This risks duplicate or fabricated closures and
is not taken.

**Kill every worker and close every live domain on supersession.** This is sound
for model work and unsound for an executor effect whose truth may need
reconciliation. It is not taken as a general rule.

Technical depth: [Why the alternatives expand or weaken the boundary](0014-stream-closure-at-owner-loss-technical.md#technical-adr-0014-alternatives).

<a id="concept-adr-0014-consequences"></a>
## Consequences

An operator normally receives one exact closure per domain. After abrupt owner
loss, or live authority loss during an unproved executor effect, the operator
may instead see the stream stop without a closure and then learns the result
from durable recovery. No transient item falsely calls an effect abandoned or
complete, including in the interval before the predecessor processes its
supersession notification.

The payload algebra does not change. Existing consumers already treat missing
closure as an incomplete view and fall back to the durable record, so no timeout,
wire migration, journal migration, or released compatibility promise is added.
The producer liveness guarantee is narrower on an unreleased surface and must be
stated in the M2 plan amendment and compatibility inventory before closure.
The reconciliation record gains an internal query-bound transaction identity.
A model-result transaction likewise binds its recorded attempt as well as the
unchanged staged-request digest, so ADR 0006's required new transaction after a
proved non-commit does not collide with ADR 0010's same-bytes provider retry.
Neither identity is a public protocol field or a Store-schema migration.

The ownership fence is a runtime-wide serialization point in Control. Each
model delta and executor progress item waits on an unbounded local Control call
before the relay receives it; an executor worker therefore blocks in its
progress callback while Control is busy. The call deliberately has no timeout:
scheduling delay or temporary unavailability is not an ownership-loss verdict,
so a timeout branch could not lawfully be read as supersession. Removing that
hot-path cost requires a separate protocol which seals new relay items at the
handoff while preserving the later retained-fact and notified-model closures.

`M2` does not close until this decision carries recorded acceptance and the
amended gate independently protects ordinary closure, live model supersession,
live executor supersession both after notification and at the ownership fence,
abrupt owner loss, and consumer fallback. Rollback before closure removes this
decision and implements the durable transferable protocol above; deleting the
owner-loss cases alone is not a rollback.

Technical depth: [Compatibility, evidence, and rollback](0014-stream-closure-at-owner-loss-technical.md#technical-adr-0014-consequences).

## Links

- [ADR 0011 — Session input algebra and streaming progress](0011-session-input-algebra-and-streaming.md#concept)
- [ADR 0006 — Store transaction contract and owner epoch](0006-store-transaction-and-owner-epoch.md#concept)
- [M2 plan](../plans/M2.md#concept)
- [M2 recorded limitations](../evidence/M2-recorded-limitations.md)
