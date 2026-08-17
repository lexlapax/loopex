#!/usr/bin/env bash
# Early feedback only (AGENTS.md). The repository command is the enforcement;
# this hook calls it and never reimplements it. An earlier version parsed the
# core mix.exs with awk, which meant two definitions of the budget that could
# disagree -- and the hook's copy was the one nobody tested.
#
# An optional argument is forwarded to the command, which decides scope from the
# application the file declares. This hook makes no path decisions of its own.
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

# No toolchain means no feedback, not a block: enforcement lives in the gate.
command -v mix >/dev/null 2>&1 || exit 0
[ -f mix.exs ] || exit 0

if ! mix loopex.deps_budget "$@" >/dev/null 2>&1; then
  mix loopex.deps_budget "$@" >&2 || true
  echo "Blocked: the dependency budget rejects this change (ADR 0001)." >&2
  exit 2
fi
exit 0
