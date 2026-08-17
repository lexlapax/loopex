#!/usr/bin/env bash
# PostToolUse[Edit|Write]: stdin is the tool-call JSON.
#
# Early feedback only (AGENTS.md); repository checks own retained enforcement, so
# this fails open when the repository-owned field reader is unavailable.
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

reader="scripts/json-field.sh"
[ -x "$reader" ] || exit 0

file="$("./$reader" tool_input file_path)"
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
