#!/usr/bin/env bash
# The mechanical form of vision §7.2: the loopex core application depends on
# the Elixir/Erlang standard runtime only.
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
MIX_EXS="apps/loopex/mix.exs"
[ -f "$MIX_EXS" ] || exit 0
# Any {:dep, ...} tuple in the core deps list violates the budget.
if awk '/defp? deps/,/end/' "$MIX_EXS" | grep -qE '\{:\w+'; then
  echo "Blocked: apps/loopex may depend on stdlib+OTP only (vision §7.2)." >&2
  echo "Provider/store/terminal/JSON deps belong in adapter apps." >&2
  exit 2
fi
exit 0
