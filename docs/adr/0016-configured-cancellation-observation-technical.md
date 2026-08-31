# 0016. Configured cancellation observation — technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Configured cancellation observation](0016-configured-cancellation-observation.md#concept).

<a id="technical-adr-0016-context"></a>
## The Split Clocks

Concept: [Context](0016-configured-cancellation-observation.md#concept-adr-0016-context).

The current paths are independent:

```text
runtime cleanup_grace_ms       positive configured value, default 5_000
Executor.cancel/3 bound        fixed 60_000
CLI interrupt backstop         fixed 10_000
local receipt reserve          floor(cleanup_grace_ms / 4)
recovery cleanup_grace_ms      fresh process option, not retained session truth
```

A larger session value is accepted and reported but not honored by its outer
observers. A smaller value still inherits waits unrelated to what the operator
declared. Because the CLI can halt the VM, its fixed bound is not merely a UI
timeout; it can prevent the runtime from committing the cleanup fact entirely.
On recovery the same mismatch reaches the hand: the local executor is composed
before replay and the reducer replaces no process option with durable truth.

<a id="technical-adr-0016-decision"></a>
## One Formula and One Value Path

Concept: [Decision](0016-configured-cancellation-observation.md#concept-adr-0016-decision).

Core exposes these public functions:

```text
default_cleanup_grace_ms() -> 5_000
cancellation_bounds(grace_ms) ->
  {:ok, %{
    executor_observe_ms: max(10_000, grace_ms + 2_000),
    receipt_reserve_ms: floor(grace_ms / 4),
    terminal_reserve_ms: max(10_000, floor(grace_ms / 4)),
    cli_backstop_ms: max(10_000, grace_ms + 2_000)
      + floor(grace_ms / 4)
      + max(10_000, floor(grace_ms / 4))
  }}
  | {:error, :invalid_cleanup_grace}

cancel(module, reference, job_id, grace_ms) ->
  {:ok, :cleaned} | {:ok, :unconfirmed}
  | {:error, :invalid_cleanup_grace}
```

`default_cleanup_grace_ms/0`, `cancellation_bounds/1`, and `cancel/4` are public;
receipt and terminal arithmetic are not duplicated as separately callable
helpers. Given the other three admitted arguments, a non-positive or non-integer
grace returns the exact error above from both configured functions. The bounded
worker is killed when the derived observation period expires and returns
unconfirmed. Callback absence, error, raise, exit, and malformed answers retain
ADR 0012's exact normalization.

No positive value admitted by the existing runtime is rejected or saturated.
Internal waits use one monotonic deadline and finite VM-safe timer slices; after
each slice they recompute the remaining duration. The same helper discipline
applies to the core facade, the local executor's cancellation episode, and the
CLI backstop. Arithmetic remains exact in Elixir integers, while no individual
`receive after` or timer call receives a value outside its admitted range.

Durable and boundary shapes add:

```text
session_genesis_v2 = %{
  kind: "session_genesis_v2",
  "options" => normalized_session_options,
  "runtime_configuration" => %{
    "cleanup_grace_ms" => positive_integer
  }
}

JobRequest.cleanup_grace_ms = the exact committed session value
session_status.cleanup_grace_ms = the exact committed session value
```

The versioned genesis outer key set is exactly `[:kind, "options",
"runtime_configuration"]`; the runtime-configuration key set is exactly
`["cleanup_grace_ms"]`. The existing normalized session-options map is retained
unchanged as durable caller input rather than replaced by the new member. Both
maps are exact-key validated and replayed before the coordinator advances work.
No compatibility clause maps
`session_genesis` to `session_genesis_v2` or supplies a missing member. The job
member is an immutable semantic field covered by the
existing `canonical_request_digest`; every attempt of one operation therefore
carries the same cleanup value while retaining its own attempt-bound digest.
The local executor records the job value beside the starting or running
in-flight identity, so its unchanged `cancel/2` callback reads the value of the
job it is ending rather than the process's startup default.

The value path is:

```text
CLI parse or host option
  -> runtime validation/default for new sessions
  -> durable session genesis
  -> recovered session configuration
  -> canonical JobRequest and in-flight executor identity
  -> coordinator cancellation call
  -> Executor.cancel/4 formula

new run: committed session value
resume/cancel: recovered session-status value
  -> Interrupt.install(attachment, grace_ms) -> installation
  -> the same core formula

accepted explicit cancel
  -> Interrupt.arm(installation)

terminal signal during run/resume
  -> submit abort -> accepted -> arm that same installation
```

`cancel/3` retains ADR 0012's 60-second defensive implementation; no runtime
session uses that facade. `Interrupt.install/1` retains its ten-second
direct-caller behavior. The CLI derives a missing configured grace from
`Loopex.Executor`, not a copied literal, for a new session. Production run,
resume, and cancel call `install/2` with the value governing that session and
receive an opaque installation token. A resume or cancel option that is present
and differs from the projection is a bounded `cleanup_configuration_conflict`;
an omitted option is not replaced with a default. One owner's coordinator,
executor, and interrupt handler therefore agree.

The interrupt installation carries the attachment, terminal pid, configured
grace, and derived observation bound. A signal event starts one worker off the
signal server; that worker submits the abort and arms the installation only when
the command returns accepted. The explicit `loopex cancel` path installs it
before the abort and calls `Interrupt.arm/1` synchronously immediately after the
abort is accepted and before rendering the stream. Installation alone never
starts a timer, so an ordinary healthy `run` or `resume` cannot be killed merely
because the handler exists. Arming is idempotent, and a rejected abort never
arms a backstop, including a signal delivered before prompt admission. Tests
inject the timer/halt effect through a private seam so they prove the number,
the accepted command-initiated and signal arming transitions, and the rejected
signal race without waiting or halting the suite.

After the executor callback answers `cleaned`, coordinator cleanup keeps the
supervised `execute/5` caller alive and responsive to its result for at most
`receipt_reserve_ms`. Only a validated retained receipt settles the operation.
On expiry the coordinator terminates that caller, records the cleanup as
unproven, and never interprets a later Store outcome as a confirmed non-commit.
An unconfirmed/error callback skips this wait because process cleanup itself is
already unproved. The coordinator remains responsive throughout both waits.

The two-second facade margin is outside the cleanup grace and covers bounded
post-bound helper-kill waits and callback handoff. The quarter-period term is the
shipped local executor's separately declared receipt-retention allowance. The
final floor-or-quarter reserve is deliberately later and belongs only to the
command's emergency backstop. Store calls do not have a corresponding latency
guarantee, so expiry of that backstop may interrupt terminal retention and leave
recovery to report durable truth; it is never treated as confirmed cleanup.
None of these outer allowances is reported as `cleanup_grace_ms`.

<a id="technical-adr-0016-alternatives"></a>
## Alternative Failure Modes

Concept: [Alternatives](0016-configured-cancellation-observation.md#concept-adr-0016-alternatives).

A constant is correct for at most one configured range. A caller-supplied raw
timeout makes the declared session value advisory. Querying the local executor
couples core or CLI to one adapter and fails for remote hands. Default wrappers
remain useful compatibility entries, but the production coordinator and command
paths must prove they never select them for a configured session.

<a id="technical-adr-0016-consequences"></a>
## Compatibility, Rollback, and Evidence

Concept: [Consequences](0016-configured-cancellation-observation.md#concept-adr-0016-consequences).

Required closure evidence includes:

- formula properties at the floor boundary and for values below, equal to, and
  above the default and former fixed waits, including the receipt share and
  strict ordering of the facade and CLI deadlines;
- an injected-clock case above one VM-safe timer slice proves the wait is sliced
  against one deadline rather than capped, rejected, or handed to one invalid
  timer;
- a facade callback that answers after a deliberately shortened mutant bound
  but before the derived bound, proving the configured value governs;
- coordinator evidence that the exact session value reaches `cancel/4` rather
  than the default;
- genesis, replay, canonical-job, and local in-flight evidence that a recovered
  hand receives the exact committed value without process-default substitution;
- command evidence that one parsed value reaches composition/runtime and the
  interrupt handler, whose signal-triggered and explicit-cancel arming paths use
  the same derived result; either path arms only after its abort is accepted,
  while a rejected pre-prompt signal and installing a healthy run or resume do
  not;
- recovery evidence that an active run's retained value is not replaced by a
  fresh command default, and that an explicitly conflicting value is refused
  by both `resume` and `cancel`;
- cleanup evidence that a callback-confirmed job gets its separate receipt
  reserve, a receipt inside it settles, and expiry terminates the execute caller
  and stays unproven;
- local-executor evidence that `default_cleanup_grace_ms/1` and the legacy
  `cleanup_grace_ms/1` alias report only the startup default while a non-default
  active job and its receipt use the committed job value;
- a callback outliving the derived bound is killed and normalized unconfirmed;
- direct `cancel/3` and `Interrupt.install/1` compatibility cases retaining
  their existing 60-second and ten-second behavior without being selected by a
  configured production run;
- every ADR 0012 error and absence case remains unconfirmed; and
- mutation checks replacing any one propagation edge with `5_000`, `10_000`, or
  `60_000` fail a protected case.

The rollback unit is the versioned genesis schema, canonical job, core facade,
coordinator call, local in-flight state, session-status projection, CLI
propagation, interrupt state, docs, and tests. The executor callback does not
change arity. Development histories written with the new genesis/job contract
are not replayed by the prior implementation.
