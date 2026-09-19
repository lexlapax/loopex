# Verification — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Verification](verification.md#concept).

Measurements below were taken at `main` after M4 closure (`d609b98` for the
check runs, `dabca37` for the slowest-test run), on the Mac (Darwin arm64,
Elixir 1.20.3 / OTP 29.0.5, Homebrew) and on the Linux host serenity (x86_64,
same pair via mise). Logs are retained by the maintainer.

<a id="technical-verification-stages"></a>
### What each stage runs

Concept: [Three stages](verification.md#concept-verification-stages).

| Stage | Command | Measured |
| --- | --- | --- |
| Change, while editing | `mix test <path>`, `mix format`, `mix compile --warnings-as-errors`; the client Stop hook runs format, the dependency budget and the adapter check | Seconds |
| Change, before merge | `bash scripts/check.sh` in hosted CI on the branch; a read-only review of `git diff main..<candidate>` | 870 s Mac and 809 s Linux in sequence; 18 s before the suite starts; see the plan below for the parallel runner |
| Close | `bash scripts/check.sh` under the floor pair (`mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh`), `bash scripts/check-release.sh` once on the current pair | Release check: 149–163 s on Linux, 12 tests |
| Release | None new; the tag names the integrated closure commit | — |

`check.sh` step order and cost: warning-free compilation 1 s (warm), formatting
1 s, repository structure 11–14 s (client adapters, ignore policy, commit
messages, hygiene, `mix loopex.status` at 3 s), dependency budget 2–3 s, one
version 0–1 s, documentation ordering 1 s, then `mix test`.

Hosted CI: `.github/workflows/agent-bootstrap.yml` runs `bash scripts/check.sh`
after an Elixir/OTP setup step with the current pair and `mix deps.get`, on
every push to `main` and every pull request, checking a pull request out at
its own head. It is a thin wrapper over the repository command, and the
adapter check pins its shape.

Evidence retention: a closure keeps one page under `docs/evidence/` naming the
candidate, each run's platform, toolchain, result and measured duration, as
[M4 closure runs](../evidence/M4-closure-runs.md) does. Complete logs stay
with the maintainer outside the repository; the page records identities, not
output.

<a id="technical-verification-selection"></a>
### The selection table, mechanically

Concept: [Selection](verification.md#concept-verification-selection).

| Boundary | Where its checks live |
| --- | --- |
| Store port | `apps/loopex_store_local/test/` conformance and fault-injection cases, `apps/loopex/test/` recovery and `commit_unknown` cases; old-reader refusal in `interaction_lifecycle_test.exs` |
| Model port | `apps/loopex_llm_reqllm/test/` adapter, streaming conformance, credential plane; the `real_provider` cases |
| Executor port | `apps/loopex_executor_local/test/` authority, receipts, cancellation, coding tools; `apps/loopex/test/cancellation*_test.exs` |
| Wire protocol | `apps/loopex_protocol/test/` vectors and negotiation, `apps/loopex_app_server/test/`, `clients/node/vectors.mjs`; `docs/developer/compatibility-surfaces.md` |
| Skills and project resources | `apps/loopex_composition/test/`, `apps/loopex/test/skill_context_test.exs`, `context_admission_test.exs` |
| Observability | `apps/loopex/test/trace_session_test.exs`, `telemetry_boundary_test.exs`, `apps/loopex_telemetry/test/` |
| Dependency direction | `mix loopex.deps_budget` and `apps/loopex/test/deps_budget_test.exs` |
| Documentation chain | `mix loopex.status`, `mix loopex.docs_check` |

<a id="technical-verification-speed"></a>
### Measurements and plan

Concept: [Making it fast](verification.md#concept-verification-speed).

**Where the 852 s go (Mac, `check-mac-d609b98`).** The suite is 852 s of the
870 s push check. Per application, with the share ExUnit ran serially:

| Application | Tests | Wall | Serial | Literal `Process.sleep` in tests |
| --- | --- | --- | --- | --- |
| `loopex` | 545 | 304.6 s | 277.2 s | 79 calls |
| `loopex_llm_reqllm` | 178 | 237.3 s | 236.6 s | 14 calls, 0.3 s total |
| `loopex_executor_local` | 190 | 145.6 s | 145.6 s | 36 calls |
| `loopex_cli` | 148 | 107.0 s | 107.0 s | 53 calls |
| `loopex_composition` | 35 | 25.3 s | 3.5 s | 2 |
| `loopex_app_server` | 75 | 17.4 s | 16.5 s | 6 |
| `loopex_store_local` | 69 | 10.1 s | 8.5 s | 2 |
| the other three | 85 | 3.7 s | 3.5 s | 0 |

Linux is 5–10% faster per application and has the same shape.

**Why the modules are serial.** Of 115 test modules, 28 are asynchronous.
The serial ones carry one or more of: VM-global tracing (`trace_session`,
`context_admission`, `provider_attempt_protocol`, most of the executor's
authority tests), environment variables read by child processes (`cli`,
`llm_reqllm`, `session_directory`), registered process names (`runtime_test`,
`tool_registry`, `interaction_lifecycle`), telemetry handlers
(`telemetry_boundary`), or operating-system children built from clean source
(`cli`, `coding_tools`). Those reasons are real; the modules without any of
them are the candidates for step 3.

**Where the serial time goes (Linux, `--slowest 25`).** The 25 slowest tests
are 80% of `loopex`, 83% of `loopex_executor_local`, 64% of
`loopex_llm_reqllm` and 91% of `loopex_cli`. The tail is cheap; the head is
tests that wait for a real-time bound:

| Test | Waits for | Measured |
| --- | --- | --- |
| `cancellation_observation_contract_test.exs:377` | a callback delayed past the 60 s legacy cancel bound (`Executor.@cancel_bound_ms`) | 60.5 s |
| `cancellation_test.exs:1010` | a host cancellation that never answers, bounded at 60 s | 60.0 s |
| `provider_attempt_adapter_contract_test.exs:284` | transport deadline | 16.2 s |
| `admission_observation_wait_test.exs:53` and `:21` | literal 15 s and 10 s clock waits | 25.0 s |
| `provider_attempt_protocol_test.exs:1862` | permit deadline | 13.5 s |
| `provider_startup_boundaries_test.exs:25`, `credential_plane_test.exs:551`, `provider_retainer_boundaries_test.exs:146`, `provider_bridge_test.exs:294,352`, `provider_backpressure_test.exs:79` | 10 s provider deadlines | 10–12 s each |
| `deps_budget_test.exs:913` | the offline lock materializer | 10.2 s |
| `skill_acquisition_test.exs:149`, `external_workflow_test.exs:452` | a real Git import; a real server abort and restart | 11.6 s each |
| `foundation_workflow_test.exs:89,167,198,238` | the CLI built from clean source and run as a process | 7–10 s each |
| `prepared_recovery_contract_test.exs:547,931`, `executor_test.exs:1520`, `local_authority_contract_test.exs:1508`, `coding_tools_test.exs:4792` | 5–7 s bounds and quiescence windows | 6–8 s each |

The 60 s sleeps found by grep are almost all fixtures that never answer
(policies that hang, a worker that must be abandoned); they cost the bound the
test expects, not the sleep. The two that do cost a minute are the two rows at
the top.

**Step 1, done and measured.** `check.sh` compiles the test build once, then
runs each application's suite in its own VM, a bounded number at a time,
heaviest first, keeping each log and printing it only on failure. The trial
that justified it ran the four heavy applications at once on the Mac in 312 s
wall against 795 s in sequence. The finished runner: 315 s on Linux and 346 s
on the Mac for the whole check, every application green with the counts
unchanged, against 809 s and 870 s in sequence.

**Step 2, done and measured.** Each slow test was classified rather than
shortened blindly. Three whose claim is the real duration — the callback past
the legacy 60 s cancel bound, and the two admission waits that prove removed
cutoffs are absent — keep it, tagged `long_bound`, excluded from the fast
check and run by the release check in a pass of their own. The rest had their
bound injected where it is armed, with the production default asserted once:
the cancel case now observes the 10 s floor bound and reads the 60 s default
by tracing the call that arms it; the provider deadlines are committed at 2–4 s
in the request each case builds; `claim_wait_ms` became a trusted-local start
option of the local executor, default 5 000 ms asserted. Eight tests were left
slow with the reason recorded beside them (a real Git import, a CLI built from
source, a fixed grace derived from the ledger's fsync allowance). Result:
`loopex` 305 → 194 s, `loopex_llm_reqllm` 237 → 198 s, `loopex_executor_local`
146 → 111 s, `loopex_cli` 107 → 109 s; the whole fast check on the Mac 256 s.

**Step 3, in progress.** Modules with none of the serial markers above can be
tried asynchronous one at a time, keeping each only if the application's suite
stays green across several seeds. `loopex_llm_reqllm` (212 s, 178 tests,
almost all serial) is now the long pole, so it is where the gain is.

**Test hygiene noted by the earlier audit, still open.** A transfer-memory
witness in `artifact_transfer_test.exs` measures chunk size rather than
retained memory; a reference-client test fixes three private struct fields.
Both are evidence-quality items to fix when those tests are next touched, not
speed items.

**Accounting.** The share of development time spent on verification is not
measured. The proposal's suggestion stands: count test development, tooling,
review and waiting separately across the next milestone, from command timings
and rough effort estimates, before claiming the one-fifth target is met.
