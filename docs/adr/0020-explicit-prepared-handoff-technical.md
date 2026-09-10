# 0020. Explicit prepared handoff — Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Explicit prepared handoff](0020-explicit-prepared-handoff.md#concept).

<a id="technical-adr-0020-context"></a>
## Source Evidence and Constraints

Concept: [Context](0020-explicit-prepared-handoff.md#concept-adr-0020-context).

The [review follow-up](../evidence/M2-ff17990-review-followup.md) records the
hidden selector, replacement drain, initial-preparer lifetime gap, unsupported
non-local participants, and insufficient ordering assertions. The relevant
implementation is the [facade](../../apps/loopex/lib/loopex.ex),
[capability](../../apps/loopex/lib/loopex/resume_activation.ex),
[coordinator](../../apps/loopex/lib/loopex/runtime/session_coordinator.ex), and
[interrupt handler](../../apps/loopex_cli/lib/interrupt.ex).

[ADR 0016](0016-configured-cancellation-observation-technical.md#technical-adr-0016-decision)
requires an opaque one-use capability, current-holder presentation, serialized
installation and transfer, and no recovered work during pending or uncertain
abort admission. Its cleanup formula, clock domains, job, receipt, genesis, and
executor ledger stay unchanged. ADR 0008 still owns durable owner recovery.

The inspected OTP 26.0 and 29.0.5 `gen_event` implementations invoke `init/1`
and prepend a successful handler without rejecting an identical handler ID.
Neither add nor swap alone supplies atomic duplicate refusal. The installation
must provide that property at the event manager, not infer it from an API name.

<a id="technical-adr-0020-decision"></a>
## Explicit Surface and State Transitions

Concept: [Decision](0020-explicit-prepared-handoff.md#concept-adr-0020-decision).

### Local surface

The additive entries are:

```text
Loopex.transfer_resume(activation, holder, {participant, correlation})
Loopex.ResumeActivation.transfer(activation, holder, {participant, correlation})
  -> :ok | {:error, reason} | {:unresolved, reason}
```

`activation` is the existing opaque `ResumeActivation.t()`. Holder and participant
are local PIDs; correlation is a fresh local reference for their prepared lifetime
relationship. These are transient local control values, not portable commands,
durable owner identities, or security credentials. They enter no journal, event,
snapshot, progress, diagnostic, or printable refusal payload.

The two-argument entries preserve their current behavior and PID domain and never
inspect ambient process state to choose another protocol. In the new entry,
invalid shape returns
`invalid_resume_handoff`; non-local participants return
`non_local_resume_participant`. Validate locality before local liveness checks or
monitor/state mutation. Current holder, receiving holder, participant, and
coordinator must be distinct on this path. Role aliasing returns
`invalid_resume_handoff`. Existing owner,
capability, current-caller, unspent-state, abandonment, and abort checks remain.

The following narrow OTP participant protocol is part of the overload's
documented contract. No behaviour, callback registry, dependency, durable schema,
or general participant framework is added. The CLI owns how its participant
observes the signal manager. Core owns only the prepared capability and explicit
lifetime relationship.

### Participant protocol

An embedder can implement the participant without importing CLI code or
inspecting the activation capability. This is an unreleased local contract, not
a distributed protocol or released compatibility promise.

P is calling holder, H receiving holder, G participant, and C coordinator.
N is supplied correlation. The facade creates fresh per-call Q; C creates fresh
prepare T and verdict V references. The facade forwards P's messages itself.

| Direction | Exact message |
| --- | --- |
| P to G | `{:loopex_prepared_transfer_pending, P, C, H, N, Q}` |
| C to G | `{:loopex_prepared_owner_prepare, C, H, N, Q, T}` |
| G to C | `{:loopex_prepared_transfer_guard_ready, G, H, N, Q, T}` |
| P to G | `{:loopex_prepared_owner_verdict, C, H, N, Q, V, verdict}` |
| G to C | `{:loopex_prepared_owner_verdict_ack, G, H, N, Q, V, verdict}` |
| G to C | `{:loopex_prepared_transfer_installer_lost, G, P, H, N, Q}` |
| C to G | `{:loopex_prepared_owner_discard, C, H, N, Q}` |
| C to G | `{:loopex_prepared_guard_released, C}` |

Verdict is exactly `:committed` or `{:refused, reason}`, with a bounded owner
refusal category. These messages are neither public events nor durable records.
G serves one relationship, knows P/H/N before the call, and monitors P/H before
H becomes reachable. Matching pending binds C/Q and installs a C monitor.
Prepare may arrive first from another sender; G sends ready only after both
matching messages and all its host dependencies are established.

On exact forwarded commit, G retires its preparer dependency and acknowledges.
On refusal it ends H, acknowledges refusal, and terminates. P's DOWN before
verdict acceptance ends H and sends installer-lost once C/Q are known; before
that binding it simply ends the candidate relationship. Forwarded verdict and
P's DOWN must be consumed in one state preserving same-sender ordering; G cannot
skip an earlier verdict to select a later DOWN.

Discard, C loss, or required host-dependency loss ends H; H loss ends G. These
actions do not retract an already submitted presentation. After handoff G stays
alive to observe C/H/host dependencies. Matching release retires that single-use
relationship without acting on a successor holder. Duplicate or mismatched
messages change nothing. The interface fixes these participant-facing messages,
not the facade's internal request transport or CLI-specific manager-arm handshake.

### One lifetime linearization

Let P be current holder, H receiving holder, G lifetime participant, and C
coordinator. These name roles, not fixed processes.

1. C monitors the initial preparer before the prepared capability becomes
   observable. Loss before any transfer authorization permanently abandons it.
   Another caller cannot rescue it by presenting the same value.
2. Before installation exposes H, G observes P and the exact signal manager,
   and H depends on G. G must end H even if H is blocked presenting a capability
   and C disappears. No spawn-before-guard window is permitted.
3. P requests explicit handoff. C validates its fences, binds one pending
   transfer to H, G, and correlation, and observes their lifetimes. G confirms
   the exact pending relationship. C revalidates and issues one exact
   authorization or definitive refusal. Concurrent transfer or activation cannot
   bypass the pending decision.
4. P forwards the authorization to G. Acceptance by G is the lifetime
   linearization. G retires its preparer dependency and acknowledges to C.
   Forwarding and the later preparer-exit signal share sender and receiver; that
   OTP signal ordering decides which wins. Independent monitor order at C is
   not a substitute.
5. C records H after the matching acknowledgement, replaces the old holder
   monitor, retains the participant dependency, and returns success. It never
   resets a later abort, abandonment, supersession, or spend to prepared state.

After authorization, P's DOWN at C alone cannot prove whether forwarding
occurred. C retains the pending decision until G supplies its result or the
relationship is lost. Otherwise the new preparer monitor would revoke a valid
transfer whose public reply was lost. Before authorization, preparer loss may
settle directly.

C handles the exchange asynchronously: retain the pending caller and return to
the receive loop, never wait inside a callback. Handoff is transient, not effect
authority. Activation separately passes current-owner and abort fences.

### Loss and uncertainty

| Observation | Consequence |
| --- | --- |
| Invalid request or definitive refusal before handoff | No transfer; live original holder retains only its existing authority. |
| Preparer loss before forwarding | End candidate holder; abandon original unspent capability. |
| Preparer loss after lifetime linearization | Preserve transferred lifetime even if public reply is lost. |
| Holder, participant, manager, or handler loss before handoff | End candidate relationship; no activation; preserve independent abort/owner fences. |
| Participant or owner loss after possible handoff, before proved acknowledgement | Surviving caller gets `unresolved`; end dependent holders and keep recovered work fenced, never claim proved non-transfer. |
| Holder/participant loss after acknowledged transfer | End dependent holder and abandon only still-prepared capability; activated work belongs to session. |
| Coordinator loss or supersession | End its dependent holders, including idle holders; durable recovery follows existing rules. |
| Late, duplicate, mismatched message | Change nothing; never refresh a lifetime or reverse a settled state. |

Reasons are bounded categories, never private capability values. Success proves
recorded handoff, not perpetual participant liveness. Ending a holder does not
withdraw a presentation already received by C. Learn any durable consequence
through the session surface; do not retry activation speculatively or treat
compensating abandonment as proof that activation never happened.

### Installation and observations

Claim one manager-local identity and install the handler in the same serialized
manager turn. `init/1` may own this atomic claim. Failed initialization releases
only its own claim; orderly termination releases the matching claim; manager
death destroys it. An incumbent refuses with `interrupt_already_installed`.
An unprotected `which_handlers` followed by add or swap is insufficient.

Duplicate refusal preserves incumbent attachment, holder, abort identity, and
backstop. Dispose only of the unsuccessful candidate's participants. Existing
`install/1` and `install/2` may retain their documented best-effort `:ok`;
`install_prepared/3` returns `:ok | {:error, reason} | {:unresolved, reason}`.
It preserves unresolved from the explicit transfer instead of converting it to
refusal. The command renders a bounded uncertainty result, leaves recovered work
fenced, preserves participant cleanup, and does not activate or retry installation
on that result. No callback replaces the Loopex handler or
keeps predecessor lists. No node-global lock spans a session call, handoff,
presentation, or holder drain.

Coordinate default-handler removal and signal coverage with successful initial
installation. Abort submission stays asynchronous and retains its configured
backstop. Handler removal releases its holder asynchronously; abrupt manager
loss is independently covered by G. Neither route proves a submitted mutation
failed.

Transfer, activation, and abandonment may wait without a deadline for correlated
owner results in callers or owned workers, never in C or the signal manager.
Read-only holder, configuration, and status observations use bounded waits and
report unavailable on expiry. A suspended live manager is not an absent one.
Attachment and installation mutate state: expired observation requires unresolved
handling and continued lifetime protection, not a false refusal. Existing
cancellation deadlines stay exact.

<a id="technical-adr-0020-alternatives"></a>
## Alternative Costs

Concept: [Alternatives](0020-explicit-prepared-handoff.md#concept-adr-0020-alternatives).

A CLI-only guard needs another explicit surface or private capability access to
observe idle coordinator death. Dynamic replacement retains presentation,
signal-coverage, abort-identity, installer-loss, and concurrent-drain obligations
for no production caller. Longer waits do not prove draining, and unbounded
lookups do not repair observation semantics. The selected overload exposes the
existing relationship while deleting replacement machinery.

<a id="technical-adr-0020-consequences"></a>
## Migration, Rollback, and Decisive Evidence

Concept: [Compatibility, delivery, and rollback](0020-explicit-prepared-handoff.md#concept-adr-0020-consequences).

Implement facade/capability documentation, coordinator handoff and preparer
monitor, CLI installation, embedding guidance, and tests together. Delete both
ends of the hidden selector, replacement handlers, predecessor state, global
drain lock, and replacement-only tests. Preserve event delivery, configured
cancellation, and accepted compatibility entries.

No persisted bytes or dependencies change. The overload is an unreleased embedded
public API over ADR 0016's non-serializable local capability. It adds no released
stability label or compatibility freeze. Prove ordinary two-argument compatibility
without narrowing its PID domain. Rollback
terminates transient command participants before restarting a coherent prior
composition. Never migrate live capability values or undo admitted activation or
abort. Existing Store and executor rollback procedures still apply.

Required behavioral evidence and selective mutants cover:

- both facade paths; no ambient selector; malformed/non-local refusal without
  coordinator death or state change on the new path; independent participant
  roles; prepared-install and command propagation of unresolved rather than refusal;
- an independent minimal participant using only the documented messages through
  the facade, including prepare-before-pending, refusal, loss, and release;
- preparer loss immediately after preparation and on each side of forwarding;
  permanent pre-handoff abandonment and post-handoff usability with lost reply;
- loss of every holder, guard, handler, exact manager, and coordinator before,
  during, and after handoff, including blocked presentation and idle holder;
- controlled authorization/acknowledgement delays, delayed success not earlier
  refusal, and explicit unresolved loss in the ambiguous interval;
- ordered abort, activation, supersession, and handoff; no dispatch behind a
  fence, no fence reset, one-use activation;
- concurrent real-event-manager installation, with/without default handler:
  exactly one Loopex handler, prepared duplicate refusal, preserved incumbent
  stop state, no orphaned candidate holder;
- signal/backstop operation during presentation; ordinary removal and manager
  loss without replacement;
- bounded read-only observation followed by a delayed mutation's actual result;
  short silence is never a drain or non-commit verdict; and
- mutants deleting each lifetime dependency, accepting stale correlation,
  overriding forwarded authorization with preparer DOWN, clearing abort,
  acknowledging before recording, treating uncertainty as refusal, or allowing
  duplicate installation. Replace reachable lexical assertions with behavior.

These are proposal obligations, not newly locked selectors or claims of executed
proof. Messages outside the participant contract remain private. Changing Closed M2
locked evidence requires its separate additive gate-generation transaction;
this ADR changes no gate or lifecycle record.
