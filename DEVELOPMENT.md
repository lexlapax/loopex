# Development

Loopex is pre-implementation. This document describes how to validate and work
on the repository seed before the first milestone plan and executable product
gate are accepted. There is no Mix project, installable package, or product
test suite yet.

The canonical status for the checked-out revision, including currently
authorized work and the next maintainer decision, is in
[docs/plans/README.md](docs/plans/README.md). Its Directing the Work section
owns how development is requested — the verbs and where each one stops. This
file owns the commands those verbs run, and milestone state lives in neither.
The split is deliberate: the verbs outlive the toolchain, so replacing the seed
bridges with Mix entrypoints changes the commands here and nothing there. The
[development charter](docs/developer/development-charter.md#concept) explains the
project's clarity and traceability commitments; its
[technical companion](docs/developer/development-charter-technical.md#technical-depth) defines
the exact documentation, review, and code-comment conventions.

## Bootstrap Prerequisites

The provider-neutral bootstrap check requires:

- Git;
- Bash;
- a POSIX userland providing `cat`, `grep`, `readlink`, `sed`, and `tr`;
- Python 3.11 or newer, including the standard-library `tomllib` module; and
- `jq`.

Python and `jq` are temporary seed/M0 bridges, not enduring project
dependencies. Before M0 closes, repository checks migrate to Elixir
standard-library or Mix entrypoints, and tested client-hook paths migrate to them.
Removing a tested hook instead requires the accepted M0 plan to disposition the
behavior explicitly with equivalent protection or an explicitly accepted loss.
The M0 gate proves adapter behavior with `jq` absent, so feedback cannot silently
disappear. These two prerequisites are then removed. The lasting development
baseline is Git, shell/POSIX tools, and the accepted Elixir/OTP toolchain.

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
command but does not define it. The aggregate, its in-memory mutation tests, and
its Git-history resolver controls only read the checkout and do not rely on a
writable ambient temporary directory, so an effectively read-only reviewer can
run the exact same command.

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

The M0 gate also locks the self-hosting transition: by closure, the local
aggregate, its structural/mutation checks, and tested client-hook paths run
through the accepted Elixir/OTP toolchain without Python or `jq`. The same gate
adds a Mix check over compiled documentation so covered public code carries
Concept before Technical depth; semantic usefulness and proportional private
comments remain review obligations.

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
