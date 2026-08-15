#!/usr/bin/env bash
# PostToolUse[Edit|Write]: stdin is the tool-call JSON.
# Early feedback only (AGENTS.md); repository checks own enforcement, so fail
# open without jq.
set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
input="$(cat)"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
[ -z "$file" ] && exit 0

case "$file" in
  *.ex|*.exs) mix format "$file" >/dev/null 2>&1 || true ;;
esac

case "$file" in
  */apps/loopex/mix.exs|apps/loopex/mix.exs)
    .claude/hooks/deps-budget.sh || exit 2
    ;;
esac
exit 0
