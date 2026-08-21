# M0 Toolchain Matrix

Retained by outcome 3. ADR 0002 validates two (Elixir, OTP) pairs rather than a
cross-product, and one Mix run has one Erlang runtime, so the gate runner is
invoked once per pair and every run is recorded here. Both orders are run, and
each pair is also run after itself, because a per-lane pass proves nothing about
ordering — a shared build directory once made the second lane fail on beams the
first had compiled.

- runs taken at: `7451bb649f637a335140065745548d24af2ae104` (the code commit; the
  closure candidate is a later commit carrying this file, which is why the gate
  is re-run there rather than trusting these rows)
- gate digest: `sha256:6e02cd424bab8e3410205ca053adce150ee9fa1a84d7b6f5b032390c4529e09f`
- command: `bash scripts/check-m0-gate.sh`, with `LOOPEX_PROVIDER_API_KEY` set, the
  floor pair supplied by `mise exec erlang@26.0 elixir@1.17.0-otp-26 --`
- host: macOS arm64; both pairs provided by `mise`
- recorded: 2026-08-21

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
run=1 order=first elixir=1.17.0 otp=26.0 erts=14.0 verdict=GREEN exit=0 wall=91s
run=2 order=second elixir=1.20.3 otp=29.0.5 erts=17.0.5 verdict=GREEN exit=0 wall=103s
run=3 order=third elixir=1.20.3 otp=29.0.5 erts=17.0.5 verdict=GREEN exit=0 wall=68s
run=4 order=fourth elixir=1.17.0 otp=26.0 erts=14.0 verdict=GREEN exit=0 wall=93s
run=5 order=fifth elixir=1.17.0 otp=26.0 erts=14.0 verdict=GREEN exit=0 wall=60s
```
<!-- loopex:matrix-runs:end -->

The previous candidate's runs are superseded rather than kept alongside these.
Product bytes changed, which invalidates the evidence taken before them; a record
carrying runs from two revisions invites a reader to count runs that were never
all true of one tree.

Runs 1 and 2 are floor-then-current; runs 3 and 4 reverse that; run 5 follows the
floor lane with itself. The four adjacencies present are therefore floor-current,
current-current, current-floor, and floor-floor -- each pair immediately after
itself and immediately after the other.

Run 5 exists because the previous table asserted exactly that sentence while the
runs were floor, current, current, floor: there was no floor-after-floor anywhere
in it. The cheaper repair was to narrow the claim to what had been run. Running
the missing lane was chosen instead, because the sentence describes the coverage
the outcome is supposed to have, and the shared-build-directory defect it exists
to catch is not the only way two lanes can interact. With no
`LOOPEX_PROVIDER_API_KEY` present the same runner stops at outcome 7 reporting
evidence unavailable rather than skipping, which is the fail-closed direction.

These runs were executed on the code commit named above with the retained-evidence
edits of that round already present in the working tree. They did not observe this
file as it now stands: the recorded-runs block, the header above it, the adjacency
narration describing run 5, and the verdict-handling paragraph below were all
written or rewritten after them. An earlier version of this sentence claimed the
runs were the only difference, which was not true even when written. This file and
the self-hosting evidence are then written
in the commit immediately after the candidate: there is no way to record a run
inside the commit the run observed. That residual gap is stated rather than
papered over, and it is why the gate expects a reviewer to re-run at the closure
candidate rather than trust a retained verdict.

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
temporary build directory. Both lanes were then run in both orders and each after
itself, five runs, all green -- which is the evidence that matters here, because a
per-lane green proves nothing about ordering.
