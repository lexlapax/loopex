# 0012. Executor cancellation capability

<a id="concept"></a>
## Concept

Technical depth: [Cancellation boundary and evidence](0012-executor-cancellation-capability-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-29
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` closure
- **Supersedes:** 0009
- **Supersedes:** 0011

The two supersession declarations are limited to the executor-boundary
exclusivity clauses named below. Every other decision in ADR 0009 and ADR 0011
is incorporated unchanged.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0012-context"></a>
## Context

[ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) says the executor
port changes in exactly one way for `M2`: `execute/4` becomes `execute/5`, and
nothing else at the boundary moves. [ADR 0011](0011-session-input-algebra-and-streaming.md#concept)
repeats that the progress function is the whole executor-boundary change.

That boundary cannot implement the cancellation protocol both decisions and the
vision require. A durably admitted abort must stop one in-flight executor job,
wait for bounded cleanup, and commit `cancelled` only when cleanup is confirmed.
Workspace-lease loss is too coarse: a lease belongs to a workspace, so revoking
it stops every job using that workspace and leaves the host unable to continue
work there. Killing only the coordinator's worker proves nothing about an
operating-system process the executor owns.

`M2` therefore needs one job-scoped cancellation operation on the executor port.
This is a public-boundary change, not an implementation detail or a recorded
limitation. The surface is unreleased and explicitly unstable, but the decision
still has to replace the two accepted exclusivity clauses additively rather than
editing either accepted ADR.

Technical depth: [The accepted clauses and the missing operation](0012-executor-cancellation-capability-technical.md#technical-adr-0012-context).

<a id="concept-adr-0012-decision"></a>
## Decision

**An executor that conforms to the cancellation capability implements
`cancel/2`.** The callback stops one named job and reports what cleanup it could
confirm. `{:ok, :cleaned}` means the owned process tree is confirmed gone.
`{:ok, :unconfirmed}` and `{:error, reason}` mean the executor could not prove
that fact. A raise, exit, malformed answer, or answer that exceeds the runtime's
defensive bound is also unconfirmed.

The callback is required because an executor may own operating-system work.
Silence cannot distinguish an in-VM implementation with nothing to stop from an
implementation that left a process running. An in-VM executor implements the
callback and answers `{:ok, :cleaned}`; it does not communicate that fact by
omitting the operation.

**The facade still handles a nonconforming or mixed-version implementation
defensively.** If a module does not export `cancel/2`, `Loopex.Executor.cancel/3`
returns `{:ok, :unconfirmed}`. That fallback is not conformance and does not
turn the callback back into an option. It prevents a stale or host-supplied
implementation from converting silence into a false clean stop while the
runtime reports `outcome_unknown` with a reconciliation reference.

ADR 0009's cancellation ordering and terminal algebra remain unchanged. The
change is the boundary operation that makes the cooperative-cancel step
expressible for one job. ADR 0011's executor progress function, validation, and
stream-closing rules remain unchanged.

Technical depth: [Callback, normalization, and integration contract](0012-executor-cancellation-capability-technical.md#technical-adr-0012-decision).

<a id="concept-adr-0012-alternatives"></a>
## Alternatives

**Keep `cancel/2` optional.** This preserves source compatibility for a module
that implements only `execute/5`, but it calls an effect-owning executor
conformant while giving the runtime no way to ask it to stop. Reporting
`outcome_unknown` is truthful; it does not satisfy the separate requirement to
stop owned work. Not taken.

**Route cancellation through workspace-lease revocation.** This uses the signal
`M1` already has, but it stops unrelated jobs, destroys the host's ability to do
later work in that workspace, and asks the coordinator to revoke a lease the host
owns. Not taken.

**Cancel only the BEAM worker and always report `outcome_unknown`.** This leaves
an executor-owned process tree outside the cancellation protocol and makes a
clean operator cancellation unrepresentable even where the executor can prove
one. Not taken.

Technical depth: [Why the alternatives do not satisfy the boundary](0012-executor-cancellation-capability-technical.md#technical-adr-0012-alternatives).

<a id="concept-adr-0012-consequences"></a>
## Consequences

The executor behaviour grows by one required callback. Every implementation and
test fixture must implement it before claiming conformance. The shipped local
executor performs job-scoped process-group termination and confirmation; an
in-VM fixture may answer clean immediately.

An implementation compiled against the earlier experimental behaviour may still
load, and the facade handles it fail-closed as unconfirmed, but it is not
cancellation-conformant until it adds the callback. This distinction is visible
to embedders and belongs in the compatibility inventory.

`M2` does not close until this decision carries recorded acceptance and the
locked cancellation evidence proves both the conforming path and the defensive
fallback. No released contract or installed data is migrated.

Technical depth: [Evidence, compatibility, and rollback](0012-executor-cancellation-capability-technical.md#technical-adr-0012-consequences).

## Links

- [ADR 0009 — Tool, executor, and grant contracts](0009-tool-executor-and-grant-contracts.md#concept)
- [ADR 0011 — Session input algebra and streaming progress](0011-session-input-algebra-and-streaming.md#concept)
- [M2 recorded limitations](../evidence/M2-recorded-limitations.md)
- [Vision cancellation protocol](../vision-technical.md#technical-vision-recovery-truth)
