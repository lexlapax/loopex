<a id="technical-depth"></a>
## Technical depth

Concept: [M6 minimal runnable Loopex](M6.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](M6.md#concept-plan-purpose).

Concept: [Design decisions](M6.md#concept-plan-decisions).

Concept: [Non-goals](M6.md#concept-plan-non-goals).

M6 waits on one decision. It is accepted before the implementation that depends
on it, not before unrelated work, and it may not be outstanding at closure. The
repository status check reads the links in this section, so a decision named
only in prose declares nothing.

| Decision | Acceptance point | What its acceptance settles |
| --- | --- | --- |
| [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept) | Before the in-process model adapter, the memory store or the ephemeral composition is written. Outcome 6 and the read-only tools do not wait on it | Outcomes 1 to 4: the two profiles, the memory store's truth statement, the adapter and its credential rule, the default model, the authority rule |

**The closure prerequisite, satisfied.** M5 closed on 2026-09-26 at the tested
implementation `fe020e24b62504f6f2fbc6c81711f399803b6fa9` (administrative
closure `3f81b04828901a6fb05b29e8b6bed211eed2d376`, tag `v0.2.0`).

**Deferrals.** No M6 outcome waits on these, and M6 runs no part of them:

- ADR 0035 stays Proposed and wholly deferred.
- ADRs 0036, 0037 and 0038 stay Proposed as prerequisites of the M7 and M8
  drafts.

<a id="technical-plan-ownership"></a>
### Ownership and Rejoin

Concept: [Scope](M6.md#concept-plan-scope).

| Workstream | Owns | Depends on | Rejoin order |
| --- | --- | --- | --- |
| A. Model and store | The in-process adapter in `apps/loopex_llm_reqllm/lib/loopex/llm/` beside `req_llm.ex`; `Loopex.Store.Memory` and its artifact half as an edge module, promoted from `apps/loopex/test/support/m1_runtime_helper.exs`; their conformance runs | ADR 0039 | First: every later lane composes them |
| B. Composition and facade | The ephemeral entry in `apps/loopex_composition`; `run/2`, `start_session/1`, `ask/2`, `history/1`, `stop_session/1` in `apps/loopex/lib/loopex.ex` | A | Second |
| C. Command and tools | The `-p` form, flags, stdin, output modes and exit map in `apps/loopex_cli`; `grep`, `find`, `ls` and the `:read_only` preset in `apps/loopex_executor_local` | B for `-p`; none for the tools | Third |
| D. Closure tooling and documentation | Repository commands under `scripts/` or Mix tasks for the pre-tag proofs, floor preconditions and attended release; the getting-started paths and changed pages; the closure evidence scaffold | Outcome 6 is independent; documentation follows A–C | Last |

One integrator owns rejoin, conflicts and post-rejoin verification. Parallel
writers use one worktree each with non-overlapping paths. The acceptance
demonstration script is written by the integrator first and is the rejoin
check for every workstream.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M6.md#concept-plan-outcomes).

Concept: [How each outcome is verified](M6.md#concept-plan-verification).

| # | Witness files | What they prove | Lane |
| --- | --- | --- | --- |
| 1 | `apps/loopex/test/facade_run_test.exs` (new), `apps/loopex/test/facade_session_test.exs` (new) | One-call answer and multi-turn `ask/2` with a scripted model; `{:error, :max_steps}`; a failed tool result reaches the next model call; `history/1` returns the committed conversation; `stop_session/1` ends the session | fast |
| 2 | `apps/loopex_llm_reqllm/test/in_process_adapter_test.exs` (new), the existing streaming conformance suite run against the new adapter, `apps/loopex_llm_reqllm/test/in_process_real_test.exs` (new, tagged `real_provider`) | Request and reply mapping, including tool calls and deltas; provider selection by string; `provider_credential_required` naming the variable; a canary credential absent from every record, event, progress item, diagnostic and log line; real calls to Ollama and one hosted provider | fast; release |
| 3 | `apps/loopex_store_local/test/support/store_conformance_helper.exs` run against `Loopex.Store.Memory`, `apps/loopex_composition/test/ephemeral_profile_test.exs` (new) | The memory store passes the unchanged conformance suite; the ephemeral entry refuses without a policy, removes its temporary root on stop, and names its profile in the effective options | fast |
| 4 | `apps/loopex_cli/test/print_mode_test.exs` (new), `apps/loopex_cli/test/print_mode_exit_test.exs` (new), `apps/loopex_executor_local/test/read_only_tools_test.exs` (new), an agent-delegation release lane | Flag grammar, a prompt from stdin, text and JSON output, one JSON object per run, the exit status for each outcome, skill directories by path, no home required, `--state-root` selecting the durable profile; `grep`, `find` and `ls` bounds and refusals; another agent drives `-p` and the app server | fast; release |
| 5 | The M5 suites and release lanes, unchanged; `mix loopex.deps_budget` | The durable profile is unchanged; the companion adapter still refuses in-VM operation; core's dependency list is `:telemetry` alone | fast; release |
| 6 | The new repository commands and their tests | The confinement proof, archive staging and comparison, and floor preconditions reproduce the M5 closure's proofs on a fixture repository; M6's own closure uses only them | fast; closure |

**Evidence rules.** Every derived number has an executed witness before
closure: the exit statuses, the output bounds and the default step limit. Every
release lane retains its complete output with a stable reference and a SHA-256
digest, recorded in `docs/evidence/M6-closure-runs.md`, which the tested
candidate creates and indexes as a scaffold.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

| Surface | M6 change | Label |
| --- | --- | --- |
| Embedded Elixir API | Five facade functions added; every existing function unchanged | Experimental |
| Command line | The `-p` form and its flags added; every existing subcommand unchanged | Experimental |
| Model strings (ephemeral profile) | New `provider:model` grammar | Experimental |
| Private journal and store schema | Unchanged; the memory store holds the same records in memory | Private; unchanged |
| Public session protocol | None; generations 1 and 2 unchanged | Experimental, unchanged |
| Executor protocol | Three read-only tools added behind the existing tool contract | Unchanged contract |
| Toolchain | Both pairs; the floor pair still passes the fast check | Unchanged |

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

| Item | M6 answer |
| --- | --- |
| Supported source and target versions | `0.2` roots open unchanged under `0.3`; there is no new root format |
| Forward migration | None |
| Migration between profiles | None; an ephemeral session is never promoted to a durable one |
| Backup and restore or downgrade policy | Unchanged from `0.2`; the `0.2` binary opens every root `0.3` writes |
| Exact rollback | Return to `v0.2.0`; no durable byte depends on the ephemeral profile |

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

No new application:

- the memory store is an edge module;
- the in-process adapter sits in the application that already carries ReqLLM;
- the composition entry is in `loopex_composition`;
- the command form is in `loopex_cli`.

If the maintainer prefers the memory store in its own application at
acceptance, it takes role `:edge`, depending inward on core only, and the
dependency budget's inventory changes in the same reviewed change. Core's
dependency list stays `:telemetry` alone. `VERSION` moves to `0.3.0`. The
escript build stays as it is; an escript that composes only the ephemeral
profile needs no companion build.

**Minimalism budget.**

- **Facade:** only wrappers over the existing public facade.
- **Adapter:** one module mapping the model port to ReqLLM.
- **Store:** the test fixture's semantics, promoted, not rewritten.
- **Command form:** one parser branch and one renderer mode.
- **No additions:** no configuration framework, no second loop and no new
  process type.
