# M4 closure runs

The check runs retained for the M4 closure candidate, each named by the exact
source revision, platform and toolchain it ran at. Complete logs are kept by
the maintainer outside the repository; this page records the identities and
results. Back to the [evidence index](README.md).

## Candidate

`d609b98c` — `build(M4): recompile the version readers when VERSION changes`,
source `VERSION` `0.1.0`. Every run below used this exact committed tree.

## The fast check, `bash scripts/check.sh`

| Platform | Toolchain | Result | Measured |
| --- | --- | --- | --- |
| macOS (Darwin arm64) | Elixir 1.20.3 / OTP 29.0.5 (Homebrew) | PASS, 1,388 tests, 0 failures | 870 s total, of which the test suite 852 s |
| Linux (serenity, x86_64) | Elixir 1.20.3 / OTP 29.0.5 (mise) | PASS, 0 failures | 809 s total, of which the test suite 783 s |

Both runs cover warning-free compilation, formatting, repository structure
(client adapters, ignore policy, commit messages, hygiene, and the current-tree
status check), the dependency budget and direction, one version across the ten
applications, documentation ordering, and the credential-free suite.

## The release check, `bash scripts/check-release.sh`

The tests tagged `real_provider` and `node_client`, run on macOS with the
credential in the environment and Node 22.14.0 on the path.

| Scope | Result |
| --- | --- |
| Unattended: `loopex_protocol` Node vectors (1), `loopex_app_server` (5: the independent client's session, skill and interaction workflows, the fresh-source extraction, and the real-provider end-to-end workflow), `loopex_reference_client` real sessions (2), `loopex_llm_reqllm` real provider (1) | 9 passed |
| Attended: the `loopex_cli` real-provider tests including the public-skill workflow with its two operator trust decisions | passed on Linux after closure, see below |

The real-provider end-to-end workflow observed provider `anthropic`, model
`claude-haiku-4-5-20251001`, endpoint `https://api.anthropic.com`, with two
replies carrying distinct provider response identifiers. It drove skill
selection under an operator trust decision, a deferred policy question and its
answer, policy re-evaluation and the tool run after the answer committed, a
verified bounded artifact transfer, and an abrupt server loss followed by a
fresh-process resume, all through the Node consumer.

## The release check after closure, on Linux

Run on serenity (Linux x86_64, Elixir 1.20.3 / OTP 29.0.5, Node 22.14.0) at
`23402ec4`, the closure commit plus three follow-ups: the credential restored
after the reference client's recovery test, and the release check running each
application in its own VM and skipping applications with no release test. The
two operator prompts were answered on the terminal. Result: PASS, 12 tests
(`loopex_app_server` 5, `loopex_cli` 3, `loopex_llm_reqllm` 1,
`loopex_protocol` 1, `loopex_reference_client` 2), 149 s. The first attempts
at `3e6ee5d` found that the recovery test deleted the credential from the
shared test VM, which left every later real-provider test without one; that is
the defect the follow-ups fixed.

The maintainer then ran the same command themselves on serenity at
`dabca373`, answering both prompts on the terminal: PASS, the same 12 tests,
163 s, with the public-skill workflow observing two real provider replies.

## The floor toolchain pair, after closure

The closure runs above were all on the current pair; the floor pair (Elixir
1.18.5 / OTP 27.3.4) had not been run on M4's product. Its first run, on
serenity at `23402ec4`, failed 640 tests across four applications with
`module :crypto is not available`: Mix on that pair prunes OTP applications no
application declares, and seven applications called `:crypto` without
declaring it, which the current pair never showed. With the declarations
added (`478fe1e`) and the contract's runtime-closure test updated
(`11c41bb`), the floor run passed: PASS, 0 failures in every application,
888 s on serenity. The same commit passed the current pair on the Mac in
963 s. `scripts/check-otp-applications.sh` now enforces the declaration on
every run of the fast check.

## The fast check after the speed work

At `031554c` (the parallel runner merged) and `e8a1ac3` (the time-bound
work merged), `bash scripts/check.sh` on the current pair: Linux 315 s
(runner alone, all ten applications green), Mac 346 s (runner alone), Mac
256 s (runner and bounds), against 809 s and 870 s in sequence at closure.
The three long-duration bound proofs run in the release check's own pass.
