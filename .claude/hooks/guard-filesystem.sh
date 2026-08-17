#!/usr/bin/env bash
# PreToolUse[Read|Grep|Glob|Edit|Write|NotebookEdit]: stdin is the tool-call JSON.
#
# Early feedback only (AGENTS.md); repository checks own retained enforcement.
# The three path fields are tried in the order the tools use them, which the
# repository-owned field reader resolves in one pass -- including on a Write
# whose payload carries a whole file body.
set -euo pipefail

root="${CLAUDE_PROJECT_DIR:-$(cd -- "$(dirname -- "$0")/../.." && pwd)}"
reader="$root/scripts/json-field.sh"
[ -x "$reader" ] || exit 0

path_value="$("$reader" tool_input file_path notebook_path path)"
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
