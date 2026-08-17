#!/usr/bin/env bash
# Bootstrap check from docs/archive/loopex-dotgitignore.md: generated/local
# paths stay ignored while shared contract paths remain visible. Pattern
# behavior only; secret scanning and gate locks are separate checks.
set -eu
cd "$(git rev-parse --show-toplevel)"

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
  DEVELOPMENT.md \
  .codex/config.toml \
  .codex/agents/release-reviewer.toml \
  .claude/settings.json \
  .claude/hooks/stop-gate.sh \
  .agents/skills/gate/SKILL.md \
  .env.example \
  .env.test.example \
  .vscode/settings.json \
  scripts/check-bootstrap.sh \
  scripts/check-agent-bootstrap.sh \
  scripts/json-field.sh \
  test/fixtures/python/module.py \
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

echo "gitignore check passed"
