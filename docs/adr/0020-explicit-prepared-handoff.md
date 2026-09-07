# 0020. Explicit prepared handoff

<a id="concept"></a>
## Concept

Technical depth: [Handoff ownership and evidence](0020-explicit-prepared-handoff-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-06
- **Decision owner:** Maintainer

This proposal makes ADR 0016's prepared-recovery handoff explicit. It preserves
the ordinary two-argument holder transfer, one-use activation capability, and
cancellation contract. It adds no durable record or general ownership framework.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0020-context"></a>
## Context

Prepared recovery lets a host install its interruption path before recovered
work starts. The current CLI selects additional Core transfer behavior through
an undocumented process-dictionary marker. Installation also supports dynamic
handler replacement, although production commands install once, and holds a
node-wide installation lock while waiting without a deadline for retired holders.

The retained review identifies missing initial-preparer monitoring, unsupported
non-local participant handling, and tests that infer ordering from source
positions or brief silence. These are ownership and evidence defects around an
existing capability, not reasons to change session truth.

Technical depth: [Source evidence and constraints](0020-explicit-prepared-handoff-technical.md#technical-adr-0020-context).

<a id="concept-adr-0020-decision"></a>
## Decision

Keep `Loopex.transfer_resume/2` as ordinary transfer. Add an explicit local
three-argument overload naming the receiving holder and its lifetime participant:
the process that keeps that holder alive only while its required dependencies
exist. The overload exposes a documented, narrow participant protocol so an
embedder need not copy the CLI's private implementation. Core receives no CLI,
signal-manager, or presentation concepts.

Monitor the preparing process from preparation onward. During the explicit
handoff, the coordinator authorizes one exact transfer and the lifetime
participant accepts that authorization through the current holder. This is the
handoff's lifetime linearization: the point after which the preparer's later
disappearance cannot revoke it. The coordinator records the acknowledged holder
before returning success. An abort or owner fence remains effective throughout
and cannot be cleared by completing the handoff.

The CLI supplies its existing guard as the participant. Before handoff, that
guard owns the preparer dependency; throughout installation it owns the exact
signal-manager and holder dependencies. It independently observes coordinator
loss, including while the holder is idle. Loss ends the affected transient
holder, not a session whose activation already succeeded. Orderly handler
removal releases the holder without blocking signal delivery.

A definitive refusal proves this transfer did not happen. Loss after a possible
handoff is unresolved. A missing reply or expired observation never proves
transfer, attachment, activation, abandonment, or abort failed. Decision callers
may wait without a deadline for an exact answer while the coordinator and signal
manager stay responsive; read-only observations have independent bounded waits.

Install one CLI interrupt handler per exact signal manager. Refuse duplicates
atomically without replacing the incumbent, its holder, abort identity, or
backstop. Remove dynamic replacement and predecessor draining. Initial
installation retains signal coverage and the ordinary signal-to-abort path.

Technical depth: [Explicit surface and state transitions](0020-explicit-prepared-handoff-technical.md#technical-adr-0020-decision).

<a id="concept-adr-0020-alternatives"></a>
## Alternatives

**Explicit handoff and initial installation only** is recommended. It names the
existing lifetime relationship and deletes an unused state machine. It requires
one additive local call and joint Core/CLI conformance evidence, not a new port.

**Ordinary transfer with a CLI-only guard** is smaller at the Core boundary, but
today's facade cannot independently report an idle coordinator's death to that
guard. It would narrow dependent-holder cleanup or require another explicit
boundary and its evidence.

**Retain dynamic replacement** supports an unused command behavior and needs
its own proved cancellation, draining, and installer-loss contract. Keeping the
hidden selector also preserves undocumented cross-application coupling.

Technical depth: [Alternative costs](0020-explicit-prepared-handoff-technical.md#technical-adr-0020-alternatives).

<a id="concept-adr-0020-consequences"></a>
## Compatibility, Delivery, and Rollback

The overload extends ADR 0016's existing opaque local control capability.
Portable public data and durable state remain plain bounded data. The ordinary
two-argument transfer retains its current behavior, including its PID domain.
Only the new guarded entry requires local participants. This is an additive,
unreleased embedded API; no distributed guarded handoff or public compatibility
freeze is added.

The CLI changes from replacement to duplicate refusal. Compatibility installation
entries retain their documented best-effort return behavior; prepared
installation propagates success, definitive refusal, or unresolved handoff.
On unresolved, the CLI keeps recovery fenced and its lifetime cleanup active,
reports uncertainty, and does not activate or retry installation as if nothing
happened. No accepted ADR clause is superseded: this makes
ADR 0016's existing serialized handoff obligation explicit.

Update the facade, capability, coordinator, CLI, affected guidance, and behavioral
evidence together. Rollback first terminates transient installation participants
and restarts the prior command composition; it never translates a live capability
or undoes an admitted session operation. Store and executor rollback rules stay
binding.

M2 remains Closed. This proposal grants no implementation, gate amendment,
closure, integration, or release authority.

Technical depth: [Migration, rollback, and decisive evidence](0020-explicit-prepared-handoff-technical.md#technical-adr-0020-consequences).
