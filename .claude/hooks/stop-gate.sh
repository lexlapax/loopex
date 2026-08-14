#!/usr/bin/env bash
# Stop hook: fast checks only — full gates are CI's job; Stop must never take
# minutes.
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
exit $fail
