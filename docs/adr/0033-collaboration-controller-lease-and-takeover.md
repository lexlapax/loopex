<a id="concept"></a>
## Concept

Technical depth: [Collaboration mechanics](0033-collaboration-controller-lease-and-takeover-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; the core keeps the vision §11.6 rule that it mandates no controller lease
- **Prerequisite for:** M5 acceptance

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
time, held under a lease the daemon owns and records durably in its own
runtime-control namespace, never in the session journal. Every other
attachment is an observer: it receives the same snapshot and events and may
not admit a command. A command from a connection carries the writer epoch of
the lease it believes it holds; the daemon refuses, before core admission and
before any durable write, a command whose epoch is not the current one. A
controller renews its lease while it lives and releases it on an orderly
disconnect; a lease that is not renewed expires. Takeover is explicit: an
observer asks for control and receives it only when the lease is released or
expired, and the grant advances the writer epoch durably before the new
controller's first command can be admitted, so a controller that was killed
mid-run and comes back late is fenced by its stale epoch. Cancellation
crosses processes because the core owns dispatch: the current controller's
`session.abort` cancels work that an earlier controller's command dispatched,
with the truthful cleanup outcome the core already commits.

Nothing but the lease grants control. No client content, model output,
interaction answer, metadata field or attachment order confers it, and the
daemon's own configuration may narrow who may take over; it cannot widen what
the host's policy allows a command to do. The proposed lease terms are exact
and are bound at acceptance: a thirty-second lease renewed every ten seconds,
takeover admitted the moment expiry is observed, and an immediate release on
orderly disconnect.

Technical depth: [Contract and evidence](0033-collaboration-controller-lease-and-takeover-technical.md#technical-adr-0033-decision).

<a id="concept-adr-0033-consequences"></a>
### Consequences, Compatibility and Rollback

Two people, or one person and one automation, can watch one session while
exactly one of them drives it, and a crashed driver's terminal cannot
interfere after someone else has taken over. Core semantics are unchanged:
admission, ordering, durability, fencing by session epoch and receipts stay
exactly as accepted, and another host may implement a different collaboration
policy above the same core. The wire gains lease methods and a writer-epoch
field in generation 2 only.

Rollback is the M4 foreground server, whose single connection is its own
controller by construction; lease records are daemon-owned and are simply
absent without a daemon.

Technical depth: [Compatibility mechanics](0033-collaboration-controller-lease-and-takeover-technical.md#technical-adr-0033-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
