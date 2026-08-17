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

# Any mix.exs is routed, including a fixture: the command decides scope from the
# application the file declares, so routing needs no list of paths to keep in
# sync. Scoping this to one path meant an adversarial fixture was never checked.
case "$file" in
  *mix.exs)
    .claude/hooks/deps-budget.sh "$file" || exit 2
    ;;
esac
exit 0
