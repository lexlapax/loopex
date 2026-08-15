# Development

Loopex is pre-implementation. This document describes how to validate and work
on the repository seed before the first stage plan and executable product gate
are accepted. There is no Mix project, installable package, or product test
suite yet.

## Bootstrap Prerequisites

The provider-neutral bootstrap check requires:

- Git;
- Bash;
- a POSIX userland providing `cat`, `grep`, `readlink`, `sed`, and `tr`;
- Python 3.11 or newer, including the standard-library `tomllib` module; and
- `jq`.

The checkout must preserve the tracked relative `.claude/skills` symlink. On
Windows, WSL is the straightforward path; Git Bash also requires Windows
Developer Mode or equivalent symlink permission and Git symlink support. Native
PowerShell bootstrap commands are not provided yet.

Verify a checkout from the repository root:

```bash
git status --short --branch
bash scripts/check-bootstrap.sh
```

The aggregate runs the agent/client bootstrap check and the ignore-policy
check. It requires no GitHub account, `gh` CLI, hosted CI service, credentials,
network access, coding-agent client, or product dependency download. Hosted CI
may mirror this command but does not define it.

## Coding-Agent Clients

Coding-agent clients are optional development tools, not project dependencies.
The currently tested adapters are Claude Code and Codex; their retained versions
and loading evidence live in
[docs/developer/agent-adapter-smoke.md](docs/developer/agent-adapter-smoke.md).
Canonical behavior lives in [AGENTS.md](AGENTS.md) and routes through
[the agent context map](docs/developer/agent-context-map.md). Candidate clients,
including OpenCode, Pi, and a future Loopex coding surface, are unsupported until
their adapters and parity smokes exist.

## Product Toolchain

The bootstrap floor for future product work is OTP 26+ and Elixir 1.17+.
No product scaffold exists yet, so installing that toolchain does not create a
meaningful product command today. Before scaffolding, the first stage plan and
red gate must lock the exact repository-owned setup, format, compile, analysis,
test, and gate commands and prove the declared outcome is still missing. Only
after their acceptance may implementation add the scaffold and entrypoints that
make those commands pass.

Core will use only the Elixir/Erlang standard runtime. Provider, store, client,
transport, and other integration dependencies belong in adapter applications,
subject to the accepted plan and dependency-direction checks.

## Before Product Work

Read [AGENTS.md](AGENTS.md), then use the
[agent context map](docs/developer/agent-context-map.md) to load the relevant
vision sections and current stage state. Product implementation remains
unauthorized until the maintainer explicitly opens and accepts the first stage
plan and branch-only red gate.

When product tests arrive, they must use a temporary `LOOPEX_HOME` and temporary
workspaces. Never point development or test commands at a real `~/.loopex`.
