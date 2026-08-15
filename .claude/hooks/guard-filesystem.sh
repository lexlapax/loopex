#!/usr/bin/env bash
# PreToolUse[Read|Grep|Glob|Edit|Write|NotebookEdit]: stdin is the tool-call JSON.
# Early feedback only (AGENTS.md); repository checks own retained enforcement.
set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
path_value="$(printf '%s' "$input" |
  jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty')"
[ -z "$path_value" ] && exit 0

real_loopex_home="${HOME%/}/.loopex"
case "$path_value" in
  "~/.loopex"|"~/.loopex/"*|\
  '$HOME/.loopex'|'$HOME/.loopex/'*|\
  '${HOME}/.loopex'|'${HOME}/.loopex/'*|\
  '${HOME%/}/.loopex'|'${HOME%/}/.loopex/'*|\
  "$real_loopex_home"|"$real_loopex_home/"*)
    echo "Blocked: never touch a real LOOPEX_HOME; use a temp dir (AGENTS.md)." >&2
    exit 2
    ;;
esac

exit 0
