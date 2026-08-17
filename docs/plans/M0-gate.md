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

The commands below are an **inventory, not a sequence**. The runner defines the
execution order and fails on the first unsatisfied requirement; the table lists
what must pass, not when. It is separate from `scripts/check-bootstrap.sh`, which
must remain green throughout the milestone.

## Bound Artifacts

The gate document alone governs nothing executable: replacing the runner with a
command that exits zero would leave this file's digest valid. These artifacts
are therefore bound by content, and the repository status check verifies each
against the file it names at every validation.

| SHA-256 | Path |
| --- | --- |
| `26fa0e5db41cab042a0c0e8343acf35891b99778a9b3bddaa43ff36414b25307` | `scripts/check-m0-gate.sh` |
| `fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999` | `.tool-versions` |
| `ef67304cbf2e3be1f424eb6bad463a12a61538aaeee953f4bf8f16574759be9a` | `scripts/fixtures/hook-cases/guard-bash.stdin` |
| `94538072921e9a56fb62f402766979ee7872df952228bd5ca8baaccaffe8729e` | `scripts/fixtures/hook-cases/guard-filesystem.stdin` |
| `2611b0bdfdaefd9dec75a5afd6cf9325d8666ec360ce40a68b290df36add80db` | `scripts/fixtures/hook-cases/after-edit.stdin` |
| `8d9984304a3f9176c25039ac3639c7c368f2b99784b7c645bcce2989f05947cf` | `scripts/fixtures/deps-budget-invalid/mix.exs` |

The hook fixtures are bound too. They must exist at acceptance: a fixture
created afterwards cannot establish what acceptance agreed to, and closure
review can judge whether a fixture is meaningful but cannot retroactively fix
when it appeared.

Changing any bound file changes its digest, which changes this document, which
changes the accepted gate digest. After acceptance that requires the authority
that accepted it.

## Locked Commands

| # | Command | Proves |
| --- | --- | --- |
| 1 | `mix format --check-formatted` | Formatting is clean across every application, with an `apps/**` glob proven to sit inside `.formatter.exs` `inputs` rather than merely appearing in the file |
| 2 | `mix compile --warnings-as-errors` | The checkpoint is warning-free across every application |
| 3 | `mix loopex.deps_budget` | Outcome 1: dependency budget and one-way direction |
| 3b | `mix loopex.hook_registration` | Outcome 8: each hook is registered under its required event and matcher, checked structurally rather than by string presence |
| 3c | `mix loopex.format_scope` | Outcome 1: the effective formatter configuration resolves to application sources |
| 3d | `mix test apps/loopex/test/hook_registration_test.exs` | Outcome 8: the registration task rejects a wrong event and a wrong matcher |
| 3e | `mix test apps/loopex/test/format_scope_test.exs` | Outcome 1: the scope task rejects a root-only configuration |
| 3a | `.claude/hooks/deps-budget.sh` | Outcome 2: exists, calls `mix loopex.deps_budget`, and carries no inline budget logic — no `apps/loopex/mix.exs` path handling and no `deps` definition of its own |
| 4 | `mix loopex.version_train` | Outcome 1: every application carries one version |
| 5 | `mix test apps/loopex/test/deps_budget_test.exs` | Outcome 2: forbidden dependency, reverse edge, dynamic reference |
| 5a | `mix loopex.core_only` and `mix test apps/loopex/test/core_only_test.exs` | Outcome 9: fakes-only lane, no adapter started, no per-runtime application environment |
| 5b | `mix loopex.docs_check` | Outcome 10: compiled dual-depth documentation, as the development contract requires |
| 5c | `mix test apps/loopex/test/history_anchoring_test.exs` | Outcome 8: the replacement still anchors bound artifacts across history |
| 6 | `mix loopex.matrix` | Outcome 3: both locked pairs run individually |
| 7 | `mix test apps/loopex/test/journal_replay_test.exs` | Outcome 4: journal replay across a restart |
| 8 | `mix test apps/loopex/test/fencing_test.exs` | Outcome 5: fencing and reconciliation across a restart |
| 9 | `mix test apps/loopex/test/vm_code_spike_test.exs` | Outcome 6: isolated VM load and rollback |
| 10 | `mix test apps/loopex_llm_reqllm/test/provider_test.exs --only real_provider` | Outcome 7: real model call from the adapter application |
| 11 | `mix loopex.self_hosting` | Outcome 8: absence, inventory, hook behavior, measurement |
| 13 | `mix test` | The full suite. The credential is absent from the whole run, so no test anywhere can reach a provider |

Selectors are application-relative because an umbrella root runs no tests of its
own. Command 10 is path-scoped for the same reason: `mix test --only <tag>` at
the root recurses into applications with no tagged tests and exits zero having
run nothing.

## Protected Tests and Selectors

These selectors are protected: they may be extended but never removed, renamed,
skipped, filtered, quarantined, or weakened while `M0` is open.

An exit code proves a command ran, not that it did anything. Each selector
carries a locked minimum of **executed** tests and a list of test names that
must exist. Executed means ran to a verdict — passed or failed — never skipped
or excluded, and any skip on a protected selector is rejected outright.

The two locked pairs report that differently, and the runner parses both. Elixir
1.17 prints a counted total with **both** skipped and excluded inside it
(`4 tests, 0 failures, 1 excluded, 1 skipped` for two executed), so executed is
the total minus both. Elixir 1.20 prints named counts and no total
(`2 passed, 1 skipped, 1 excluded`), so passed is read directly; its failure form
`1/2 passed` reports 2, because both ran. See [Amendment 1](#amendment-1) and
[Amendment 2](#amendment-2).

The name check is drift protection: it catches a protected test that is deleted
or renamed. It does not prove the test asserts anything, and review owns that.

| Selector | Minimum tests | Locked test names |
| --- | --- | --- |
| `apps/loopex/test/deps_budget_test.exs` | 3 | `a forbidden core dependency is rejected`; `a reverse edge from contract to runtime is rejected`; `a dynamic module reference across the boundary is rejected` |
| `apps/loopex/test/hook_registration_test.exs` | 2 | `a hook registered under the wrong event is rejected`; `a hook registered with the wrong matcher is rejected` |
| `apps/loopex/test/format_scope_test.exs` | 1 | `a root-only formatter configuration is rejected` |
| `apps/loopex/test/core_only_test.exs` | 2 | `core starts with no adapter application resolved or started`; `per-runtime state is not read from application environment` |
| `apps/loopex/test/journal_replay_test.exs` | 2 | `replay after an induced restart reconstructs the same durable state` |
| `apps/loopex/test/fencing_test.exs` | 2 | `commit_unknown is fenced and never dispatched a second time`; `a stale completion is rejected after a coordinator restart` |
| `apps/loopex/test/vm_code_spike_test.exs` | 1 | `a trusted generation loads and rolls back in an isolated VM` |
| `apps/loopex/test/history_anchoring_test.exs` | 3 | `a mutated then restored artifact is rejected`; `a merge parent carrying a mutated artifact is rejected`; `an artifact missing from history is rejected` |
| `apps/loopex_llm_reqllm/test/provider_test.exs --only real_provider` | 1 | — |

Minimums and names may be raised or extended by stricter append-only coverage
with independent gate review. They may never be lowered while `M0` is open.

## Closure Document Set

The development contract requires each gate to name the documents its milestone
must update before closure. For `M0` that set is exact:

```text
AGENTS.md                              (bootstrap prerequisites, once Python and jq go)
CHANGELOG.md
README.md                              (derived status summary)
docs/plans/README.md                   (register row and status capsule)
docs/plans/M0.md                       (progress rows and governance)
docs/evidence/M0-provider.md
docs/evidence/M0-negative-demonstrations.md
docs/evidence/M0-self-hosting.md
docs/evidence/README.md
docs/developer/agent-context-map.md    (version-specific guidance)
DEVELOPMENT.md                         (prerequisites once Python and jq go)
```

Documentation drift blocks closure like any unmet outcome. The runner does not
judge whether a document is current — that is a closure-review reading — but the
set is fixed here so the reading has a checklist rather than a guess.

## Toolchain Matrix

A single in-process Mix task cannot run two Erlang runtimes. Command 6 therefore
verifies that the **running** toolchain matches one of the locked pairs and that
both pairs are recorded as run; the gate runner is invoked once per pair by the
operator or CI under the corresponding toolchain. A run under an unlisted pair
fails, and a claim of both lanes without two recorded runs fails. The exact pairs are the
`.tool-versions` bytes bound above:

```text
floor pair    Elixir 1.17.0 with OTP 26.0
current pair  Elixir 1.20.3 with OTP 29.0.5
```

Both pins are derived from accepted ADR 0002 rather than chosen: the floor is
the lowest supported pair in the 1.17 family, and the compatibility table offers
no patch selector, so the lowest patch of each is taken. The current pair is the
newest supported release, which today is also what Homebrew ships. The floor
lane predates what brew carries and runs through a version manager or CI; the
gate requires both lanes recorded, not both run locally on every invocation.

Changing a version changes those bytes and requires an amendment to ADR 0002,
not a gate edit. A green run on one pair is not evidence for the other, and a
green run on an unlisted pair satisfies neither lane.

## Evidence Classes

| Outcome | Required class | Substitution is not permitted |
| --- | --- | --- |
| 1, 2 | Structural check plus adversarial fixture | A passing happy path alone |
| 3 | Per-pair matrix run | One pair standing for both |
| 4 | Property tests, process fault injection, and a negative demonstration | Clean-shutdown replay |
| 5 | Property tests, fault injection, a no-second-dispatch assertion, and a negative demonstration | Retry-until-success |
| 6 | Isolated-VM demonstration and a negative demonstration | A same-VM reload |
| 7 | Real-provider run with retained identity | A fake adapter |
| 8 | Absence, inventory, and behavior proofs | Equivalence with the bridge present |
| 9 | Isolated fakes-only lane | Root suite standing for core |
| 10 | Compiled-documentation check | A source-text grep |

## User-State Isolation

Before anything is allocated, the runner refuses to run if `TMPDIR`, `MIX_HOME`,
or `HEX_HOME` resolves inside the protected state directory. Both sides are
resolved physically, so `..`, relative paths, and symlinks cannot alias past the
check.

Resolution is component-wise, left to right, against an already-physical prefix,
because resolving the assembled string at the end does not work: `cd` without
`-P` collapses `..` lexically, so `~/link/../..` is reduced by text before the
kernel sees it and the intermediate symlink is discarded along with the alias it
carried. Each link is followed as it is reached, including a dangling one aimed
at a directory that does not exist yet, and `..` is taken from the resolved
prefix. The result is the path the kernel would actually open.

The loop's budget counts symlink expansions only, because that is the sole way
it can fail to make progress; component consumption always terminates. Counting
components let a path padded with `./` exhaust the budget, and the resolver then
returned the prefix it had managed to resolve, which compared as outside. An
exhausted budget now yields nothing, and an unresolvable path is refused rather
than assumed outside.

Comparing resolved text is necessary but not sufficient on a real macOS host.
Two ordinary aliases defeat it: the data volume carries a firmlink to the user's
home that shares its device and inode, and the default filesystem folds case, so
an uppercase spelling names the same directory. The runner therefore compares
device and inode as well, across **every** prefix of the candidate rather than
only its end, and does the textual comparison case-insensitively. When the
protected directory does not exist yet it has no inode of its own, so the
comparison falls back to its parent's inode plus a case-folded name match, which
is what catches an aliased spelling of a directory not yet created.

A path that does not exist legitimately has no identity and is skipped. A path
that exists whose identity cannot be read is different: that is unavailable
evidence, and the runner refuses rather than skipping the comparison and falling
back to text. Otherwise the
isolated root, or Mix's own writes, would land inside the very directory the
relocation exists to protect.

`HOME` itself is relocated into a temporary root the runner creates and removes,
along with `LOOPEX_HOME` and `LOOPEX_WORKSPACE`. A helper that reaches for the
real user state directory resolves inside that root and finds nothing, which is
the fail-before-touch containment the development contract requires — not a
notice-afterwards check.

Package-manager caches are deliberately excluded from the relocation: `MIX_HOME`
and `HEX_HOME` are pointed at their existing persistent locations, so isolation
costs no refetch and needs no network on a cold cache. Product state is
contained; tool caches are shared on purpose.

The runner also fingerprints the real state directory before and after. That is
defense in depth against a path that escaped containment, and carries no safety
claim of its own — containment above is the property.

Everything the runner does before it allocates temporary storage only reads the
checkout, so the mandatory read-only review reaches the declared red condition
instead of failing on unavailable storage. That is the guarantee, and it is
directional: checkout-only checks also appear after allocation, kept beside the
outcome they belong to, and no claim is made that all of them run first.

## Real-Provider Lane

Command 10 is excluded from the default suite and runs only when invoked
explicitly. The credential is read from the environment and never written to a
journal, fixture, log, snapshot, diagnostic, or committed byte.

That claim covers the runner's own diagnostics and its own process table. The
lane captures stdout and stderr together, so a provider or test that echoes the
key into an error message would put it directly into operator and CI output.
Captured output is therefore redacted before it is printed, by in-process
substitution rather than by piping through a filter.

The credential reaches the child through a shell assignment prefix, which sets
it in the child's environment directly. Passing it to `env` as an argument --
the earlier form -- placed it in that process's argv, where any user on the host
could read it before `env` replaced itself with Mix. Redacting output does not
address that exposure; it is a separate plane and needs its own containment.

The lane retains non-secret identity in `docs/evidence/M0-provider.md`. The
runner requires four fields, named exactly: `provider`, `model`, `endpoint`, and
`recorded`. Each must appear exactly once and be populated, so a real value
cannot sit beside a placeholder. Populated means containing an alphanumeric
character, which is what distinguishes a recorded value from `-`, `?`, or the
template's em dash.

The file holds only `real_provider`-tagged tests, so an unfiltered run of it must
execute none. Requiring merely that something was excluded would pass while an
unrelated tag supplied the exclusion and the provider test still ran. A missing
credential reports evidence unavailable and exits non-zero; it never reports
success, and a skipped lane is not a pass. Because a tagged run exits zero having executed nothing, the runner requires at
least one executed test.

The credential is named `LOOPEX_PROVIDER_API_KEY`. The runner disables
`allexport`, captures the value into an explicitly non-exported variable, unsets
the original, and then proves neither name appears in the environment of a child
process. It removes the credential for the **entire** run, handing it only to the
explicit real-provider command. Unsetting it just before the full suite would
leave every earlier selector, task, and compile step holding it, so an
accidentally untagged provider call earlier would still reach a provider.

Containment precedes the runner's **first child process** — ahead of the
`git rev-parse` that locates the repository root, not merely ahead of the Mix
commands. A scrub placed after any child is a notice-afterwards check: every
process already started has inherited the value, and an assertion made later
cannot detect that it did. The assertion itself is the first child, and it runs
only once both names are contained.

The runner also proves the tag is excluded by default, by running the same file
unfiltered and requiring it to execute none of its tagged tests. Without that,
the full-suite command would reach a real provider a second time while the gate
still turned green.

## Self-Hosting

The runner proves absence and inventory itself rather than delegating them to
the task under test, because a task cannot be the evidence for its own
retirement. It shadows `python3` and `jq` with stubs that refuse to run and
requires the aggregate to complete anyway, then inspects the tree directly and
scans for invocations that shadowing cannot intercept. Dropping directories from
`PATH` is not used: it would also remove `git` and fail for the wrong reason.

The scan covers the **whole tracked tree**, not a list of top-level directories.
An allowlist is defeated by a directory nobody thought to add: an absolute
invocation in a new `tools/helper.sh` called by the aggregate would evade both
the stub and a `scripts`-only scan. Exactly one exclusion applies: the runner
itself, which must name the interpreters in order to shadow and report them, and
whose drift the bound-artifact digest catches instead.

Markdown is **not** excluded. Excluding prose by file type was unsafe: a
mode-0644 file is still executable as an argument to a shell or by being
sourced, so the execute-bit assertion that guarded the exclusion could not
establish that prose was inert. The documents that must describe these forms
avoid spelling them literally instead, which removes the need for the exception
rather than guarding it.

The interpreter set is not just `python3` and `jq`. On an ordinary macOS host
`python`, a versioned `python3.x`, and `xcrun` all reach a working interpreter,
and `xcrun` resolves Xcode's Python independently of `PATH` order. The runner
stubs a fixed core plus every python-like name reachable on the current `PATH`,
proves each stub effective rather than only the first, and matches the same
widened set in the scan. A name followed by `/` is a directory component, not an
invocation, and does not match. Entries are read with `:` as the only separator,
so a directory containing a space is not split and an empty entry is correctly
treated as the working directory.

The fixed core also covers launchers whose own name is not python-shaped and
which dynamic enumeration therefore cannot find: `xcrun`, `uv`, `pyenv`, `pipx`,
`poetry`, and `conda`. That list is enumerable but not provably exhaustive --- a
launcher nobody named reaches an interpreter it manages --- so the coverage claim
is the fixed core plus python-shaped names, not every conceivable entrypoint.

`git grep` exits 0 on a match, 1 on none, and above 1 on error. The runner
distinguishes all three. Treating anything non-zero as clean would turn a broken
invocation, an unreadable object, or a pathspec typo into a silent pass, which
inverts the unavailable-evidence rule.

Command 11 covers four separable things and fails on any of the first three:

1. **Absence.** The aggregate runs to completion while `python3` and `jq` are
   shadowed by stubs that refuse to run. Shadowing intercepts PATH lookups only,
   so the runner additionally scans for absolute paths — including forms that
   quote the interpreter name inside the path — `env`-resolved calls with or
   without flags, `command -p` and `-pv`, `exec`, and assignment-prefixed runs,
   none of which a shim can catch. This document does not spell those forms
   literally, because it is scanned like every other tracked file.

   Mutating the search-path variable defeats the stubs as completely as naming an
   absolute path, and the mutation need not sit on the line that calls the
   interpreter. Every **textual** mutation outside the runner is therefore
   rejected: plain and exported assignment, a quoted assignment handed to `env`,
   `unset`, `printf -v`, an array-element write, and a declaration naming the
   variable. Requiring the value to carry the old one forward was a heuristic and
   failed in both directions -- prepending a real interpreter directory ahead of
   the stub root preserves the variable and defeats the stub, and a substring
   removal deletes the stub root while still naming it -- so the rule makes no
   judgment about the value.

   **This is not airtight, and no claim is made that it is.** Indirection --- a
   nameref, `eval`, or a computed variable name --- mutates the same variable
   with no matching token, and no text scan can see it. The containment that
   would close it does not exist in the development baseline: an allowlist search
   path cannot exclude the interpreter directories, because `/usr/bin` holds
   `python3` and also `git`, `sed`, and `awk`, so removing it would break the
   aggregate this check exists to run. Prepending the stub root is the strongest
   portable containment available; indirection is the residual, and it reaches
   closure review because no mechanism at this layer can reach it.
2. **Inventory.** Every named bridge component is gone from the tree:
   `scripts/check_status.py`, `scripts/test_check_status.py`,
   `scripts/check-agent-bootstrap.py`, the `python3` invocations in
   `scripts/check-status.sh` and `scripts/check-agent-bootstrap.sh`, and the
   `jq` invocations in `scripts/check-agent-bootstrap.sh`,
   `.claude/hooks/guard-bash.sh`, `.claude/hooks/after-edit.sh`, and
   `.claude/hooks/guard-filesystem.sh`.
3. **Preserved hook behavior.** Each named hook must exist — a hook that simply
   disappears is behaviour loss, which ADR 0002 permits only through a recorded
   disposition — must be executable, and is run **as the configured executable**
   rather than through `bash`, so a lost execute bit or broken shebang is caught.
   Its registration in `.claude/settings.json` is checked too, because a hook
   that still blocks is worthless if the client no longer invokes it. The
   required mappings are exact:

   ```text
   PreToolUse   Bash                                    guard-bash.sh
   PreToolUse   Read|Grep|Glob|Edit|Write|NotebookEdit  guard-filesystem.sh
   PostToolUse  Edit|Write                              after-edit.sh
   ```

   A task exit status alone would prove only that the task ran, so the task
   carries its own protected tests: it must reject a hook registered under the
   wrong event and one registered with the wrong matcher. The same applies to
   the formatter scope task, which must reject a root-only configuration.
   Without those, either task could be a successful no-op. It must
   exit exactly `2` on its fixture at
   `scripts/fixtures/hook-cases/<hook>.stdin`: the client treats 2 as blocking
   and any other nonzero status as a non-blocking error, so only 2 proves the
   behavior survived. The
   replacement additionally runs
   `apps/loopex/test/history_anchoring_test.exs`, whose three locked cases prove
   it still anchors bound artifacts across history; retiring the current checker
   would otherwise drop that guarantee silently. This is proved
   by execution, not by the task's exit status. Removing a behavior instead of
   migrating it requires an explicit disposition recorded against outcome 8.
4. **Measurement.** `docs/evidence/M0-self-hosting.md` records the replacement's
   size and what it dropped. The runner requires three populated fields, named
   exactly: `measured size`, `dropped behaviors`, and `recorded`, each appearing
   exactly once and populated. A populated value must contain an alphanumeric
   character: rejecting only the template's em dash left `-`, `?`, and every
   other punctuation placeholder reading as filled while recording nothing.
   Review judges whether the content is truthful.

Shell is not retired. The enduring baseline is Git, shell and POSIX tools, and
the accepted Elixir/OTP toolchain, so a check may remain a shell entrypoint that
calls Mix.

The retiring bridge measures 4,462 lines at the gate commit:

```text
2104  scripts/check_status.py
2119  scripts/test_check_status.py
   8  scripts/check-status.sh
 231  scripts/check-agent-bootstrap.py
4462  total
```

**That figure is audit and review material, not a pass condition.** Requirement 4
reports; it does not threshold. A line ceiling would reward compressed code,
hidden complexity, and deleted coverage, so an independent reviewer weighs the
measurement against the dropped-behavior list instead.

## Negative Demonstrations

Outcomes 4, 5, and 6 each require a demonstration that the protected test fails
when the mechanism it covers is disabled. A test that still passes with the
behavior removed proved nothing, and no locked name or minimum count detects
that.

The record is `docs/evidence/M0-negative-demonstrations.md`. The runner requires
**exactly one** `## Outcome N` section for each of 4, 5, and 6, and within each
section **exactly one** populated entry for every field:

```text
- mechanism disabled: <what was turned off>
- observed failure:   <how the protected test failed>
- demonstrated at:    <commit>
```

Both counts are exact rather than minimums. Duplicate sections would let a
populated one cover a placeholder one, and a duplicate field would let a real
value sit beside an unfilled dash while still satisfying "at least one
populated". Neither is semantic dishonesty; both are the unpopulated-field drift
this runner is responsible for.

Whether a demonstration is real remains a review judgment.

## What the Runner Is For, and What Review Owns

The runner defends against **accident and drift**: a command that stops passing,
a protected test renamed or skipped, a dependency creeping back, an evidence
record never filled in. Those failures happen without anyone intending them, and
a script catches them reliably.

It does not defend against a **dishonest implementer**, and this gate no longer
pretends to. Earlier versions added control after control — grep for locked test
names, minimum counts, fixture counts, report schemas — and independent review
found a bypass for each, because a script cannot tell whether a test asserts
anything, whether a fixture is real, or whether a report is truthful.

Those judgments are assigned to the independent review of the implementation at
the closure candidate, which the plan requires. Concretely, that review must
decide whether each protected test asserts the behavior its name claims, whether
each hook and history fixture is meaningful rather than trivially satisfied, and
whether the self-hosting report and negative demonstrations are truthful.

Stated plainly so the closure reviewer knows where to look, rather than implying
the runner covers it.

A locked test name is a source-text check: it proves the name is still present,
which catches a protected test that was deleted or renamed. It does not prove
that test ran, and a minimum executed count does not prove the counted tests
were the named ones. A custom
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

<a id="amendment-1"></a>
## Amendment 1 — ExUnit summary parsing across both locked pairs

**Accepted:** 2026-08-17 by the maintainer. **Scope:** parsing helpers in the
bound runner and the Protected Tests description above. **Not changed:** every
locked command, selector, minimum executed count, locked test name, fixture,
toolchain pair, evidence class, and closure document.

The runner as accepted parsed only Elixir 1.17's ExUnit summary. Elixir 1.20,
the current locked pair, prints named counts and no total, so every protected
selector reported no parsable test count and **the gate could not go green on its
own locked toolchain.** It failed closed, which was safe, but it was
unsatisfiable, and no amount of implementation would have changed that.

The defect was not caught when the gate was written. Every command form had been
executed against a disposable umbrella scaffold, which proved the commands ran;
none of them ran a passing Elixir test, because no test existed yet, so the
summary parsing was never exercised. Five independent review rounds probed the
runner's containment logic and none reached this either. The lesson is recorded
here rather than in a commit message: a gate must be run against a passing
example of the thing it measures, not only against the absence it declares.

Fixing it required changing the bound runner, whose digest is part of the
accepted gate digest, so this amendment rebinds the acceptance record to a new
candidate carrying the amended bytes. The original acceptance remains in the
Git history and in the disposition record it points at.

<a id="amendment-2"></a>
## Amendment 2 — excluded tests are inside the floor pair's total

**Accepted:** see [Amendment 3](#amendment-3), which corrects this heading. The
line originally here claimed acceptance under a standing instruction to proceed;
that instruction predated this amendment and did not name it. **Scope:** the executed-count arithmetic for the counted summary form in
the bound runner, and the Protected Tests description above. **Not changed:**
every locked command, selector, minimum executed count, locked test name, fixture,
toolchain pair, evidence class, and closure document.

Amendment 1 subtracted only skipped tests from the counted total, on the stated
belief that Elixir 1.17 reports excluded tests outside it. **The floor lane
disproved that.** On Elixir 1.17.0 a file with two passing, one skipped and one
excluded test reports `4 tests, 0 failures, 1 excluded, 1 skipped`: both sit
inside the total, so executed is the total minus both.

The consequence was not cosmetic. The real-provider file holds one tagged test, so
an unfiltered run reports `1 test, 0 failures, 1 excluded`. Amendment 1's
arithmetic read that as one executed test and the gate declared that
`real_provider` was not excluded by default — failing outcome 7 on the floor pair
for a reason that was purely a parsing error, while the exclusion was working
correctly.

The original gate text worried that subtracting excluded "would reject a valid
file that holds both tagged and ordinary tests". That worry was mistaken. When
such a file runs with the tag excluded, the total counts the excluded tests, so
subtracting them yields exactly the ordinary count.

This is the second amendment in one milestone, and both were the same class of
defect: the runner could not read the output of a toolchain it locks. Amendment 1
was found only because implementation produced a passing test; Amendment 2 only
because the floor lane finally ran. Neither was reachable by inspecting the gate.
That is the argument for ADR 0002's two validated pairs, and it is also the
argument against writing a measurement before there is anything to measure.

<a id="amendment-3"></a>
## Amendment 3 — corrections of record, no behaviour change

**Acceptance: OUTSTANDING.** This amendment exists to be disposed of together with
[Amendment 2](#amendment-2), which also has no disposition. **Scope:** two comment
blocks in the bound runner and the acceptance heading of Amendment 2. **Not
changed:** no behaviour whatsoever — no locked command, selector, minimum executed
count, locked test name, fixture, toolchain pair, evidence class, or closure
document, and no executable logic. The runner's exit codes are identical before and
after.

Three things are corrected.

**One.** Amendment 1's explanation survived inside the runner after Amendment 2
disproved it. Two comment blocks still told a reader that Elixir 1.17 reports
excluded tests outside its counted total and that executed is the total minus
skipped, immediately above code that subtracts both. The example shapes were also
not the ones 1.17.0 emits. A governed artifact carrying a disproved explanation is
a defect even when the code below it is right, because the comment is what the next
reader believes.

**Two.** Amendment 2's own acceptance heading claimed acceptance under a standing
instruction. It had none. An amended artifact cannot be its own authority evidence,
and the heading now points here rather than asserting a disposition that was never
given.

**Three.** A review found that command 2's warning check might be a cached no-op,
because project tasks above it compile the same code without the flag. **That was
checked and it does not hold.** Mix persists diagnostics and replays them, so the
command fails on a stored warning even with nothing stale to recompile — verified
on both locked pairs by compiling without the flag, which exits 0 with the warning
present, then running the command, which exits non-zero having compiled nothing. No
change was made, and the runner now records the verified reasoning where the doubt
would otherwise recur. Adding `--force` would have cost a full rebuild on every
lane for no additional guarantee.

That third item is why this amendment is small. Two of the three review findings in
this area were real and are corrected as text; the one that proposed a behaviour
change was not confirmed, and behaviour was left alone.