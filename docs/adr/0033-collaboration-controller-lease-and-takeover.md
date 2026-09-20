<a id="concept"></a>
## Concept

Technical depth: [Collaboration mechanics](0033-collaboration-controller-lease-and-takeover-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; the core keeps the vision §11.6 rule that it mandates no controller lease
- **Prerequisite for:** M5 Outcome 3, accepted before any admission check is
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
attachment has command capability. The daemon checks those facts together
before core admission and serializes that handoff with lease changes; an
observer cannot reuse an epoch it learned from a result or status.
`session.create` is the one exception because no session lease exists yet:
it creates an uncontrolled session, and control over it is never implicit.

Attach and acquire are independent of each other and their order is not
fixed. A connection may acquire control of any session that durably exists —
which the daemon establishes by asking core its read-only existence query, not
by attaching or resuming to find out — by session ID, before or after it
attaches to that session; what is fixed is
that no existing-session mutation is admitted until the lease is held by the
sending connection, its epoch matches, and — with the single exception of
`session.resume` on a verified dormant session — that connection holds a
controller-capable attachment. So a newly created session is driven by
attaching and acquiring in either order and then sending the first command
with the granted epoch, and a known dormant session is driven by acquiring
by ID, resuming with the granted epoch and attaching. A
controller renews its lease while it lives and releases it on an orderly
disconnect; a lease that is not renewed expires. Takeover is explicit: an
observer asks for control and receives it only when the lease is released or
expired, and the grant mints a new writer epoch before the new controller's
first command can be admitted, so a controller that was killed mid-run and
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
release on orderly disconnect. Expiry and an unresolved admission meet on one
rule, so neither promise is quietly broken by the other: a mutation whose
holder check completed before the deadline settles under its lease even if the
deadline passes while core is still deciding; at the deadline the holder gains
nothing further and every new mutation of its own refuses; and a takeover becomes
eligible at the deadline but is granted only once those in-flight mutations
have resolved. That adds no grace, because the expired holder can only finish
what it had already begun. Writer exclusion between two daemons on one
state root stays the local store's writer marker, unchanged.

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
beneath live sockets was rejected on 2026-09-20, on an independent review's
finding: the owner holds the session's
in-flight admission set, a takeover waits on that set being empty, and a
restarted owner cannot know what it has forgotten. Retaining the set in a
survivor moves the same window one process up; making it survivable at all
would mean making it durable, which is the durable lease record this decision
already rejects.

**Evidence its acceptance requires.** This is a trust claim, so its class is
negative tests on real processes plus a security reading of the admission
path: every refusal — stale epoch, copied current epoch, non-holder
connection, released lease, expired lease, observer abort — proved before core
admission and before any session write, a controller killed mid-run fenced
after takeover, a lease owner killed while a mutation is in flight taking the
daemon down rather than being restarted beneath live sockets, and a daemon
restart leaving every session uncontrolled with every earlier epoch refused. No durable record changes, so no migration or
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
| Acceptance | — | — | — |
