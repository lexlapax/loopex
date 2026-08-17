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

cmd="$("$reader" tool_input command)"
[ -z "$cmd" ] && exit 0

case "$cmd" in
  *"git commit"*)
    if printf '%s' "$cmd" | grep -qiE 'co-authored-by|generated with|generated-by'; then
      echo "Blocked: no AI-attribution trailers in commits (AGENTS.md)." >&2
      exit 2
    fi
    ;;
esac

path_view="${cmd//\"/}"
path_view="${path_view//\'/}"
real_loopex_home="${HOME%/}/.loopex"
case "$path_view" in
  *"~/.loopex"*|*'$HOME/.loopex'*|*'${HOME}/.loopex'*|*'${HOME%/}/.loopex'*|*"$real_loopex_home"*)
    echo "Blocked: never touch a real LOOPEX_HOME; use a temp dir (AGENTS.md)." >&2
    exit 2
    ;;
esac
exit 0
