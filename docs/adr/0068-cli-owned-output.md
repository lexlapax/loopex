<a id="concept"></a>
## Concept

Technical depth: [CLI output ownership and completion](0068-cli-owned-output-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-10-09
- **Decision owner:** Maintainer
- **Refines:** [ADR 0058](0058-bounded-progress-delivery.md#concept), CLI custody of native progress; [ADR 0049](0049-explicit-host-configuration.md#concept), physical transcript completion with its existing limits.

<a id="concept-adr-0068-decision"></a>
### Purpose and proposed decision

The CLI must keep live output bounded even when a pipe or custom output device
stops reading. Killing an IO worker does not remove bytes already held by its
device. Reporting delivery or releasing progress credit at that point can
hide an undelivered answer and leave a later write outside CLI cleanup.

Give each command one private CLI output owner. It owns the native progress
sink, transcript queue, retained suppression text and physical write tickets.
It survives foreground-command loss long enough to retire its original
resources. Acquire output before runtime or provider work. Support exactly
two target kinds: inherited stdout/stderr through a fixed raw-byte writer,
and a custom IO target whose creator transfers exclusive ownership of every
pending write and downstream copy. Refuse borrowed devices before work.

Propose one new, explicit 5,000-ms acquisition interval. The command captures
its cutoff immediately before its first output-acquisition effect. Target
setup, ownership acknowledgements and publication of the usable handle spend
that same interval. Cleanup uses only its remaining time, with no added grace.
On failure or caller loss, start no runtime/provider work. If cleanup cannot
be proved by the cutoff, report failure, retain original custody for late
retirement and fence target reuse. A late success cannot repair that verdict.
An unusable target is never borrowed again to print its own startup error.

Admission reserves capacity before payload transfer. A successful enqueue
means admission only. Confirm delivery after the complete write and joins of
its original resources. Retain native credit through every copy, including
text used to suppress a durable answer. Uncertain delivery permits truthful
durable fallback; it never authorizes retransmitting an uncertain write as
confirmed output. Retire a target after failure or lost ownership, and forbid
replacement on that target while cleanup is unproved.

Keep current rendering, native pressure and closure meanings, queue ceilings
and delivery/finish/stop cutoffs. The acquisition interval is a separate new
proposal; it borrows no Core clock and grants no cleanup grace.
An implementation that cannot prove its copies fit the existing credit must
drop transient output before the extra copy or stop for a further decision.
The stopped-output allocation capacity claim remains unproved. Recovery
inspection and the final runtime have separate sink lifetimes.

Technical depth: [Private interface and custody](0068-cli-owned-output-technical.md#technical-adr-0068-decision).

<a id="concept-adr-0068-alternatives"></a>
### Alternatives and recommendation

Recommend this private CLI boundary. It requires executable `/bin/bash` for
the inherited-fd backend and changes custom IO injection to explicit owned
acquisition. The writer preserves stdout/stderr destinations and exact
rendered bytes. Diagnostics retain their separate delivery accounting and
may interleave on stderr; this creates no global stderr order.

A shared host writer generalized from Stdio would require a wider contract,
dependency owner and changes to its strict JSON framing. Keeping arbitrary
borrowed devices cannot prove removal of their pending copies. Neither is
selected. Core gains no writer API, and CLI gains no AppServer dependency.

Recommend 5,000 ms for target startup and ownership handshakes. It adds up to
five seconds before runtime preparation. This is a proposed choice, not a
measured sufficiency claim or an inherited output allowance. A coherent
1,000-ms alternative uses the same ownership, cleanup and no-retry rules.
It refuses sooner but leaves less scheduling and cold-start room. Neither
number is justified by Core's unrelated startup-status read.

Deferring writer launch is only an optimization after exclusive target
custody has completed within the acquisition interval. Later setup, first
write and joins must fit an already applicable control or finish cutoff.
Text/progress paths lacking such a cutoff need their writer ready during
acquisition. A lazy borrowed-device handshake does not remove the timing
decision. No additional acquisition actor or retry is proposed.

Technical depth: [Target mechanisms and alternatives](0068-cli-owned-output-technical.md#technical-adr-0068-alternatives).

<a id="concept-adr-0068-evidence"></a>
### Consequences and required proof

Blocked or broken output can make the command fail without changing a durable
run outcome. A visible prefix or a lost completion remains delivery-unconfirmed.
Successful output proves a full target write, not receipt by a human. Prove
actual pipes, PTYs, custom-device retained copies, owner loss and retirement
under the proposed acquisition cutoff and unchanged delivery/cleanup limits
on Darwin and Linux with both supported toolchains.
Source review and arithmetic alone cannot activate this path.

Technical depth: [Cutoffs and qualification](0068-cli-owned-output-technical.md#technical-adr-0068-evidence).

<a id="concept-adr-0068-compatibility"></a>
### Compatibility and rollout

Migrate CLI callers to the current native sink and owned targets together,
then delete PID delivery and borrowed-device fallbacks. This changes a private
CLI injection contract and prerequisite, with no journal or wire migration.
Before source rollback, stop and join the current output owners; rollback
cannot manufacture proof for the unsafe path. Acceptance of this pair would
authorize its implementation only. Independent review, qualification and M7
closure remain separate.

Technical depth: [Migration and confinement](0068-cli-owned-output-technical.md#technical-adr-0068-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-adr-0065-0067-0068-2026-10-09) | candidate `773e090df996d3cd2e5966244121a9b632cffbd7`; concept `sha256:89e1bcb090a1e1648ef289c3238f5541d0b62627778419b5084fa3295a309b6f`; technical `sha256:6b40f8445e23a106911254ef09a14f76eff49d3cf7afd16060c94751783200d4` |
