# M0 Toolchain Matrix

Retained by outcome 3. Accepted ADR 0026 replaced ADR 0002's derived pin rule
with two exact (Elixir, OTP) pairs, and one Mix run has one Erlang runtime, so
the gate runner is invoked once per pair and every run is recorded here. The
ordering hazard this record was built around — a shared build directory making
the second lane fail on beams the first had compiled — is fixed in the runner
itself, and the narration below states exactly which adjacency these runs
prove rather than claiming the earlier campaign's coverage.

- runs taken at: `0915329ccfbc61b3110303d44b174076a3dedd63` (the code commit,
  with provisional rows for both pairs present in this file so that outcome 3
  could see both lanes recorded while the runs that replaced those rows
  executed; the commit carrying this file is a later one, and the gate is
  re-run there under both pairs before the closed M1 and M2 re-captures that
  cite it)
- gate digest: `sha256:b86275a21d1041c7e72e8354367ff9036de2470abfb2f11559ed95145835dca1`
  (M0 gate generation 7, which refreshed the floor pair under accepted ADR 0026)
- command: `bash scripts/check-m0-gate.sh`, with `LOOPEX_PROVIDER_API_KEY` set, the
  floor pair supplied by `mise exec erlang@27.3.4 elixir@1.18.5-otp-27 --`
- host: macOS arm64; the floor pair provided by `mise`, the current pair by Homebrew
- recorded: 2026-09-14; the previous record's five runs of 2026-08-21 under the
  earlier floor pair Elixir 1.17.0 with OTP 26.0 are superseded, not kept
  alongside, because accepted ADR 0026 changed the locked pairs and M4's
  Workstream 0 records the first runs under the refreshed pair

The runs are recorded below as verbatim text rather than as a Markdown table.
That is deliberate, and it is the seventh version of this check. Every earlier one
compared a locked pair against a hand-written approximation of how Markdown
renders, and every one was evaded: a code span that deleted text, a comment that
hid a field, `&#35;` rendering as `#` to smuggle in a second table with failing
runs. Content inside a fence has no inline structure at all, so a backtick, an
entity and comment syntax are literal characters to a reader and to the parser
alike. There is nothing to render, and so nothing to disagree about.

<!-- loopex:matrix-runs:start -->
```text
run=1 order=first elixir=1.18.5 otp=27.3.4 erts=15.2.7 verdict=GREEN exit=0 wall=2717s
run=2 order=second elixir=1.20.3 otp=29.0.5 erts=17.0.5 verdict=GREEN exit=0 wall=2628s
```
<!-- loopex:matrix-runs:end -->

The previous candidate's runs are superseded rather than kept alongside these.
Product bytes and the locked floor pair both changed, which invalidates the
evidence taken before them; a record carrying runs from two revisions invites a
reader to count runs that were never all true of one tree.

Runs 1 and 2 are floor-then-current in one clone with the shared build
directory left as the first run wrote it, so the one adjacency this record
claims for the refreshed pair is floor-current. The earlier record's five
runs proved every adjacency under the previous floor pair; the
shared-build-directory defect they caught is fixed in the runner itself, and
M4's Workstream 0 takes the refreshed pair's first proof as this pair rather
than repeating the four-adjacency campaign, which each later M0 re-proof under
the closed M1 and M2 re-captures extends. With no `LOOPEX_PROVIDER_API_KEY`
present the same runner stops at outcome 7 reporting evidence unavailable
rather than skipping, which is the fail-closed direction.

These runs were executed on the code commit named above with provisional
rows for both pairs committed in a throwaway clone, because the provider
fixture refuses a dirty checkout and outcome 3 refuses a record that names
fewer lanes than `.tool-versions` locks. They did not observe this file as it
now stands: the recorded-runs block, the header above it and this narration
were written after them. There is no way to record a run inside the commit
the run observed. That residual gap is stated rather than papered over; the
maintainer accepted the recorded runs for M4's acceptance checkpoint on
2026-09-14 without a re-run at the commit carrying them, and the closed M1
and M2 re-captures that follow each re-run the gate under both pairs at their
own candidates, which is where this pair's later proofs are retained.

The gate is also run on both lanes AFTER this file is committed, and that verdict
goes to the integrator out of band rather than into this file. Writing it here
cannot terminate: this file is an input to locked command 6, so recording a
verdict changes the bytes the verdict describes, and the commit carrying it is
unverified again. One candidate pasted a verdict and reproduced exactly that, one
commit later. AGENTS.md states the rule plainly -- do not mutate tracked bytes
merely to paste a final run link -- and what closes the gap is the gate's own
expectation that a reviewer re-runs at the closure candidate, not a retained
verdict. An earlier candidate skipped that step on the reasoning that an
evidence-only commit changes no product bytes -- and the gate reads these bytes.
The commit that recorded five green runs turned the gate red, because it put a
second demonstration into an outcome section where the locked runner requires
exactly one. A green gate at the code commit is not a green gate at the closure
candidate.

Each run names the EXACT versions its lane ran, and `mix loopex.matrix` compares
them by equality on a parsed field rather than by searching text. Every run in the
block must be green with exit zero: asking only whether SOME run recorded a pair
green let a failing run sit beside a passing one and be ignored. Evidence a check
accepts loosely is evidence the check does not really constrain, and narrowing
what it accepts one spelling at a time leaves the next spelling accepted — which
is what six earlier versions of this check each discovered in turn.

`mix loopex.matrix` requires this file to name every locked pair with a green
verdict. It cannot verify that a recorded run happened, and says so; that judgment
is review's.

## What the floor lane was worth

It is the reason the two-pair rule exists, and it earned its place here rather
than merely satisfying a rule. The three findings below were made under the
earlier floor pair, Elixir 1.17.0 with OTP 26.0; they are retained because they
are why the lane exists, not because they describe the runs recorded above.
Running that lane found two defects the current pair could not have surfaced,
both of which would have shipped:

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
temporary build directory. Both lanes were then run in both orders and each after
itself, five runs, all green -- which is what proved that repair, because a
per-lane green proves nothing about ordering. Those five runs belong to that
earlier floor pair and that earlier candidate; the refreshed pair's runs are the
two recorded above.
