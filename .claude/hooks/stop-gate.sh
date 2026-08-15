#!/usr/bin/env bash
# Stop hook: fast feedback only. Repository commands own full gates; hosted CI
# may mirror them and retain evidence. Stop must never take minutes.
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
fail=0
# Pre-implementation guard: with no Mix project there is nothing to format.
if [ -f mix.exs ] && command -v mix >/dev/null 2>&1; then
  if ! mix format --check-formatted >/dev/null 2>&1; then
    echo "Stop blocked: run mix format (warning-free checkpoints, AGENTS.md)." >&2
    fail=2
  fi
fi
.claude/hooks/deps-budget.sh || fail=2
# Repository-owned seed check; subsecond today. Keep slow gates in repository
# commands rather than letting Stop grow slow.
if ! bootstrap_err="$(scripts/check-agent-bootstrap.sh 2>&1 >/dev/null)"; then
  echo "Stop blocked: ${bootstrap_err:-scripts/check-agent-bootstrap.sh failed}" >&2
  fail=2
fi
exit $fail
