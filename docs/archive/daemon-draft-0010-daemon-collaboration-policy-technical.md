# 0010: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Daemon collaboration policy and controller takeover](0010-daemon-collaboration-policy.md#concept).

<a id="technical-adr-0010-context"></a>
## Why the Boundary Erodes Without a Rule

Concept: [Context](0010-daemon-collaboration-policy.md#concept-adr-0010-context).

The coordinator is the one process that already knows the session's serial order,
already fences stale writers through the store, and already sees every command.
Every fact a controller rule needs is sitting in it. So the cheapest correct
implementation of one-controller/many-observer is a field in coordinator state
and a guard in its command path.

That implementation is also the end of the kernel boundary. Once the coordinator
knows what a controller is, a host that wants a different collaboration model
cannot have one without changing core, and the vision's claim that "another host
may use a different collaboration policy" becomes false. Nothing announces this
when it happens; the code is shorter and the tests pass.

The same pressure appears a second time under takeover. Fencing a departed
controller looks like the store's stale-writer problem, and the store already
solves that — so the instinct is to reuse the session epoch as the controller
fence. That conflates two different things: the session epoch fences a *writer to
durable truth*, while a controller fence gates *which client may ask*. Merging
them means a client-level policy decision can advance a durability-level epoch,
and a durability recovery can silently change who is in control.

The rule that keeps both boundaries is that policy lives in the daemon and
consults core's facts without adding to them, and that a negative test proves
core stayed ignorant. Intent is not sufficient here, because the erosion is a
local improvement at every individual step.

<a id="technical-adr-0010-decision"></a>
## Exact States, Takeover Sequence, and the Verified Boundary

Concept: [Decision](0010-daemon-collaboration-policy.md#concept-adr-0010-decision).

Per-session control state, held entirely in the daemon:

| State | Meaning |
| --- | --- |
| `uncontrolled` | No attachment holds command authority; commands are refused |
| `controlled(attachment_id)` | Exactly one attachment may command |
| `fencing(attachment_id)` | A departed controller is being fenced; no new controller yet |

Every attachment is an observer by default. Observers receive committed history
and progress identically to the controller; the only difference is the right to
command. A command from a non-controller is refused with `not_controller`,
carrying nothing about who the controller is — that would leak client identity
Loopex does not interpret.

Takeover sequence:

```text
controller connection closes, or fails liveness
-> daemon enters fencing(departed)
-> daemon fences the departed controller's session authority
-> daemon confirms the fence took effect
-> state becomes uncontrolled
-> a requesting attachment is granted controlled(new)
```

The confirmation step is not optional. Granting control before the fence is
confirmed produces a window with two clients that both believe they command,
which the store would eventually refuse at commit — correctly, but only after one
of them has been told its command was admitted.

"Provably gone" means the transport connection is closed or a liveness check has
failed, not that the controller has been quiet. A quiet controller is an idle
user. A timeout short enough to catch a crashed client is short enough to evict a
thinking one, which is why departure is detected from the connection rather than
from inactivity.

The controller fence is a daemon-level identifier and is deliberately **not** the
session epoch. Session epoch fences a writer to durable truth under ADR 0006;
controller fence gates which attachment may submit. Keeping them separate means
a policy change cannot advance a durability epoch, and a durability recovery
cannot silently reassign control.

The boundary is verified rather than asserted. Outcome 7 requires a negative test
proving core admits and serializes commands with no controller concept, plus a
module-boundary assertion that no daemon collaboration term — controller,
observer, takeover, control lease — appears anywhere in core. A grep-class
assertion is crude and is exactly right here: the failure mode is a term
migrating inward, and a term migrating inward is what it detects.

<a id="technical-adr-0010-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0010-daemon-collaboration-policy.md#concept-adr-0010-alternatives).

**No policy — every attachment may command.** Core serializes, so the result is
well-defined: commands interleave in admission order. This is genuinely the
smallest implementation and it stays available to any host, which is the whole
reason policy is kept out of core. It is not the reference daemon's choice
because two editors driving one session produce interleaved runs with no
arbitration, and the resulting behaviour is indistinguishable from a bug.

**Controller lease in core.** One place for the rule, fewer moving parts, and a
direct contradiction of the vision's statement that core mandates no controller
lease. It also makes the policy unremovable: every host inherits it, and the
"different collaboration policy" escape hatch closes.

**Optimistic concurrency by command.** Each command carries an expected session
version; conflicts lose and retry. Correct in the abstract and poorly matched to
an interactive controller, which would lose races to any automated observer and
receive rejections a human cannot act on.

**Reuse the session epoch as the controller fence.** Tempting because the
mechanism exists and is proven. Rejected in the context section: it merges a
client-policy decision with a durability-truth mechanism, in both directions.

<a id="technical-adr-0010-consequences"></a>
## Operational Consequences

Concept: [Consequences](0010-daemon-collaboration-policy.md#concept-adr-0010-consequences).

The daemon gains a real state machine with a fencing intermediate state, and
`fencing` is a state clients can observe as `temporarily_unavailable` for
commands. That is honest: there is a real interval during which nobody may
command.

A second client requesting control while one is held is refused. The named error
lets a client present that plainly rather than appearing to hang.

The confirmation step in takeover costs latency at exactly the moment a user is
waiting — their editor crashed, they reopened it, and control is being
transferred. Making that fast without making it unsafe is an implementation
concern; making it unsafe to make it fast is the failure this decision exists to
prevent.

Keeping the controller fence separate from the session epoch means two fencing
mechanisms exist in the system, which is more to understand. The alternative is
one mechanism carrying two meanings, which is more to get wrong.

<a id="technical-adr-0010-compatibility"></a>
## Compatibility and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0010-daemon-collaboration-policy.md#concept-adr-0010-compatibility).

No public compatibility claim. Control requests, grants, and the `not_controller`
refusal are ADR 0008 envelopes and error codes, so changing them is a protocol
version change rather than a local edit.

No durable record holds control state — it lives in the daemon and dies with it.
A daemon restart therefore leaves every session `uncontrolled`, and clients
re-request control. That is a deliberate consequence of not persisting policy
state: there is nothing to migrate and nothing to reconcile.

Rollback is replacing the policy with no policy. Core already supports that
because core never knew about it, which is the property the negative test
protects.
