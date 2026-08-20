#!/usr/bin/env bash
# PreToolUse[Bash]: stdin is the tool-call JSON.
#
# Early feedback only (AGENTS.md); repository checks own retained enforcement.
# The field reader is a repository-owned command rather than logic duplicated
# here, so the parsing this hook depends on has one definition and one place to
# be corrected. When it is unavailable the hook fails open: feedback disappears,
# enforcement does not.
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
# A bounded view is used for matching. Stripping quotes from an unbounded string
# is where the remaining timeout lived: the reader became linear, and the same
# quadratic work reappeared in the shell that consumed it. Nothing legitimate this
# guard inspects is longer than the bound, and a longer one blocks rather than
# being scanned slowly.
read_field() {
  local out status
  out="$("$reader" "$@")" || status=$?

  case "${status:-0}" in
    0) printf '%s' "$out" ;;
    *) echo "Blocked: the tool call could not be read safely (reader exit ${status})." >&2
       exit 2 ;;
  esac
}

bounded_view() {
  local text="$1"

  if [ "${#text}" -gt 8192 ]; then
    echo "Blocked: field is too long to inspect safely." >&2
    exit 2
  fi

  text="${text//\"/}"
  printf '%s' "${text//\'/}"
}

cmd="$(read_field tool_input command)"
[ -z "$cmd" ] && exit 0

case "$cmd" in
  *"git commit"*)
    if printf '%s' "$cmd" | grep -qiE 'co-authored-by|generated with|generated-by'; then
      echo "Blocked: no AI-attribution trailers in commits (AGENTS.md)." >&2
      exit 2
    fi
    ;;
esac

path_view="$(bounded_view "${cmd}")"
real_loopex_home="${HOME%/}/.loopex"
case "$path_view" in
  *"~/.loopex"*|*'$HOME/.loopex'*|*'${HOME}/.loopex'*|*'${HOME%/}/.loopex'*|*"$real_loopex_home"*)
    echo "Blocked: never touch a real LOOPEX_HOME; use a temp dir (AGENTS.md)." >&2
    exit 2
    ;;
esac
exit 0
