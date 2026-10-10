# Development

This document describes how to validate and work on the repository, and it
owns the commands, not the milestone state. The canonical status for the
checked-out revision, including currently authorized work and the next
maintainer decision, is in [docs/plans/README.md](docs/plans/README.md). The
[development charter](docs/developer/development-charter.md#concept) explains
the project's clarity and traceability commitments; its
[technical companion](docs/developer/development-charter-technical.md#technical-depth)
defines the exact documentation, review, and code-comment conventions.

## Prerequisites

The repository checks require:

- Git;
- Bash;
- a POSIX userland providing `awk`, `cat`, `grep`, `readlink`, `sed`, and `tr`;
- Python 3 for the M6 demonstration and attended-release fixtures, and the
  platform's `script(1)` for the attended-release fixture;
- the accepted Elixir/OTP toolchain, which supplies `mix`.

That is the whole development baseline. The client hooks read a tool call
through `scripts/json-field.sh`, which uses `awk` from the baseline rather than
an added dependency. Adding another development dependency requires the
ordinary dependency decision.

The direct `scripts/check-release.sh` uses the existing Elixir byte-stream
redactor before each release lane reaches the terminal or its retained log.
The `scripts/attended-release.sh` closure helper uses the same redactor for a
person's `script(1)` transcript. Only authorized
`--answer-attended` uses Python's standard library for its controlling PTY and
transcript redaction. Neither Python nor `script(1)` is a Loopex runtime
dependency or a prerequisite for running `scripts/check-release.sh` directly.

The release check adds one prerequisite that is not part of the baseline: the
independent consumer in `clients/node` runs under the Node version pinned in
`scripts/fixtures/m4/client-toolchain.txt`. Nothing in the product uses Node,
and the consumer is plain JavaScript with no build step, package manifest,
lockfile or dependency, so there is nothing to install beyond Node itself.

The reference local executor has a separate **runtime** prerequisite:
executable `/bin/bash` for its internal supervision scripts on Darwin and Linux.
Model-supplied raw commands still use `/bin/sh`, and argv commands remain literal.
Core and custom executors do not acquire this requirement; see
[Accepted ADR 0022](docs/adr/0022-local-executor-supervision-shell.md#concept)
and the [operator prerequisite](docs/operator/tools-and-policy.md#operator-local-supervision-shell).

The checkout must preserve the tracked relative `.claude/skills` symlink. On
Windows, WSL is the straightforward path; Git Bash also requires Windows
Developer Mode or equivalent symlink permission and Git symlink support.

## The Two Checks

Once per integration candidate, from the repository root (hosted CI runs the
same command, as `--select`, on every push to `main` and every pull request):

```bash
bash scripts/check.sh
```

It runs, in order, and stops at the first failure: `mix compile
--warnings-as-errors`, `mix format --check-formatted`,
`bash scripts/check-bootstrap.sh` (client-adapter structure, ignore policy,
commit messages, branch and worktree hygiene, OTP application declarations, the
suite-summary judge, and `mix loopex.status` over the current tree: paired
documents, directory indexes, local links, and the status
register), `mix loopex.docs_check`, `mix loopex.m7_evidence` (the M7 evidence
validator: well-formed, non-conflicting committed `index-head:` lines in the M7
plan, the intact pinned coding-fixture catalog, external task and execution
manifest, the legacy and M7 release case families, and the
[M7 validation runbook](docs/operator/m7-validation.md)'s matching step
ownership), the release-runner, escript-inventory,
archive-manifest, attended-release, floor-lane, and M6 demonstration fixtures,
`mix loopex.deps_budget`,
`mix loopex.version_train`, the test build, and the credential-free suite, one
application per VM with several at once (`LOOPEX_CHECK_JOBS` bounds how many;
the default is half the cores capped at four; composition always runs alone,
and `LOOPEX_CHECK_ALONE` names other applications that
run one at a time before the rest share the box, which hosted CI sets to
`loopex_llm_reqllm` because its child VMs boot under the product's deadline
and a four-core runner starved that boot behind another application's
compile). Each application's output is kept in a log and printed only if it
fails; a line every thirty seconds names what is still running, and an
interruption kills the whole process tree. An application whose suite executed
no test is red, not green: `scripts/suite-summary.sh` judges the result line.

`bash scripts/check.sh --docs` stops after the documentation step, for a change
that touches only prose, and `bash scripts/check.sh --select` picks between the
two from the diff against `merge-base(origin/main, HEAD)` — documentation mode
when every changed path is Markdown outside `apps/`, the full check otherwise
or when the diff is empty. The check needs no credential, network access, or
coding-agent client, and runs once per integration candidate: hosted CI runs
`bash scripts/check.sh --select` on every push to `main` and every pull request
and does not define it.

Before closing a milestone, once from the exact committed candidate, on a
machine with the pinned Node, a provider credential, and a running local
Ollama server at `127.0.0.1:11434`, make the selected local model available
there and export `LOOPEX_RELEASE_OLLAMA_MODEL=ollama:<installed-model>`. The
real local-command case checks that model through Ollama's `/api/show` before
it runs. For M6 closure, use the retained
[floor and attended runners](docs/plans/M6-technical.md#technical-plan-closure-tooling):

```bash
bash scripts/floor-lane.sh SHA --output-dir DIR --long-bound
read -rs LOOPEX_PROVIDER_API_KEY
export LOOPEX_PROVIDER_API_KEY
bash scripts/attended-release.sh --output LOG
```

Run each once for the tested SHA. `DIR` and `LOG` are new retained-output paths
outside the repository. For M7 closure, load provider B's `OPENAI_API_KEY` the
same way and pass the M7 matrix options to the attended runner, which forwards
them unchanged to the release check and redacts both providers' values from
its transcript:

```bash
bash scripts/attended-release.sh --output LOG \
  --attempts-index /absolute/retained/m7-attempts.jsonl \
  --writer WRITER --host HOST --markers /absolute/retained/m7-markers \
  --m7-config /absolute/retained/m7-config.json --operator Maintainer
```

The runner forwards `--attempts-index`, `--writer`, `--host`, `--markers`,
`--m7-config`, `--operator`, `--pins` and `--resume-matrix`, each at most once.
The underlying release check accepts the same options directly.

The full matrix requires `--attempts-index FILE`, the retained M7 attempts
index outside the checkout, with the writer identity that holds it
(`--writer`, `--host`, `--markers`), and the conversation lanes' explicit
configuration and named operator (`--m7-config`, `--operator`). One recorder
records every release lane of the logical matrix in that index before it runs;
`--resume-matrix ID` continues that matrix after a pre-dispatch stop, skipping
the lanes it already completed and rebuilding fresh-source, whose archive
manifest must reproduce the first invocation's digest. Before staging, and again inside the built extraction, it
runs the M7 evidence validator with `--release`, which refuses an M7 lane
(`m7-provider`, `m7-rollback`, or the attended `m7-operator` block in the full
matrix) as unavailable evidence while any of its manifest cases is still
pending, and the full matrix while any step owner is pending; the committed
manifest has no pending case or step owner. The M7 conversation lanes carry
exactly provider A's `LOOPEX_PROVIDER_API_KEY` and provider B's
`OPENAI_API_KEY`; set `LOOPEX_M7_EXTERNAL_REPOSITORY` to the external task's
checkout. The cases themselves run through `scripts/m7-fixture-chat.exs`,
described in the [M7 validation runbook](docs/operator/m7-validation.md).
It refuses without the credential, without the pinned Node, or on a dirty tree, and raises its own open-file soft limit toward the hard limit, refusing below 4,096, because the maximum-population case holds both ends of 512 daemon connections in one VM.
It first stages the candidate as a fresh source archive and builds it there
(described below), then runs every test lane inside that extraction rather than
in your checkout. The eleven real-provider cases run from a named manifest
(application, file and exact case name), each in its own `mix test FILE --only
test:NAME` process and each executing exactly one test. The ninth is the
operator takeover:
`loopex daemon`, a CLI controller killed with `SIGKILL` and the Node observer
taking over, each its own process, the observer's prompt answered by the real
provider. The tenth drives local Ollama through `loopex -p` without a
credential; the eleventh drives the embedded API against Anthropic with only
`ANTHROPIC_API_KEY`. Rows one through nine receive the durable
`LOOPEX_PROVIDER_API_KEY`. The runner keeps provider values shell-held while
unrelated preflight, build, summary and digest helpers inherit none of those
named provider variables. Every
other lane removes all supported provider credential names. A wrapper
self-check reports only presence or absence, never the values. The
independent Node client runs with `--only node_client` over
`loopex_app_server`, `loopex_protocol`, `loopex_daemon` and `loopex_cli`, the
last being the operator takeover: a killed CLI controller and a Node observer
that takes over and aborts. The fresh-source lane that precedes them: from a
hostile caller
`umask 0777` it stages the exact commit with `git archive` under a scoped
`umask 022`, retains the extraction's `scripts/source-archive-manifest.sh`
manifest and the `git ls-files -z` inventory outside the extraction (set
`LOOPEX_RELEASE_RETAIN` to choose where), proves with
`scripts/source-archive-check.exs` that the extraction is exactly that commit,
builds the command there with `mix deps.get` and the documented escript build,
checks that both built escripts contain Logger and the load-only provider
applications, and proves the build changed nothing outside its declared
outputs; it then
requires the extraction's source identity to be the staged commit and its
`VERSION` to be `0.3.0`, and prints both retained files' SHA-256 digests. A `--only long_bound` pass over `loopex`,
`loopex_executor_local`, `loopex_daemon` and the in-process ReqLLM transport-drain witness runs the real-duration proofs the
fast check excludes. On Linux the last lane runs the daemon's two
`--only cross_uid` cases and requires exactly two to execute; it needs a second
unprivileged user named in `LOOPEX_CROSS_UID_USER` that you may run a command
as with `sudo -n`. Elsewhere that lane prints `cross_uid: not run (Darwin)` and
the run ends `PASS (closure-incomplete: cross_uid not run)`; closure needs a
Linux run ending in a plain `PASS`. The pre-1.0 current-contract rule retires
the old cross-version `rollback` lane and its historical archive requirements;
the removed selector refuses before staging. Every current lane prints its executed count and
elapsed time. Provider keys are not placed in command arguments; exact
nonempty values of the four supported key names are masked before release-lane
output reaches the terminal or retained evidence. The attended terminal
launcher and redactors necessarily handle those values; partial, transformed
or encoded disclosures are outside exact-value masking. The runner refuses a
selector or release path containing a supported value before archive
extraction and prevents inherited Bash startup hooks from running again in
its children. Trusted host code that ran before the script starts remains the
host's responsibility. Two of the real-provider tests and the `m7-operator`
block's attended cases are attended: they prompt on the controlling terminal
for the operator's decisions (`Type yes and press Enter.`), so run the command
from a terminal.

An unchanged-source release reuses this closure evidence. It runs only the
pre-tag administrative-SHA proofs described by the milestone and verification
guides; it does not run `scripts/check-release.sh` again.

The individual commands can also be run directly:

```bash
mix loopex.status              # paired documents, indexes, links, register
mix loopex.agent_bootstrap     # client adapter structure
mix loopex.hook_registration   # each hook's required event and matcher
mix loopex.docs_check          # compiled Concept-before-Technical-depth ordering
mix loopex.deps_budget         # dependency budget and direction
mix loopex.version_train       # one version across every application
mix loopex.matrix              # the running toolchain is one of the two pairs
```

Every check reads the checkout and writes nothing to it except the Mix build
directory. Tests use a temporary `LOOPEX_HOME` and temporary workspaces, and
the helpers fail before touching real user state; never point development or
test commands at a real `~/.loopex`.

## Toolchain Pairs

The floor is OTP 27 and Elixir 1.18. Accepted ADR 0026 fixes two validated
pairs, recorded in `.tool-versions`: floor Elixir 1.18.5 with OTP 27.3.4 and
current Elixir 1.20.3 with OTP 29.0.5. Homebrew carries only the current one,
so the floor pair needs a version manager. `mise` provides both, and the floor
toolchain needs Hex and rebar3 installed once before Mix can build under it:

```text
mise install erlang@27.3.4
mise install elixir@1.18.5-otp-27
mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- mix local.hex --force
mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- mix local.rebar --force
mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh
```

Do not activate a version manager inside the checkout; invoke the pair
explicitly. OTP 27 cannot read a beam written by OTP 29, so clear `_build`
when switching between the pairs, or give each pair its own `MIX_BUILD_PATH`.
Hosted CI normally proves the current pair. A local fast check counts for an
integration candidate only when its complete output and exact tested SHA are
retained. Milestone closure runs `scripts/check.sh` once under the floor pair
as well, which is the only run that proves the floor still builds and passes.
A Linux host needs
`LANG=C.UTF-8` and `LC_ALL=C.UTF-8` exported.

## Dependency Rules

Every child project declares one literal `loopex_role`: `:contract`, `:core`,
`:edge`, `:composition`, `:client` or `:host`. Contract carries no dependency;
core depends on protocol and on exactly one external package, the `telemetry`
event dispatcher the vision's dependency doctrine admits by name; store, model,
executor and telemetry edges depend in production on core and may also depend
on protocol. The composition (`loopex_composition`) depends in production on
core, protocol and the edges it wires together. A client (the CLI, the app
server and the reference client) depends in production on core and may also
depend on the contract, on at most one composition and on at most one host;
it names any other edge only in tests. A host (`loopex_daemon`) obeys the client
rules and may not depend on another host. `mix loopex.deps_budget` reads the literal dependency
declarations of all eleven applications and rejects any other edge, alternate
path or source-control dependency, or added external package.

An OTP application is not a dependency in that sense, but it must still be
declared: any application whose code calls `:crypto`, `:ssl` or `:public_key`
names it in `extra_applications`, because Mix prunes undeclared OTP
applications from the code path under the floor toolchain pair.
`scripts/check-otp-applications.sh` enforces the declaration on every run of
the fast check.

## Debugging

Debugging Loopex during development means turning on what the runtime already
offers rather than adding printing to the code under test. A trace session is
started through the runtime reference a host holds and stopped the same way;
telemetry spans arrive at every port callback and transaction cut. The
[operator runbook](docs/operator/observability.md#concept) has the levels,
what redaction removes, the ceilings and the event inventory; the
[developer pair](docs/developer/observability.md#concept) has the contract.

`mix loopex.docs_check` reads the doc chunk of every compiled module, so it
answers what a reader of the published documentation would see. Covered public
code must carry `## Concept` before `## Technical depth`; a module with no
documentation fails, and one marked `@moduledoc false` is excluded and counted.

## Provider Companion

The reference CLI build also builds its private provider companion from a clean
source checkout. Compilation and companion artifacts use the effective Mix
build directory, including `MIX_BUILD_ROOT` or `MIX_BUILD_PATH`; the command
embeds that exact companion path and build identity. Runtime never searches a
workspace for a companion. The operator build command and relocation constraint
are in [Coding sessions](docs/operator/coding-sessions.md#operator-sessions-running).

## Implementation Posture

Start with direct OTP and the smallest clear implementation. Production code,
tests, fixtures, helpers, public surface, and abstractions all count as system
cost. A new abstraction must name the concrete examples or current
implementations it unifies and why direct code is insufficient; do not add a
layer for a hypothetical future consumer. Keep tests focused and reusable, but
never delete required coverage merely to make the repository smaller.

Elixir modules, behaviours, callbacks, public APIs, public types, and important
boundaries explain both `## Concept` and `## Technical depth` in their standard
documentation. A private function uses adjacent `# Concept:` and
`# Technical depth:` comments only for a non-obvious invariant, effect, failure
mode, or design decision.

## Optional Development Clients

Development clients are optional tools, not project dependencies. The currently
tested adapters are Claude Code and Codex; their retained versions and loading
evidence live in
[docs/developer/agent-adapter-smoke.md](docs/developer/agent-adapter-smoke.md).
Canonical behavior lives in [AGENTS.md](AGENTS.md) and routes through
[the agent context map](docs/developer/agent-context-map.md).

## Before Working

Read [AGENTS.md](AGENTS.md), then the
[plans status register](docs/plans/README.md), and use the
[agent context map](docs/developer/agent-context-map.md) only to load relevant
Concept sections and their exact Technical depth. Work lands on `main` in small
reviewed changes, as the
[milestone guide](docs/developer/milestones.md#concept-milestones-develop)
describes.
