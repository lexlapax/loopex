<a id="concept"></a>
## Concept

Technical depth: [Collaboration mechanics](0033-collaboration-controller-lease-and-takeover-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; the core keeps the vision §11.6 rule that it mandates no controller lease
- **Prerequisite for:** M5 outcomes 3 and 5, accepted before any admission check is
  written — that is, before M5's workstream 4

<a id="concept-adr-0033-decision"></a>
### Context and Decision

Once several client processes can attach to one live session, two of them can
try to drive it. The core serializes every durably admitted command and does
not care which client sent it, so without a rule above the core two terminals
would interleave prompts, steers and aborts into one run and each would see
the other's work as its own. The vision assigns that rule to the reference
daemon: one controller, many observers, stale-controller fencing and crash
takeover, none of it in core semantics, and a read-only attachment never
acquiring command authority.

Decide the rule. Each daemon-owned session has at most one controller at a
time, held under a lease the daemon owns and keeps in its own memory for the
daemon process's lifetime, never in the session journal or any durable
record. Every other attachment is an observer: it receives the same snapshot
and events and may not admit a command. For an existing session, the daemon
admits a mutation only when the sending connection is the current holder,
its supplied writer epoch matches, the lease is held and unexpired, and the
connection has a live attachment for its pinned session. Attachments carry no
controller capability: the lease is the only controller role, and any live
attachment satisfies the liveness condition. The daemon checks those facts together
before core admission and serializes that handoff with lease changes; an
observer cannot reuse an epoch it learned from a result or status.
`session.create` is the one exception because no session lease exists yet:
it creates an uncontrolled session, and control over it is never implicit.

Attach and acquire are independent of each other and their order is not
fixed. A connection may acquire control of any session that durably exists —
which the daemon establishes by asking core its read-only existence query, not
by attaching or resuming to find out — by session ID, before or after it
attaches to that session; what is fixed is
that no existing-session core mutation is admitted until the lease is held by the
sending connection, its epoch matches, and — with the single exception of
`session.resume` on a verified dormant session — that connection holds a
live attachment for the pinned session. So a newly created session is driven by
attaching and acquiring in either order and then sending the first command
with the granted epoch, and a known dormant session is driven by acquiring
by ID, resuming with the granted epoch and attaching. A
controller renews its lease while it lives and releases it early only by
sending `session.release_control` and having it succeed. Release checks the
holder, epoch, held state and unexpired term but requires no attachment, so a
controller can relinquish a dormant session after attach refuses; a lease that is not
renewed expires. Nothing about how the connection ended shortens the term,
because over a Unix-domain socket the daemon cannot tell a polite close from a
killed client — both are EOF — so only a message the client actually sent can
mean "I am done". Core's non-prepared owner-succession cut does not end the
daemon connection: it invalidates that session's attachment and sends
`detached`, while the cut itself leaves the exact lease holder, epoch and
deadline unchanged.
The holder must reattach before another mutation can pass the live-attachment
gate; it may still release without an attachment. A mutation crossing the gate
holds a candidate renewal at that gate instant. Accepted or outcome-unknown
admission commits it; a proved pre-admission succession loss or other refusal
discards it. Thus a controller whose own accepted `session.resume` caused the
cut renews normally, while another actor's succession and a refused resume do
not move its deadline. Takeover is explicit: while
the lease owner remains live, an observer asks for control and receives it only
when the lease is released or expired. If the lease owner itself fails, a later
acquisition starts no fresh owner until the exact dead-owner pop,
classification acknowledgement and
terminal holder-close or correlated-refusal settlement complete. Its first
grant additionally waits until every retained predecessor ticket and retirement
completion settles. Every grant mints a new writer epoch before
the new controller's first command can be admitted, so a controller that was killed mid-run and
comes back late is fenced by its stale epoch. The writer epoch is an opaque
value minted fresh for every grant and never reused, so a stale epoch from
any earlier tenure, including one issued before the lease owner or the whole
daemon restarted, never matches. After a daemon restart every session is
uncontrolled and every earlier connection is gone with the old socket;
nothing about control survives the daemon that granted it, while session
truth lives in the journal exactly as before. Cancellation crosses processes
because the core owns dispatch: the current controller's `session.abort`
cancels work that an earlier controller's command dispatched, with the
truthful cleanup outcome the core already commits.

Nothing but the lease grants control. No client content, model output,
interaction answer, metadata field or attachment order confers it, and the
daemon's own configuration may narrow who may take over; it cannot widen what
the host's policy allows a command to do. The proposed lease terms are exact
and are bound at acceptance: a thirty-second lease renewed every ten seconds,
takeover eligible at the live daemon's steady-clock expiry, and immediate
release only on a successful explicit release. Expiry and an unresolved
admission meet on one
rule, so neither promise is quietly broken by the other: a mutation whose
holder check completed before the deadline settles under its lease even if the
deadline passes while core is still deciding; at the deadline the holder gains
nothing further and every new mutation of its own refuses; and a takeover becomes
eligible at the deadline but is granted only once those in-flight mutations
have resolved. That adds no grace, because the expired holder can only finish
what it had already begun. Runtime-Control exclusion between two daemons on one
state root uses the shared crash-reclaimable host placement lock accepted ADR
0008 requires; the local Store's unchanged writer marker remains physical
Store-writer exclusion.

One fixed admission relay makes that ordering survive a lease owner's death
and gives shutdown one cut. Every post-initialize method request linearizes
there. The eight
lease-authorized core mutations, `session.create` and `session.attach` also
take retained tickets: each connection first installs a bounded request-slot
row at the relay. A lease owner promotes an ordinary mutation; the connection
registry first binds any activation or attachment reservation for create,
activation-capable resume and attach, then promotes the exact primary or records
an exact duplicate as a waiter. The relay starts each primary's monitored core
task **before** it acknowledges promotion; a waiter starts no task. Attach's task
uses the connection pid as an explicit stable holder, so relay execution does
not transfer attachment lifetime to the task. A relay cut acknowledges as
soon as it closes admission; calls admitted before it may finish inside the
separate bounded wait, whose fixed `admission_wait_ms` candidate value is
selected from the maximum 16,384-origin/512-connection witness and recorded with
its closure conditions; pending lightweight permits are cancelled at that
deadline, as are unpromoted ticket rows; executing non-lease calls remain tracked to result or connection
teardown, and executing lease calls receive their exact shutdown disposition;
every call after the cut refuses. Any frozen pre-cut permit may claim before the
shared admission deadline, but only acquisition may start an owner. Immediately
before core quiesce the relay enters `quiescing(drain_id)`; after successful
quiesce a teardown-bounded seal preserves real results and explicitly abandons
the remaining unresolved ticket IDs before teardown. At most 512 provisional
(including aborting), live-or-closing accepted slots times 32 request rows bound
the relay to 16,384 origins and no more primary tasks. At the admission deadline
a lease-operation barrier rejects or ends every uncompleted start, mirror and
release-settlement operation; after connections close, a second mailbox barrier freezes the
remaining idle or granted owner set that teardown sweeps, so no owner or routing
mirror appears behind it. Relay
loss is daemon-fatal because no process may guess what its missing ticket set
contained.

A lease-owner failure remains session-scoped in every owner state. The linked
daemon owner serializes every exact mirror install, clear and dead-owner pop into the connection
registry on the lease owner's behalf; the lease owner never writes that mirror
directly. Signal ordering therefore puts a sent install ahead of that owner's
later exit. After resolving that operation, the daemon atomically pops only the
dead pid/incarnation's row and returns the exact holder it must close before a
successor install may run; a stale pop cannot erase the successor. The relay
also classifies every acquire, release or lease-authorized mutation that had no
visible result. An origin on the returned holder receives only the uncorrelated
`control_owner_lost` close. Any other claimed acquire or release, or a pending
or queued mutation claimed before promotion, receives the correlated
request-shaped refusal and its connection stays usable. A promoted
mutation remains relay-owned until its real core result or shutdown settlement,
while a mutation that had not reached core starts no task. A free or retiring
owner with no such operation has nobody to notify. In every case successor
start waits for mirror pop, classification acknowledgement and terminal
holder-close or correlated-refusal settlement. Its first grant additionally
waits for every predecessor ticket and retirement completion; the relay then
releases the bounded transient rows.

Starting-waiting-pop, starting, live and retiring lease-owner rows share one
512-slot count. A
retiring predecessor keeps its slot until exact process exit; a same-session
successor is queued and receives that slot only when the daemon consumes the
exit, while an unrelated 513th owner is refused. A holder-changing acquisition
is provisional until its permit result wins: connection loss first clears the
provisional route and makes no grant, while result first promotes the exact
route even when the connection closes before the reply.

**Alternatives rejected.** Putting the lease in core was rejected because the
vision keeps collaboration policy above core and another host may choose a
different rule. Last-writer-wins without an epoch was rejected because a
killed controller's late command would interleave with its successor's. A
lease with no expiry was rejected because a crashed controller would hold the
session forever. A durable lease record was rejected because after a daemon
restart every connection is gone with its socket and admission already
requires the holder connection, so durability could only preserve a counter
nothing needs. A counter-based epoch scoped to the daemon incarnation was
rejected on 2026-09-14 because a lease-owner restart under the same
incarnation would mint values already issued. Restarting a failed lease owner
beneath live sockets was rejected on 2026-09-20 because it would claim a lease
record it cannot reconstruct. The fixed admission relay retains pending,
waiting and promoted request origins, including tickets for calls it started,
but never the lease; its loss is daemon-fatal rather
than reconstructed, so the ticket ledger needs no durable record.

**Implementation and milestone-closure evidence.** Outcome 5's integrated
controller-kill and takeover workflow waits on this decision as well as Outcome
3. This is a trust claim, so its class is
negative tests on real processes plus a security reading of the admission
path: every refusal — stale epoch, copied current epoch, non-holder
connection, released lease, expired lease, holder without a live attachment,
observer abort — proved before core
admission and before any session write, a controller killed mid-run fenced
after takeover, a lease owner killed before and after a mutation is promoted
taking neither the daemon nor any other session down — an unpromoted operation
receives exactly its classified refusal or holder close and starts no core task,
a promoted task settles to its real result, its observers stay, and the
replacement's grant is held until both populations and the owner-loss
notification barrier settle — and a daemon
restart leaving every session uncontrolled with every earlier epoch refused.
A non-prepared core succession additionally proves `detached` leaves both
daemon connections open, preserves the controller's exact holder, epoch and
deadline when another actor caused the cut, orders an already-routed mutation
to its real result, `admission_unknown`, or `detached` then
`control_not_held`, refuses later mutation until reattach, and permits another connection
to take over only after explicit release or expiry. No durable record changes, so no migration or
rollback evidence is owed.

Technical depth: [Contract and evidence](0033-collaboration-controller-lease-and-takeover-technical.md#technical-adr-0033-decision).

<a id="concept-adr-0033-consequences"></a>
### Consequences, Compatibility and Rollback

Two people, or one person and one automation, can watch one session while
exactly one of them drives it, and a crashed driver's terminal cannot
interfere after someone else has taken over. Core semantics are unchanged:
admission, ordering, durability, fencing by session epoch and receipts stay
exactly as accepted, and another host may implement a different collaboration
policy above the same core. The wire gains lease methods and a writer-epoch
field in generation 2 only. Creating a session grants no command authority
until control is acquired. Because the lease is not durable, a daemon restart
is a clean slate for control and for nothing else: the first client to
acquire after restart becomes the controller.

Rollback is the M4 foreground server, whose single connection is its own
controller by construction; the lease is daemon memory and is simply absent
without a daemon.

Technical depth: [Compatibility mechanics](0033-collaboration-controller-lease-and-takeover-technical.md#technical-adr-0033-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m5-acceptance-2026-09-21) | candidate `1e1b33bfbf83953463e6abcdaebd52dc12735d8f`; concept `sha256:920d2dff8dbf37f1f341ef6885ff19fb85f430f2908d2b99af0d7c6681482018`; technical `sha256:08aa94e95e15ac1a83a54b353a79fb71722599f9abf03db3522b4067daad1ed3` |
