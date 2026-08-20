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

# Concept: a field the reader could not read is a reason to block, not to allow.
# Technical depth: the reader announced it could not read a field and exited
# non-zero, and this took the empty output as "no such field" and allowed the call.
# Exit 2 is the only status the client treats as blocking, so a failure that is not
# translated into 2 is a failure that permits.
#
# No bounded view is needed here. The bash guard strips quotes before matching,
# which is quadratic on a long value; this guard matches the extracted path with
# `case` patterns directly, which is linear. An oversize path is already refused
# by the reader, so nothing reaches the match that would be slow to scan.
read_field() {
  local out status
  out="$("$reader" "$@")" || status=$?

  case "${status:-0}" in
    0) printf '%s' "$out" ;;
    *) echo "Blocked: the tool call could not be read safely (reader exit ${status})." >&2
       exit 2 ;;
  esac
}

path_value="$(read_field tool_input file_path notebook_path path)"
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
