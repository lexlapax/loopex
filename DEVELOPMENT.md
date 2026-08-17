# Development

Loopex is pre-implementation. This document describes how to validate and work
on the repository, and it owns the commands, not the milestone state. There is no
installable package and no public product surface; the umbrella exists so the
accepted milestone's repository checks and experiments have somewhere to live.

The canonical status for the checked-out revision, including currently
authorized work and the next maintainer decision, is in
[docs/plans/README.md](docs/plans/README.md). Its Directing the Work section
owns how development is requested — the verbs and where each one stops. This
file owns the commands those verbs run, and milestone state lives in neither.
The split is deliberate: the verbs outlive the toolchain, so replacing the seed
bridges with Mix entrypoints changed the commands here and nothing there. The
[development charter](docs/developer/development-charter.md#concept) explains the
project's clarity and traceability commitments; its
[technical companion](docs/developer/development-charter-technical.md#technical-depth) defines
the exact documentation, review, and code-comment conventions.

## Bootstrap Prerequisites

The provider-neutral bootstrap check requires:

- Git;
- Bash;
- a POSIX userland providing `awk`, `cat`, `grep`, `readlink`, `sed`, and `tr`; and
- the accepted Elixir/OTP toolchain, which supplies `mix`.

That is the whole list, and it is the enduring development baseline: Git,
shell/POSIX tools, and the accepted Elixir/OTP toolchain. The seed's two bridge
prerequisites are gone — repository checks now run as repository-owned Mix
commands, and the client hooks read a tool call through
`scripts/json-field.sh`, which uses `awk` from the baseline rather than an
added dependency. Shell is not retired: a check may remain a shell entrypoint
that calls Mix, and several do.

Adding another development dependency requires the ordinary dependency
decision.

The checkout must preserve the tracked relative `.claude/skills` symlink. On
Windows, WSL is the straightforward path; Git Bash also requires Windows
Developer Mode or equivalent symlink permission and Git symlink support. Native
PowerShell bootstrap commands are not provided yet.

Verify a checkout from the repository root:

```bash
git status --short --branch
bash scripts/check-bootstrap.sh
```

The aggregate runs five checks: agent/client bootstrap, ignore policy, commit
messages, branch/worktree hygiene, and status/document drift. It requires
no GitHub account, `gh` CLI, hosted CI service, credentials, network access,
coding-agent client, or product dependency download. Hosted CI may mirror this
command but does not define it.

Every check reads the checkout and writes nothing to it. The aggregate does need
a writable build directory, because it now runs on Mix and Mix compiles: that is
the direct consequence of moving repository validation onto the accepted
toolchain. A reviewer who must not write to an ambient temporary directory
directs the build into an explicit isolated task root through the
`MIX_BUILD_PATH` variable. The read-only inspection lane is the milestone gate
runner's prefix, which reaches its declared condition before it allocates any
storage.

The individual repository commands can also be run directly:

```bash
mix loopex.status              # paired documents, register, governance, history
mix loopex.agent_bootstrap     # client adapter structure and hook registration
mix loopex.hook_registration   # each hook's required event and matcher
mix loopex.docs_check          # compiled Concept-before-Technical-depth ordering
mix loopex.self_hosting        # replacement measurement and dropped behaviors
```

## Optional Development Clients

Development clients are optional tools, not project dependencies. The currently
tested adapters are Claude Code and Codex; their retained versions and loading
evidence live in
[docs/developer/agent-adapter-smoke.md](docs/developer/agent-adapter-smoke.md).
Canonical behavior lives in [AGENTS.md](AGENTS.md) and routes through
[the agent context map](docs/developer/agent-context-map.md). Candidate clients,
including OpenCode, Pi, and a future Loopex coding surface, are unsupported until
their adapters and parity smokes exist.

## Product Toolchain

The bootstrap floor for future product work is OTP 26+ and Elixir 1.17+.
No product scaffold exists yet, so installing that toolchain does not create a
meaningful product command today. Before scaffolding, the first milestone plan
and red gate must lock the exact repository-owned setup, format, compile,
analysis, test, and gate commands and prove the declared outcome is still
missing. Only after their acceptance may implementation add the scaffold and
entrypoints that make those commands pass.

The M0 gate locks the self-hosting transition, and that transition has landed:
the local aggregate, its structural and mutation checks, and the tested
client-hook paths all run through the accepted Elixir/OTP toolchain, with the
seed's two bridge prerequisites removed. `mix loopex.self_hosting` reports the
replacement's measured size and names every behavior it dropped with the reason,
which is the material an independent reviewer weighs; no run passes or fails on
the figure.

The same gate installs `mix loopex.docs_check`, a repository-owned check over
**compiled** documentation. It reads the doc chunk of every compiled module, so it
answers what a reader of the published documentation would see rather than what
characters appear in a source file. Covered public code must carry `## Concept`
before `## Technical depth`; a module with no documentation at all fails, and one
marked `@moduledoc false` is excluded and counted in the report. Semantic
usefulness and proportional private comments remain review obligations.

Core will use only the Elixir/Erlang standard runtime. Provider, store, client,
transport, and other integration dependencies belong in adapter applications,
subject to the accepted plan and dependency-direction checks.

## Implementation Posture

Start with direct OTP and the smallest clear implementation. Production code,
tests, fixtures, helpers, public surface, and abstractions all count as system
cost. A new abstraction must name the concrete examples or current
implementations it unifies and why direct code is insufficient; do not add a
layer for a hypothetical future consumer.

Each accepted plan carries a proportional minimalism budget and locks any useful
ceilings or negative constraints in its gate. Raw line count is a review signal,
not a universal gate: it must not reward compressed code, hidden complexity, or
missing evidence. Keep tests focused and reusable, but never delete required
coverage merely to make the repository smaller.

Elixir modules, behaviours, callbacks, public APIs, public types, and important
boundaries explain both `## Concept` and `## Technical depth` in their standard
documentation. A private function uses adjacent `# Concept:` and
`# Technical depth:` comments only for a non-obvious invariant, effect, failure
mode, or design decision. Obvious helpers rely on clear names and direct code;
documentation should clarify rather than paraphrase syntax.

## Before Product Work

Read [AGENTS.md](AGENTS.md), then the
[plans status register](docs/plans/README.md), and use the
[agent context map](docs/developer/agent-context-map.md) only to load relevant
Concept sections and their exact Technical depth. Product implementation remains
unauthorized until the maintainer or a recorded delegate explicitly opens and
accepts the first milestone plan and branch-only red gate.

When product tests arrive, they must use a temporary `LOOPEX_HOME` and temporary
workspaces. Never point development or test commands at a real `~/.loopex`.

## Toolchain pairs

ADR 0002 locks two validated pairs, recorded in `.tool-versions`. Homebrew carries
only the current one, and it pairs Elixir against whatever OTP it ships, so the
floor pair needs a version manager. `mise` was used to provide both:

```text
mise install erlang@26.0
mise install elixir@1.17.0-otp-26
mise exec erlang@26.0 elixir@1.17.0-otp-26 -- bash scripts/check-m0-gate.sh
```

Alternating pairs also shares mutable dependency state. `MIX_BUILD_PATH` alone
leaves `deps/` and the Rebar cache common to both, which produces cache
restore/discard diagnostics and, once observed, a self-healing corrupt-beam
warning. Neither changed an exit status, but a genuinely isolated task root sets
`MIX_DEPS_PATH` as well:

```text
env MIX_BUILD_PATH=<root>/build MIX_DEPS_PATH=<root>/deps mix <task>
```

Do not activate a version manager inside the checkout. `.tool-versions` is a
digest-bound gate artifact listing both pairs, so a tool that reads it would pick
one arbitrarily; invoke the pair explicitly instead. The floor pair also needs its
own Hex and rebar archives (`mix local.hex --force`, `mix local.rebar --force`),
which are per-Elixir-version and live outside the checkout.
