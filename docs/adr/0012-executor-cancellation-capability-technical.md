# 0012. Executor cancellation capability — technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Executor cancellation capability](0012-executor-cancellation-capability.md#concept).

<a id="technical-adr-0012-context"></a>
## The Accepted Clauses and the Missing Operation

Concept: [Context](0012-executor-cancellation-capability.md#concept-adr-0012-context).

This decision supersedes two exact exclusivity claims:

- ADR 0009's `The executor port change ADR 0011 makes` subsection says
  `execute/4` becomes `execute/5` and "nothing else at this boundary moves";
- ADR 0011's Concept decision and `The executor port` subsection say the trailing
  progress function is the whole executor-boundary change and `execute/5` gains
  nothing else.

Those statements remain historical facts about what was accepted. This
successor replaces only their claim that no second boundary operation exists.
Grant bindings, job and receipt shapes, request digests, deduplication,
executor-progress validation, cancellation ordering, and terminal outcomes keep
the meaning their accepted ADRs give them.

The vision's acknowledged cancellation sequence contains a cooperative cancel
to the executor before bounded grace, owned-tree termination, and cleanup
evidence. A behaviour with only `execute/5` cannot express that step after the
job has been dispatched.

<a id="technical-adr-0012-decision"></a>
## Callback, Normalization, and Integration Contract

Concept: [Decision](0012-executor-cancellation-capability.md#concept-adr-0012-decision).

The executor behaviour includes this required callback:

```elixir
@callback cancel(reference :: term(), job_id :: binary()) ::
            {:ok, :cleaned} | {:ok, :unconfirmed} | {:error, term()}
```

It is not listed in `@optional_callbacks`. The three declared answers normalize
to two cleanup facts:

| Callback answer | Runtime cleanup fact |
| --- | --- |
| `{:ok, :cleaned}` | `cleaned` |
| `{:ok, :unconfirmed}` | `unconfirmed` |
| `{:error, reason}` | `unconfirmed` |

Anything outside the declared return type, a raise, an exit, or a call that
outlasts the runtime's defensive bound also becomes `unconfirmed`. The bound is
runtime protection against host-supplied code that never answers; the local
executor performs its own cancellation inside the operator-visible cleanup
period.

`Loopex.Executor.cancel/3` checks `function_exported?/3` before calling the
implementation. An absent callback returns `{:ok, :unconfirmed}`. This branch is
a compatibility and safety guard for a nonconforming or mixed-version module,
not an optional-callback declaration and not evidence that its cleanup was
attempted.

The session coordinator invokes the facade in supervised work outside its own
process. A blocking host callback therefore cannot prevent the coordinator from
answering a second interrupt. The coordinator commits the run terminal only
after that work resolves, and derives `outcome_unknown` wherever any owned
operation or process tree remains unconfirmed.

The local executor's implementation is job-scoped. It uses the kill identity
captured before effect acceptance, applies the one configured cleanup period,
and confirms the owned process group is quiescent before answering clean. A job
that never started or is already terminal may answer clean because no owned work
exists. An in-VM executor makes the same fact explicit by implementing the
callback and answering clean.

<a id="technical-adr-0012-alternatives"></a>
## Why the Alternatives Do Not Satisfy the Boundary

Concept: [Alternatives](0012-executor-cancellation-capability.md#concept-adr-0012-alternatives).

An optional callback leaves capability implicit. The runtime cannot infer from a
missing function whether the implementation owns an operating-system process,
so absence has only one safe reading: unconfirmed. Making the callback required
turns the relevant capability into a conformance obligation instead of a guess.

Lease revocation is workspace-scoped rather than job-scoped and belongs to the
host. Killing only the task that called `execute/5` does not establish what an
executor-owned process or external effect did. Both alternatives can still end
truthfully as unknown, but neither implements the stop protocol.

<a id="technical-adr-0012-consequences"></a>
## Evidence, Compatibility, and Rollback

Concept: [Consequences](0012-executor-cancellation-capability.md#concept-adr-0012-consequences).

`M2` closure evidence must prove:

- the shipped local executor implements `cancel/2`, receives the named job, and
  confirms cleanup only after its owned process group is gone;
- a cleaned answer permits `cancelled`, while an unconfirmed, error, malformed,
  raised, exited, or timed-out answer produces `outcome_unknown` with the
  reconciliation reference;
- a module lacking `cancel/2` exercises the defensive fallback and confirms
  nothing rather than being read as clean;
- the host call runs outside the coordinator and cannot block a second
  interrupt; and
- every executor implementation and conformance fixture implements the required
  callback before it is labelled conformant.

The existing locked case `an executor that declares no cancellation confirms
nothing` remains useful, but it proves the nonconforming fallback rather than
optional-callback conformance. The cancellation selectors also have to prove the
normal callback and terminal-outcome paths.

**Compatibility.** The executor protocol is unreleased and explicitly unstable.
This change is source-breaking for an implementation that claims the behaviour
without `cancel/2`; the facade's fallback makes a stale implementation fail
closed at runtime but does not restore conformance. The compatibility inventory
must state both facts.

**Rollback before closure.** Remove `cancel/2`, the public abort-to-executor
path, and the clean-cancellation claim together. A rollback that removes the
callback while retaining an operator promise that cancellation stops executor
work is not valid.
