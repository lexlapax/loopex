# M0 Toolchain Matrix

Retained by outcome 3. ADR 0002 validates two (Elixir, OTP) pairs rather than a
cross-product, and one Mix run has one Erlang runtime, so the gate runner is
invoked once per pair and both runs are recorded here.

ADR 0002 validates two (Elixir, OTP) pairs rather than a cross-product, and one Mix
run has one Erlang runtime, so the gate runner is invoked once per pair. Both
orders are run, because a per-lane pass proves nothing about ordering — a shared
build directory once made the second lane fail on beams the first had compiled.

- candidate: `9095fb65fb0f79a50adbb6e645fd229c7f3c87ae`
- gate digest: `sha256:e3a755be21b63a68164faa7edba489742409d94576fe74afd745a8edc30499dc`
- command: `bash scripts/check-m0-gate.sh`, with `LOOPEX_PROVIDER_API_KEY` set, the
  floor pair supplied by `mise exec erlang@26.0 elixir@1.17.0-otp-26 --`
- host: macOS arm64; both pairs provided by `mise`
- recorded: 2026-08-17

| # | Order | Toolchain | Verdict | Exit | Wall clock |
| --- | --- | --- | --- | --- | --- |
| 1 | first | Elixir 1.17.0 / OTP 26.0 erts-14.0 | `M0 gate GREEN` | 0 | 89s |
| 2 | second | Elixir 1.20.3 / OTP 29.0.5 erts-17.0.5 | `M0 gate GREEN` | 0 | 101s |
| 3 | third | Elixir 1.20.3 / OTP 29.0.5 erts-17.0.5 | `M0 gate GREEN` | 0 | 56s |
| 4 | fourth | Elixir 1.17.0 / OTP 26.0 erts-14.0 | `M0 gate GREEN` | 0 | 87s |

Runs 1 and 2 are floor-then-current; runs 3 and 4 reverse that, so each pair ran
both immediately after itself and immediately after the other. With no
`LOOPEX_PROVIDER_API_KEY` present the same runner stops at outcome 7 reporting
evidence unavailable rather than skipping, which is the fail-closed direction.

These runs were executed at the candidate named above. This file and the
self-hosting evidence are written in the commit immediately after it, so the
closure candidate differs from the runs' SHA by those retained evidence files — there is no way to record a run inside the commit the run
observed. That residual gap is stated rather than papered over, and it is why the
gate expects a reviewer to re-run at the closure candidate rather than trust a
retained verdict.

The toolchain column names the EXACT version each lane ran, not the major release.
`mix loopex.matrix` searches for that exact string: it previously searched for the
major, so a row naming "OTP 26" satisfied a lock that promises 26.0 while runtime
matching was exact. Evidence a check accepts loosely is evidence the check does not
really constrain.

`mix loopex.matrix` requires this file to name every locked pair with a green
verdict. It cannot verify that a recorded run happened, and says so; that judgment
is review's.

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
