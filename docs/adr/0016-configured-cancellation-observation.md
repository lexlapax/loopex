# 0016. Configured cancellation observation

<a id="concept"></a>
## Concept

Technical depth: [Derived bounds, propagation, and evidence](0016-configured-cancellation-observation-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-31
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` closure
- **Supersedes:** 0009
- **Supersedes:** 0012

The ADR 0012 supersession is limited to the preserved fixed `JobRequest` shape
and the three-argument facade as the complete production integration path. This
decision adds one canonical job field and a configured four-argument production
facade. ADR 0012's required executor `cancel/2` callback, three-argument legacy
facade and defensive behavior, answer normalization, fail-closed fallback, job
scope, cancellation ordering, terminal algebra, and compatibility
classification remain unchanged.

The ADR 0009 supersession is limited to its fixed `JobRequest` field set and the
adjacent statement that nothing else at the executor boundary moves. This
decision adds the session's committed `cleanup_grace_ms` as one immutable,
canonicalized job field. Grant bindings, deadlines, attempt identity,
deduplication, progress, receipts, and every other executor rule remain
unchanged.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0016-context"></a>
## Context

The operator configures one cleanup period and the runtime and local executor
retain that value. The cancellation facade nevertheless waits a fixed 60
seconds, while the command's interrupt backstop halts the process after a fixed
10 seconds. A valid session configured for 120 seconds can therefore be declared
unconfirmed at 60 seconds or killed by its own command at 10 seconds even while
its executor is behaving exactly as configured.

Those fixed waits also disagree with each other. The earlier one wins by killing
the process, so the later one cannot protect anything. An operator-visible
cleanup period is truthful only when every outer observer allows the operation
it encloses to spend that period and its bounded retention reserve.

The executor callback remains `cancel/2`: its instance already owns the
configured period. The missing value belongs at the facade and command
observation boundaries, where callers decide how long an answer may take.

There is a second disagreement after recovery. The current reducer reconstructs
no cleanup configuration and then overwrites its default with the new process's
option. A resumed command can therefore install a five-second/default executor
and ten-second interrupt around a run that originally declared 120 seconds.
Reporting the value in a later terminal receipt is too late: cancellation needs
it before that terminal can exist.

Technical depth: [The split clocks](0016-configured-cancellation-observation-technical.md#technical-adr-0016-context).

<a id="concept-adr-0016-decision"></a>
## Decision

**One configured cleanup period derives both ordered cancellation observation
bounds.** The runtime passes its normalized `cleanup_grace_ms` to
`Loopex.Executor.cancel/4`. Core derives, rather than accepts, the waits:

```text
executor_observe_ms = max(10_000, grace_ms + 2_000)
receipt_reserve_ms  = floor(grace_ms / 4)
terminal_reserve_ms = max(10_000, receipt_reserve_ms)
cli_backstop_ms     = executor_observe_ms + receipt_reserve_ms + terminal_reserve_ms
```

The full grace covers termination and confirmation. The first two seconds cover
bounded post-bound helper termination and callback handoff. The quarter-period
share covers the separately declared receipt-retention allowance the shipped
executor may lawfully spend after cleanup. The final reserve gives the
coordinator and command a distinct interval to retain and render the terminal.
It is an emergency process-liveness backstop, not a claim that an arbitrary
Store operation completes inside that interval: if the session has not settled,
the command halts and recovery reads durable truth rather than calling the stop
confirmed. The 10-second floors preserve the existing operator-liveness
allowances for the default five-second cleanup period and small test or host
values. The command backstop is deliberately later than the facade timeout;
identical deadlines could halt the process at the instant core is handling the
unconfirmed answer.

The formulas live once in core as `Loopex.Executor.cancellation_bounds/1`,
which returns every derived interval together. The facade, coordinator, and
command consume that one result. No caller supplies an arbitrary timeout, and
no concrete executor module is queried for its own configuration.

Session creation commits the normalized value in the exact versioned
`session_genesis_v2` runtime configuration. The new reducer refuses the prior
genesis kind and the prior reducer refuses this one, so neither direction can
silently supply a process default. Recovery requires the member and reconstructs
it before work is advanced; a new process option is only a default for sessions
that process creates, never a replacement for an existing session's fact. Every canonical
`JobRequest` carries the committed `cleanup_grace_ms`, so a remote or local hand
does not depend on matching out-of-band process configuration. The shipped local
executor uses that job field for the cleanup episode and retains it with the
in-flight identity that `cancel/2` reads.

The owner-scoped session-status projection exposes the committed cleanup period
as read-only data. A reference `run` installs its interrupt handler with the
newly committed value. A reference `resume` or `cancel` waits for recovery,
reads the retained value from that projection, and installs its handler with the
same value. Omitting the CLI option on recovery uses the retained value;
explicitly supplying a different one is refused as a configuration conflict
rather than ignored.

After `cancel/2` confirms process cleanup, the coordinator does not immediately
terminate the still-running `execute/5` caller. It waits asynchronously for that
caller to return its validated retained receipt for at most the derived receipt
reserve. A valid receipt settles the operation; expiry terminates the caller and
leaves the effect unproven. This preserves ADR 0012's meaning of `cancel/2` as a
cleanup fact while making the separately declared receipt reserve part of the
actual production path.

The existing configuration domain remains every positive integer. Derived
values are not capped merely because one BEAM receive timer has a finite maximum.
Core, the local executor, and the interrupt handler wait against a monotonic
deadline in safe finite slices, checking the remaining duration after each
slice. This preserves a large admitted cleanup period without handing an invalid
timeout to the VM or converting a timer implementation limit into a false
unconfirmed result.

The command normalizes the cleanup period once, passes the same exact value to
the composition/runtime and interrupt handler, and records the derived outer
bound in handler state. Installation does not start a timer. A signal arms it
only after the signal worker's abort is durably accepted; an explicit
`loopex cancel` does the same before rendering begins. A rejected abort never
arms it, including a signal that arrives before a run is active. Its backstop
cannot fire before the facade's observation window. Recovery uses the cleanup
period committed with the session rather than a newly supplied command default.

ADR 0012's `cancel/3` and its existing 60-second defensive bound remain
byte-for-behavior compatible for direct callers. It does not delegate to the new
configured function. Production coordination always uses `cancel/4`; retaining
the older facade does not authorize that path to discard a session's
non-default value.
The executor behavior callback remains `cancel/2` and implementations do not
change arity. The interrupt module likewise keeps `install/1` with its existing
ten-second direct-caller behavior while production run, resume, and cancel use
`install/2`.

The local executor exposes `default_cleanup_grace_ms/1` for its startup default.
Its existing `cleanup_grace_ms/1` remains a compatibility alias for that default,
not a claim about an active job; job receipts and session status carry the
committed per-session value. Composition uses the default only when creating a
new session and never substitutes it during recovery.

Technical depth: [One formula and one value path](0016-configured-cancellation-observation-technical.md#technical-adr-0016-decision).

<a id="concept-adr-0016-alternatives"></a>
## Alternatives

**Keep 60 seconds in core and raise only the command backstop.** A configured
cleanup above 60 seconds still becomes a false unconfirmed result. Not taken.

**Keep 10 seconds in the command and cap configuration there.** This turns a
command implementation constant into the runtime's maximum supported cleanup
period and breaks embedders that have no terminal. Not taken.

**Expose an arbitrary facade timeout.** Callers could choose a value shorter
than the session's own cleanup period and recreate the contradiction. The
declared grace is the input; the outer bound is derived. Not taken.

**Change ADR 0012's `cancel/3` to use the default five-second grace.** That would
silently shorten its defensive 60-second behavior and could cut off a direct
caller whose executor was configured independently. Production should not use
it for a configured session, but compatibility means preserving both its shape
and its behavior. Not taken.

Technical depth: [Alternative failure modes](0016-configured-cancellation-observation-technical.md#technical-adr-0016-alternatives).

<a id="concept-adr-0016-consequences"></a>
## Consequences

Core, the canonical job, coordinator, local executor, command parsing, and
interrupt handling carry one exact cleanup value. A long configured cleanup can
keep the terminal alive longer than ten seconds; that is the period the operator
selected, with a bounded reserve and margin rather than an unrelated hang.

The added facade and interrupt arities are source-compatible. Executor adapter
implementations keep `cancel/2`, but the canonical job shape gains one required
field on this unreleased surface. Old development session histories without the
genesis member fail unavailable rather than receiving a fresh default. The
compatibility inventory and operator cancellation guide must name that
production now follows the configured value and that the older wrappers retain
their legacy fixed direct-caller behavior only.

Rollback removes the versioned genesis and job members, `cancel/4`, the derived bounds,
coordinator propagation, and command propagation together. New development
histories are unavailable to the prior reducer and may be discarded; prior
development histories are likewise unavailable to the new reducer rather than
being silently defaulted. Restoring
one fixed wait without the others recreates the split-clock defect and is not a
valid partial rollback.

`M2` does not close until tests prove a non-default period reaches every layer,
the facade never cuts off a conforming callback before its derived bound, the
interrupt backstop uses the same result and is armed for an accepted explicit
cancel but not merely by installing a healthy command, recovery uses the
retained period in the job, cancellation, status projection, and command,
explicit conflicting resume and cancel options are refused, and timeout, raise,
exit, malformed,
missing-callback, and unconfirmed answers still fail closed. A value above one
VM timer slice is proved through injected time so the test demonstrates slicing
without waiting for the configured duration.

Technical depth: [Compatibility, rollback, and evidence](0016-configured-cancellation-observation-technical.md#technical-adr-0016-consequences).

## Links

- [ADR 0012 — Executor cancellation capability](0012-executor-cancellation-capability.md#concept)
- [ADR 0009 — Tool, executor, and grant contracts](0009-tool-executor-and-grant-contracts.md#concept)
- [Vision cancellation protocol](../vision-technical.md#technical-vision-recovery-truth)
