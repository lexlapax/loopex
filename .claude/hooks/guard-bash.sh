#!/usr/bin/env bash
# PreToolUse[Bash]: stdin is the tool-call JSON.
# Early feedback only (AGENTS.md); repository checks own enforcement, so fail
# open without jq.
set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
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
