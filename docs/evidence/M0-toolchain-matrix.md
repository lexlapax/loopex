# M0 Toolchain Matrix

Retained by outcome 3. ADR 0002 validates two (Elixir, OTP) pairs rather than a
cross-product, and one Mix run has one Erlang runtime, so the gate runner is
invoked once per pair and both runs are recorded here.

- floor pair: Elixir 1.17.0 / Erlang OTP 26, erts-14.0 — `M0 gate GREEN`, exit 0
- current pair: Elixir 1.20.3 / Erlang OTP 29, erts-17.0.5 — `M0 gate GREEN`, exit 0
- candidate: recorded per run below; the current closure candidate is named in the plan's
  governance row rather than duplicated here, so this file does not go stale when a
  later commit changes only documents
- recorded: 2026-08-17, macOS arm64, both pairs provided by `mise`

## What the floor lane was worth

It is the reason the two-pair rule exists, and it earned its place here rather
than merely satisfying a rule. Running it found two defects the current pair could
not have surfaced, both of which would have shipped:

1. The documentation check identified macro-injected entries through metadata that
   only newer Elixir emits. On 1.17 the same fact lives in the Erlang annotation as
   `generated: true`, so the check failed on `child_spec/1` — a function nobody
   wrote. Both signals are now read.
2. The gate runner's executed-count arithmetic was wrong for 1.17, which
   [Amendment 2](../plans/M0-gate.md#amendment-2) corrects. It read an unfiltered
   run of the real-provider file as one executed test and declared that
   `real_provider` was not excluded by default, failing outcome 7 for a pure
   parsing error while the exclusion worked correctly.

Neither was reachable by inspecting the gate or by running the current pair.

A third defect surfaced only when both lanes ran against the same commit. The
core-only lane shared the umbrella's build directory, so it depended on which
toolchain had compiled last: running the floor pair after the current pair loaded
beams built by the other Elixir and the VM died with a corrupt atom table. The gate
failed on a docs-only commit that had passed minutes earlier. The lane now owns a
temporary build directory. Both lanes were then run in both orders, four runs, all
green -- which is the evidence that matters here, because a per-lane green proves
nothing about ordering.
