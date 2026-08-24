# 0010. Daemon collaboration policy and controller takeover

<a id="concept"></a>
## Concept

Technical depth: [Policy states, takeover, and the core boundary](0010-daemon-collaboration-policy-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-22
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` acceptance, and implementation of its outcome 7

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0010-context"></a>
## Context

With N clients attached to one session, two of them can send conflicting
commands. Something must decide who may command, and where that decision lives
determines whether Loopex stays a kernel.

The vision is explicit that the core does not mandate a controller lease: it
serializes all durably admitted commands, and a reference daemon implements
one-controller/many-observer policy, crash takeover, and stale-writer fencing
*above* the core. Another host may use a different collaboration policy
entirely.

That boundary is easy to state and easy to erode. The natural implementation
instinct — the coordinator knows who is attached, so let it decide who may
command — puts collaboration policy inside the session owner, at which point
every host inherits Loopex's opinion about collaboration and the kernel has
grown a product feature.

This decision fixes the concrete policy and the boundary together, because
fixing one without the other is how the boundary moves during implementation.

Technical depth: [Why the boundary erodes without a rule](0010-daemon-collaboration-policy-technical.md#technical-adr-0010-context).

<a id="concept-adr-0010-decision"></a>
## Decision

- **Core carries no controller concept.** It admits and serializes durably
  admitted commands and holds no notion of controller, observer, lease, or
  takeover. This is verified by a negative test, not by intent.
- **The daemon implements one-controller/many-observer.** At most one attachment
  holds command authority for a session at a time; every other attachment is an
  observer receiving the same committed history.
- **A read-only attachment never acquires command authority.** Not by sending a
  command, not by the controller leaving, not by holding a cursor. It must
  explicitly request control and be granted it.
- **Control is explicit and revocable.** An attachment requests control, holds it
  while its connection lives, and releases it on clean detach.
- **Takeover requires the controller to be provably gone**, not merely quiet. The
  daemon fences the departed controller before granting control to a successor,
  so a returning controller cannot resume commanding.
- **A fenced ex-controller is refused with a named error**, not silently ignored.
  A client must be able to distinguish "you are not the controller" from "your
  message was lost."
- **The policy is replaceable.** It is the reference daemon's policy, documented
  as such. A host that wants free-for-all, quorum, or role-based control replaces
  the daemon's policy without touching core.

Technical depth: [Exact states, takeover sequence, and the verified boundary](0010-daemon-collaboration-policy-technical.md#technical-adr-0010-decision).

<a id="concept-adr-0010-alternatives"></a>
## Alternatives

**No policy — every attachment may command.** Core already serializes, so this is
coherent and is genuinely the smallest thing. It is not recommended for the
reference daemon because two editors driving one session with no arbitration
produces interleaved runs that no user asked for. It remains available to a host
that wants it, which is the point of keeping policy out of core.

**A controller lease in core.** Fewer moving parts and one obvious place for the
rule. Rejected: it puts a collaboration opinion in the kernel, contradicts the
vision directly, and makes every host inherit it.

**Optimistic concurrency by command.** Each command carries an expected session
version and loses on conflict. Elegant, and wrong for this shape — an interactive
controller would lose races to a background observer and see rejections it cannot
act on.

Technical depth: [Alternative analysis](0010-daemon-collaboration-policy-technical.md#technical-adr-0010-alternatives).

<a id="concept-adr-0010-consequences"></a>
## Consequences

The reference daemon acquires a real state machine — control held, released,
fenced, taken over — which is code that must be tested rather than asserted.
That cost is accepted because the alternative places the same complexity in core
where it is much harder to remove.

Two clients that both want control will have one refused. That is a visible
product behaviour, and the named error exists so a client can present it
honestly.

"Provably gone" is doing real work in the takeover rule, and it is where a
premature timeout would reintroduce exactly the split-brain the store's fencing
exists to prevent. The daemon's fencing is a policy layer over a store that
already refuses stale writers, not a replacement for it.

Technical depth: [Operational consequences](0010-daemon-collaboration-policy-technical.md#technical-adr-0010-consequences).

<a id="concept-adr-0010-compatibility"></a>
## Compatibility, Migration, and Rollback

No public compatibility claim. Control requests and refusals travel as ADR 0008
envelopes and error codes, so a change to them is a protocol version change.

Rollback is replacing the policy with no policy, which core already supports
because core never knew about it.

Technical depth: [Compatibility and rollback mechanics](0010-daemon-collaboration-policy-technical.md#technical-adr-0010-compatibility).

## Links

- [ADR 0006](0006-store-transaction-and-owner-epoch.md#concept) — the store
  fencing this policy layers over and does not replace
- [ADR 0008](0008-session-protocol-candidate.md#concept) — control request and
  refusal envelopes
- [ADR 0009](0009-attachment-cursor-and-residency.md#concept) — attachments and
  cursors, which never carry authority
