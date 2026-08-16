# M0 Gate

Locked executable acceptance for milestone `M0`. This file's canonical UTF-8/LF
text and its SHA-256 digest are bound at acceptance and immutable for the
milestone. Plan progress and evidence links change without touching these bytes.

Concept plan: `docs/plans/M0.md`. Technical depth: `docs/plans/M0-technical.md`.

Every command form below was executed against a disposable umbrella scaffold
before this gate was proposed. That check exists because a previous version of
this gate locked repository-root test paths, which an umbrella root never runs:
`mix test test/x_test.exs` produced no output and exited zero, leaving four
outcomes permanently unprovable. A gate nobody has run is a hypothesis.

## Runner

```text
bash scripts/check-m0-gate.sh
```

The runner executes every command below in order and fails on the first
unsatisfied requirement. It is separate from `scripts/check-bootstrap.sh`, which
must remain green throughout the milestone.

## Bound Artifacts

The gate document alone governs nothing executable: replacing the runner with a
command that exits zero would leave this file's digest valid. These artifacts
are therefore bound by content, and the repository status check verifies each
against the file it names at every validation.

| SHA-256 | Path |
| --- | --- |
| `535496b8afa97291c177e7c2c2de92c9dc98d32796e8d66d4061295cda4126f9` | `scripts/check-m0-gate.sh` |
| `f26287082f2f58ff9f1e08acc0b87f472f3c79556dbf4f2c15fad76b47280d1d` | `.tool-versions` |

Changing either file changes its digest, which changes this document, which
changes the accepted gate digest. After acceptance that requires the authority
that accepted it.

## Locked Commands

| # | Command | Proves |
| --- | --- | --- |
| 1 | `mix format --check-formatted` | Formatting is clean across both applications |
| 2 | `mix compile --warnings-as-errors` | The checkpoint is warning-free |
| 3 | `mix loopex.deps_budget` | Outcome 1: dependency budget and one-way direction |
| 4 | `mix loopex.version_train` | Outcome 1: both applications carry one version |
| 5 | `mix test apps/loopex/test/deps_budget_test.exs` | Outcome 2: forbidden dependency, reverse edge, dynamic reference |
| 5a | `mix loopex.core_only` and `mix test apps/loopex/test/core_only_test.exs` | Outcome 9: fakes-only lane, no adapter started, no per-runtime application environment |
| 6 | `mix loopex.matrix` | Outcome 3: both locked pairs run individually |
| 7 | `mix test apps/loopex/test/journal_replay_test.exs` | Outcome 4: journal replay across a restart |
| 8 | `mix test apps/loopex/test/fencing_test.exs` | Outcome 5: fencing and reconciliation across a restart |
| 9 | `mix test apps/loopex/test/vm_code_spike_test.exs` | Outcome 6: isolated VM load and rollback |
| 10 | `mix test apps/loopex_llm_reqllm/test/provider_test.exs --only real_provider` | Outcome 7: real model call from the adapter application |
| 11 | `mix loopex.self_hosting` | Outcome 8: absence, inventory, hook behavior, measurement |
| 13 | `mix test` | The full suite |

Selectors are application-relative because an umbrella root runs no tests of its
own. Command 10 is path-scoped for the same reason: `mix test --only <tag>` at
the root recurses into applications with no tagged tests and exits zero having
run nothing.

## Protected Tests and Selectors

These selectors are protected: they may be extended but never removed, renamed,
skipped, filtered, quarantined, or weakened while `M0` is open.

An exit code proves a command ran, not that it did anything. Each selector
carries a locked minimum of **executed** tests and a list of test names that
must exist, both enforced by the runner. ExUnit counts skipped tests inside its
total, so a `@tag :skip` test would satisfy a naive minimum without running:
the runner subtracts skipped tests and rejects any skip on a protected
selector outright.

| Selector | Minimum tests | Locked test names |
| --- | --- | --- |
| `apps/loopex/test/deps_budget_test.exs` | 3 | `a forbidden core dependency is rejected`; `a reverse edge from contract to runtime is rejected`; `a dynamic module reference across the boundary is rejected` |
| `apps/loopex/test/core_only_test.exs` | 2 | `core starts with no adapter application resolved or started`; `per-runtime state is not read from application environment` |
| `apps/loopex/test/journal_replay_test.exs` | 2 | `replay after an induced restart reconstructs the same durable state` |
| `apps/loopex/test/fencing_test.exs` | 2 | `commit_unknown is fenced and never dispatched a second time`; `a stale completion is rejected after a coordinator restart` |
| `apps/loopex/test/vm_code_spike_test.exs` | 1 | `a trusted generation loads and rolls back in an isolated VM` |
| `apps/loopex_llm_reqllm/test/provider_test.exs --only real_provider` | 1 | — |

Minimums and names may be raised or extended by stricter append-only coverage
with independent gate review. They may never be lowered while `M0` is open.

## Toolchain Matrix

A single in-process Mix task cannot run two Erlang runtimes. Command 6 therefore
verifies that the **running** toolchain matches one of the locked pairs and that
both pairs are recorded as run; the gate runner is invoked once per pair by the
operator or CI under the corresponding toolchain. A run under an unlisted pair
fails, and a claim of both lanes without two recorded runs fails. The exact pairs are the
`.tool-versions` bytes bound above:

```text
floor pair    Elixir 1.17.3 with OTP 26.2.5
current pair  Elixir 1.19.5 with OTP 28.1
```

Changing a version changes those bytes and requires an amendment to ADR 0002,
not a gate edit. A green run on one pair is not evidence for the other, and a
green run on an unlisted pair satisfies neither lane.

## Evidence Classes

| Outcome | Required class | Substitution is not permitted |
| --- | --- | --- |
| 1, 2 | Structural check plus adversarial fixture | A passing happy path alone |
| 3 | Per-pair matrix run | One pair standing for both |
| 4 | Property tests, process fault injection, and a negative demonstration | Clean-shutdown replay |
| 5 | Fault injection, a no-second-dispatch assertion, and a negative demonstration | Retry-until-success |
| 6 | Isolated-VM demonstration and a negative demonstration | A same-VM reload |
| 7 | Real-provider run with retained identity | A fake adapter |
| 8 | Absence, inventory, and behavior proofs | Equivalence with the bridge present |
| 9 | Compiled-documentation check | A source-text grep |

## Real-Provider Lane

Command 10 is excluded from the default suite and runs only when invoked
explicitly. The credential is read from the environment and never written to a
journal, fixture, log, snapshot, diagnostic, or committed byte.

The lane retains non-secret provider, model, and endpoint-class identity in
`docs/evidence/M0-provider.md`, which the runner requires. A missing
credential reports evidence unavailable and exits non-zero; it never reports
success, and a skipped lane is not a pass. Because a tagged run exits zero
having executed nothing, the runner requires at least one executed test.

## Self-Hosting

The runner proves absence and inventory itself rather than delegating them to
the task under test, because a task cannot be the evidence for its own
retirement. It shadows `python3` and `jq` with stubs that refuse to run and
requires the aggregate to complete anyway, then inspects the tree directly and
scans for absolute or `env`-resolved invocations that shadowing cannot
intercept. Dropping directories from `PATH` is not used: it would also remove
`git` and fail for the wrong reason.

Command 11 covers four separable things and fails on any of the first three:

1. **Absence.** The aggregate runs to completion while `python3` and `jq` are
   shadowed by stubs that refuse to run. Shadowing intercepts PATH lookups only,
   so the runner additionally scans for absolute paths, `env`-resolved calls,
   `command -p`, and inline `PATH=` assignments, none of which a shim can catch.
2. **Inventory.** Every named bridge component is gone from the tree:
   `scripts/check_status.py`, `scripts/test_check_status.py`,
   `scripts/check-agent-bootstrap.py`, the `python3` invocations in
   `scripts/check-status.sh` and `scripts/check-agent-bootstrap.sh`, and the
   `jq` invocations in `scripts/check-agent-bootstrap.sh`,
   `.claude/hooks/guard-bash.sh`, `.claude/hooks/after-edit.sh`, and
   `.claude/hooks/guard-filesystem.sh`.
3. **Preserved hook behavior.** Locked fixtures in `scripts/fixtures/hook-cases`
   are executed against each migrated hook, and every one must still be
   rejected. At least three fixtures run, one per migrated hook. This is proved
   by execution, not by the task's exit status. Removing a behavior instead of
   migrating it requires an explicit disposition recorded against outcome 8.
4. **Measurement.** The command reports the replacement's measured size and the
   behaviors dropped from the bridge, with reasons.

Shell is not retired. The enduring baseline is Git, shell and POSIX tools, and
the accepted Elixir/OTP toolchain, so a check may remain a shell entrypoint that
calls Mix.

The retiring bridge measures 3,990 lines at the gate commit:

```text
1893  scripts/check_status.py
1858  scripts/test_check_status.py
   8  scripts/check-status.sh
 231  scripts/check-agent-bootstrap.py
3990  total
```

**That figure is audit and review material, not a pass condition.** Requirement 4
reports; it does not threshold. A line ceiling would reward compressed code,
hidden complexity, and deleted coverage, so an independent reviewer weighs the
measurement against the dropped-behavior list instead.

## What This Gate Cannot Prove

Stated plainly so the closure reviewer knows where to look, rather than implying
the runner covers it.

A locked test name and a minimum count prove that a test with that name ran.
They cannot prove it asserts anything: `assert true` satisfies both. A custom
Mix task's exit code proves it ran, not that it inspected anything. The
real-provider lane's retained identity record proves a record exists, not that a
network call happened. No structural rule closes these, because meaning is not a
property of structure.

Two things carry that weight instead. Outcomes 4, 5, and 6 require a **negative
demonstration** recorded in `docs/evidence/M0-negative-demonstrations.md`: the
protected test is shown to fail when the mechanism it covers is disabled. The
runner requires the record and rejects unpopulated fields; it cannot disable a
mechanism itself, so a reviewer judges whether the demonstration is real. The second is
independent review of the implementation at the closure candidate, which is
already required.

This gate makes faking obvious; it does not make it impossible.

## Failure Rules

Never skip, filter, soften, quarantine, rewrite, inflate a retry or timeout, or
substitute a fake for a required real path to make this gate pass. Stricter
append-only coverage advances the lock and requires independent gate review.

A retry is diagnostic. A failure that disappears on the same commit, seed, and
environment is a blocking flake until fixed or explicitly dispositioned. An
environment failure means evidence is unavailable, never PASS.

## Declared Red Condition

At the gate commit no Mix project exists, so the runner stops at the first
scaffold check. That is the declared missing behavior this gate exists to prove
absent. `bash scripts/check-bootstrap.sh` remains green at the same commit.
