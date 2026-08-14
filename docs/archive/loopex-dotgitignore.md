# Loopex `.gitignore` seed

Copy the block below to the repository root as `.gitignore`. It keeps Loopex's
shared development contract visible—`AGENTS.md`, `CLAUDE.md`, `.codex/`,
`.claude/`, `.agents/skills/`, plans, ADRs, fixtures, vectors, and redacted
evidence—while excluding generated output and machine-local state.

## `.gitignore`

```gitignore
# Elixir, Erlang, and Mix -------------------------------------------------------
# Keep known generated roots explicit. Broad package and report rules can
# silently hide conformance repositories, fixtures, and retained evidence.
/_build/
/deps/
/cover/
/doc/
/.fetch
/apps/*/_build/
/apps/*/deps/
/apps/*/cover/
/apps/*/doc/
/apps/*/.fetch
/examples/*/_build/
/examples/*/deps/
/examples/*/cover/
/examples/*/doc/
/examples/*/.fetch

# VM, archive, package, and analysis output.
/*_crash.dump
/erl_crash.dump
/rebar3.crashdump
/crash.dump
/apps/*/erl_crash.dump
/apps/*/rebar3.crashdump
/apps/*/crash.dump
/examples/*/erl_crash.dump
/examples/*/rebar3.crashdump
/examples/*/crash.dump
/loopex-*.ez
/loopex-*.tar
/loopex-*.tar.gz
/loopex-*.zip
/dist/
/priv/plts/
/apps/*/priv/plts/
/*.plt
/*.plt.hash

# Language servers and local analysis caches.
/.elixir_ls/
/.lexical/
/.next_ls/
/.lsp/

# Optional adapter/tool ecosystems --------------------------------------------
/node_modules/
/assets/node_modules/
/apps/*/assets/node_modules/
/clients/*/node_modules/
/examples/*/node_modules/
/tools/*/node_modules/
/target/
/apps/*/native/*/target/
/clients/*/target/
/native/*/target/
/tools/*/target/
/__pycache__/
/clients/**/__pycache__/
/examples/**/__pycache__/
/tools/**/__pycache__/
/.venv/
/venv/
/clients/*/.venv/
/examples/*/.venv/
/tools/*/.venv/

# Loopex runtime and local test state -----------------------------------------
# Tests must still fail closed unless LOOPEX_HOME and workspaces are explicit
# temporary roots. Ignore rules are cleanup hygiene, not that safety boundary.
/.loopex/
/.loopex-home/
/var/loopex/
/tmp/
/.tmp/
/log/
/.test_metrics/
/test-results/
/coverage/
/artifacts/local/
/artifacts/tmp/

# Secrets and machine-local configuration -------------------------------------
# .gitignore is not secret protection; repository checks must reject known
# credentials and generated secrets before commit and in CI.
.env
.env.*
!.env.example
!.env.*.example
.envrc.local
/.direnv/
/.mise.local.toml
/config/*.local.exs
/config/*.secret.exs
/apps/*/config/*.local.exs
/apps/*/config/*.secret.exs

# Agent-client local state -----------------------------------------------------
# Track shared adapters and workflows. Never ignore .claude/, .codex/, or
# .agents/ wholesale.

# Claude Code: keep settings.json, hooks, agents, and any transitional shared
# files; exclude only per-machine state.
/.claude/settings.local.json
/.claude/.credentials.json
/.claude/projects/
/.claude/worktrees/
/.claude/debug/
/.claude/todos/
/.claude/shell-snapshots/
/.claude/logs/
/.claude/transcripts/
/.claude/.cache/

# Codex: keep config.toml, agents/, future reviewed hooks/rules, and other
# project adapter files. Exclude logs, sessions, auth, and caches if CODEX_HOME
# or log_dir is ever pointed inside the checkout.
/.codex-log/
/.codex/auth.json
/.codex/history.jsonl
/.codex/sessions/
/.codex/shell_snapshots/
/.codex/logs/
/.codex/tmp/
/.codex/.cache/
/.codex/hook_outputs/
/.codex/rollout*.jsonl
/.codex/session-*.jsonl
/.codex/*.db
/.codex/*.db-shm
/.codex/*.db-wal

# Shared Agent Skills: keep .agents/skills/; exclude only client-local caches.
/.agents/.cache/
/.agents/local/
/.agents/tmp/

# Editors and operating systems -----------------------------------------------
.DS_Store
Thumbs.db
/.idea/
/.vscode/*
!/.vscode/extensions.json
!/.vscode/settings.json
!/.vscode/tasks.json
!/.vscode/launch.json
```

## Deliberate non-ignores

Do not add broad `*.beam`, `*.app`, `*.ez`, `*.db`, `*.sqlite*`, `*.log`,
`*.jsonl`, `junit*.xml`, `*.lcov`, `artifacts/`, or `evidence/` patterns. Loopex
may intentionally track protocol vectors, database fixtures, sealed extension
archives and exact rollback bytes, report fixtures, log fixtures, or redacted
acceptance notes. Generated forms belong under one of the explicitly ignored
runtime, report, coverage, build, distribution, or local-artifact roots. When a
new nested toolchain is introduced, add its exact generated root instead of a
repository-wide basename rule.

Project ignore rules deliberately do not suppress arbitrary editor backup,
patch-reject, IDE-module, or compiled-language suffixes. Put those in a personal
global excludes file. If Loopex later generates one itself, ignore its exact
output root while keeping fixture and evidence paths visible.

Keep these shared files tracked:

- `mix.lock`, `.tool-versions`, and shared tool configuration;
- root and nested `AGENTS.md` files and the root `CLAUDE.md` shim;
- `.codex/config.toml` and `.codex/agents/*.toml`;
- `.claude/settings.json`, reviewed hooks, and client agent adapters;
- `.agents/skills/**` as the portable workflow source;
- public schemas, golden vectors, conformance fixtures, migration fixtures, and
  redacted evidence required by an accepted plan.

If a future tool creates new local state, ignore its narrow generated path.
Never ignore a whole vendor directory merely to silence `git status`.

## Bootstrap check

Run after installing the root `.gitignore`:

```bash
set -eu

for candidate_path in \
  .loopex/sessions/local.db \
  .claude/settings.local.json \
  .claude/worktrees/worker-1/file \
  .codex-log/codex-tui.log \
  .codex/sessions/session.jsonl \
  .agents/.cache/index.json \
  apps/loopex/_build/dev/lib/loopex/ebin/Elixir.Loopex.beam \
  apps/loopex/.fetch \
  apps/loopex/doc/index.html \
  examples/basic/.fetch \
  examples/basic/cover/index.html \
  examples/basic/doc/index.html \
  examples/basic/erl_crash.dump \
  native/pty/target/debug/pty \
  loopex-0.1.0.ez \
  test-results/junit.xml \
  coverage/lcov.info
do
  git check-ignore --no-index -q "$candidate_path" || {
    echo "FAIL: expected ignored: $candidate_path" >&2
    exit 1
  }
done

for candidate_path in \
  AGENTS.md \
  CLAUDE.md \
  .codex/config.toml \
  .codex/agents/release-reviewer.toml \
  .claude/settings.json \
  .claude/hooks/fast-check.sh \
  .agents/skills/gate/SKILL.md \
  .env.example \
  .env.test.example \
  .vscode/settings.json \
  test/fixtures/protocol/session.jsonl \
  test/fixtures/extensions/compat.ez \
  test/fixtures/extensions/rollback/exact-package.ez \
  test/fixtures/patch/change.orig \
  test/fixtures/patch/change.rej \
  test/fixtures/project/project.iml \
  test/fixtures/python/compiled.pyc \
  test/fixtures/repositories/__pycache__/sample.pyc \
  test/fixtures/reports/junit-example.xml \
  test/fixtures/repositories/doc/README.md \
  test/fixtures/repositories/target/source.txt \
  evidence/release/junit.xml
do
  if git check-ignore --no-index -q "$candidate_path"; then
    echo "FAIL: shared path is ignored: $candidate_path" >&2
    git check-ignore --no-index -v "$candidate_path" >&2 || true
    exit 1
  fi
done

echo "PASS: generated/local paths are ignored and shared contract paths remain visible"
```

The bootstrap check proves pattern behavior only. Secret scanning, temporary
home sentinels, dependency checks, gate locks, and evidence validation remain
repository-owned checks enforced by CI.
