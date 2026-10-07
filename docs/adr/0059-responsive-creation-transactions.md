<a id="concept"></a>
## Concept

Technical depth: [Responsive creation transaction mechanics](0059-responsive-creation-transactions-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-07
- **Decision owner:** Maintainer
- **Amends:** [ADR 0055](0055-remote-session-creation-options.md#concept)'s worker Store-write prohibition and creation recovery mechanics, and [ADR 0006](0006-store-transaction-and-owner-epoch.md#concept)'s runtime-control transaction catalogue, only as specified here. Preserve ADR 0055's creation grammar, captured configuration, one-slot admission and live cleanup bounds, and [ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept)'s host-exclusive placement boundary.

<a id="concept-adr-0059-purpose"></a>
### Purpose and evidence

Technical depth: [Current path and accepted constraints](0059-responsive-creation-transactions-technical.md#technical-adr-0059-purpose).

An in-progress create must leave Control able to handle stop, status and the
specified overlapping-create refusals through its terminal disposition. The
current create transaction calls the Store synchronously from Control. A held
Store call therefore prevents Control from handling those messages. Moving only
preparation into a worker leaves this transaction wait unresolved.

Accepted ADR 0055 also says no worker writes Store. A separate process invoking
the Store adapter would be a worker, even if named a carrier. Recommend an
explicit narrow exception rather than treating the same operation under a new
name as already authorized. The retained canonical candidate must also survive
Control, runtime-root and VM loss. A volatile fence, stable transaction ID or
empty Store read cannot recover an unlinearized prepared candidate or make a
delayed Store call inadmissible.

<a id="concept-adr-0059-decision"></a>
### Proposed carrier and Store-owned custody

Technical depth: [Exact proposal, mechanical carrier and placement](0059-responsive-creation-transactions-technical.md#technical-adr-0059-decision).

Preparation workers never write Store. Control may authorize one owned
mechanical Store transaction carrier for creation startup/recovery or the active
creation. Before permitting its single Store call, Control retains the exact
canonical proposal,
immutable OwnerLane binding and runtime-domain fence. The carrier can present
only those bytes to the existing Store callback and return its outcome. It
cannot prepare or replace a proposal, choose another transaction, retry,
update the authoritative lane, publish a durable fact or activate a session.
Control remains the sole serial owner of those decisions.

Retain one pre-session slot through preparation, transaction resolution,
retirement and terminal disposition. Each carrier is monitored and owned before
its permit. At most one carrier is live for that slot; there is no extra create
queue, duplicate waiter list or independent transaction owner. Exact unknown
resolution may authorize another single call only under the original binding,
the rules below and remaining original allowance.

Recommend Store-owned custody: a private runtime creation head, a durable
complete-candidate reservation, three closed mutation families for claim,
reservation and cancellation/close, and one optional bounded
`Store.creation_recovery/2` read. A fresh Control first claims a generation under
the host's exclusive logical Store namespace/runtime-ID placement. That claim
precedes every fresh preparation. Only after successful preparation is joined
does Control reserve its complete original candidate. Final creation is
ineligible until that reservation is durable. Reservation and final creation
create no independent worker authority; Control still selects every permit.

The host must already have quiesced or positively established the prior Control
ended before replacement. This is ADR 0008's existing trusted placement
responsibility. The selected native Store handle and runtime ID bind the new
private Control to that placement; no client metadata, returned generation,
UUID or new namespace-verification API proves the external fact. Local
supervision supplies only its own original Control's join evidence. A generation
claim never permits stealing a live placement or activates historical work.

Store retains one active candidate per runtime and exact command history. A
successor claim preserves an already-reserved candidate and permanently makes
late old-generation reservations ineligible. Recovery cancels/closes any still
reserved original command atomically, rather than issuing a new final-create
permit for it. Close records the exact original final transaction's terminal
non-commit before releasing the durable slot. If the original final create won
first, recovery returns that retained committed history. Either result activates
nothing. Once a command/reservation/final binding is retained, changed canonical
bytes cannot reuse its identity. A command whose reservation never linearized
may be fresh only after the completed successor barrier permanently excludes
its old reserve delivery; absence alone is insufficient. Its new generation
uses a distinct reservation identity, never changed bytes under the old one.

Add the closed observable refusal `creation_cancelled` in the existing native
error and remote refused/`no_activation` envelopes, with no session ID. Proven
cancellation is not Store unavailability. Later identical authored replay
returns its retained cancellation without preparation; changed authored input
conflicts. The command-scoped private read retains the original authored capture
needed for that comparison. Both generation manifests, schemas, vectors,
independent Node consumers and replay readers must qualify this added reason;
this proposal authorizes none of their implementation yet.

The current complete final-create canonical recipe and command/transaction ID
stay unchanged. Its first presentation additionally requires the exact durable
reservation. Known current-format histories still resolve their exact original
bytes before new eligibility; that does not authorize an unreserved new create.
No superseded decoder or unreserved unknown-create fallback is retained.

While this authored slot is held, both existing native Control create routes
use one shared admission gate before any candidate reconstruction, Store
freshness/provenance lookup or OwnerLane operation. After existing authority
and pure syntax checks, native default/implicit and complete-genesis creates
receive existing `creation_in_progress` with `no_activation`, including an
exact same-binding retry. They cannot bypass the slot. Outside occupation,
both native routes also use the current generation and exact reservation before
final creation, with the same single-slot/carrier custody. Existing result
envelope shapes remain, with the explicit additional cancellation reason above;
no new native result envelope is added.

<a id="concept-adr-0059-serviceability"></a>
### Serviceability and limits

Technical depth: [Nonblocking intake and original bounds](0059-responsive-creation-transactions-technical.md#technical-adr-0059-serviceability).

Control handles stop, status and overlapping creates without waiting for the
creation Store callback. Distinct and identical overlapping requests receive
`creation_in_progress`; changed authored input under the same command receives
`runtime_command_conflict`, with no Store lookup or replacement work. Existing
ready unrelated session routes remain usable. While the authored slot is held,
Store-dependent Control reads and resume return their existing unavailable
results immediately, without a Store call, read worker, retained reply or
waiting queue. This deliberately reduces read availability during outstanding
creation work, even when the Store itself could answer; it preserves responsive
intake without adding asynchronous read capacity. Store-dependent operations
outside this interval retain their existing behavior.

Another already-running session's provider-dispatch request also receives its
existing unavailable-proof refusal if it needs a Store read while the slot is
held. No provider permit or claimed authority proof is manufactured. Optional
post-commit spent-attempt retirement skips its Store read, retains the complete
spent map and acknowledges an otherwise valid committed receipt. Already-issued
work and ready routes remain under their existing contracts. This is an
explicit availability cost of the proposed immediate policy, not a promise
that unrelated Store-dependent work completes or that mailbox scheduling takes
zero time.

The original 60,000 ms work cutoff includes reads, preparation, transaction
presentation and any permitted exact resolution. Carrier start does not renew
it. Preserve the captured cleanup grace, the original cleanup episode and
existing observation cutoff. Startup or an explicitly new recovery invocation
has its own once-captured 60,000 ms work cutoff and the same host-captured
cleanup grace, with at most two fresh generation-CAS candidates. It does not
translate an old VM's monotonic instant, renew a live command's allowance or
activate a recovered command. There is no automatic retry episode. Failed
recovery leaves Control alive with creation unavailable; another episode
requires an explicitly host-started replacement after its old placement ended,
not repeated create calls or a new public recovery API. Dispatcher readiness
and safe status/stop remain independent. Missing recovery capability, unproved
placement or exhausted counter headroom refuses
creation without fallback. Reservations are measured for one complete bounded
recovery reply before admission under the existing 1,048,576-byte mutation
ceiling. Reserve enough counter headroom for reservation and terminal close;
neither generation nor domain version wraps or resets. Successful creation
requires preparation cleanup, the matching terminal Store outcome and exact
original carrier joins. Missing
proof keeps admission fenced and prevents activation.

<a id="concept-adr-0059-recovery"></a>
### Cancellation and durable truth

Technical depth: [State transitions and unknown recovery](0059-responsive-creation-transactions-technical.md#technical-adr-0059-recovery).

Before a reservation permit, joined cancellation establishes no candidate
dispatch; generation-claim uncertainty remains separately fenced. After any
permit, carrier or caller death does not cancel a queued or in-flight Store
mutation. A live owner resolves the exact original transaction within its
original allowance. Lost or unproved outcome is `commit_unknown`, never a
non-commit or fresh-create opportunity.

After owner loss, the successor's generation CAS can safely supersede an
unlinearized old claim/reservation: either old reservation wins and its complete
candidate is preserved, or the successor claim wins and all old reservation
delivery becomes permanently stale. Only a matching post-claim atomic read
with no active candidate permits fresh preparation. This is an explicit new
creation-domain recovery rule, not a general unknown-fence bypass. Already
reserved candidates remain fenced until their exact original final result or
atomic cancellation/close is terminal. Stop after reservation selects close,
never a new activation. Close cannot rewrite a committed result, discard an
unknown or reopen a closed command.

A matching committed outcome received after stop, expiry or owner replacement
does not activate a session. Its durable create history remains historical
truth and resolves only the original transaction. Store actors and adapter
resources retain their existing custody, which may be outside the runtime.
Joining the carrier proves that actor stopped; it does not prove cancellation
or termination of the Store itself.

<a id="concept-adr-0059-impact"></a>
### Alternatives, compatibility and rollback

Technical depth: [Scope and qualification](0059-responsive-creation-transactions-technical.md#technical-adr-0059-impact).

The alternative keeps all Store calls in Control and narrows serviceability to
the preparation period, excluding Store transaction waits. That permits held
Store calls to stall stop/status and overlap dispositions through terminal
creation. It removes part of ADR 0055's accepted behavior and requires an
explicit amendment plus corresponding proof changes. It is not selected.

An alternative host-owned durable custody port could retain the complete
candidate before each Store permit and recover it after VM loss. It also needs
an atomic host retention/delivery barrier proving old queued Store requests
cannot arrive after a clean disposition. Root memory or carrier joins alone
are insufficient. Every embedding host would acquire a second durable recovery
system, and missing custody or delivery proof could block creation indefinitely.
That viable option is not selected; Store-owned custody keeps recovery in the
existing authoritative Store.

The recommendation adds private persistent head/reservation/close contracts,
the optional recovery callback and corresponding Local replay and complete
backup/restore obligations. It adds no host custody port, public pending-candidate
DTO or generic transaction framework. Other workers and session mutation paths
acquire no permission.
No direct Local GenServer message or adapter-specific asynchronous bypass is
allowed. Only current contracts are maintained before 1.0.

Qualification must hold the actual Store transaction across stop/status and all
three overlap branches, and inject Control/carrier loss and stale completion
before permit, after possible dispatch and after durable commit. Preserve
unknown/replay and original deadline/cleanup controls. Exercise both native
create gates, repeated unavailable read intake, provider proof refusal and
post-commit acknowledgement without spent-map retirement. This proposal supplies
source evidence, not those results. Add both claim/reservation delivery orders,
delayed final-create versus close, complete VM loss, changed defaults and exact
capture collisions, reply-cap/headroom edges and current-format restore of
pending/closed custody. Rollback stops new affected creation, joins invocation
actors and preserves all new records and exact unknown bindings. A build that
cannot read this current custody format cannot safely open that Store; no
destructive rollback or old-format migration is selected. Restoring a
synchronous path does not qualify the responsive behavior. Acceptance binds
this pair before dependent implementation; ADR 0055 acceptance alone does not
authorize these new contracts.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
