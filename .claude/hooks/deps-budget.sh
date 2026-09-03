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

# Run once and reuse what it said. Running it twice -- silently to decide, then
# again to report -- let the two runs disagree: a build left mid-write by a
# killed process failed the first and recompiled successfully on the second, so
# the hook blocked while printing "dependency budget and direction hold". A
# block whose own evidence contradicts it is a block nobody believes.
# The capture sits in the condition because `set -e` would otherwise abort on a
# failing assignment before the status could be read -- which would exit with
# the command's own code and no explanation at all.
if output="$(mix loopex.deps_budget "$@" 2>&1)"; then
  exit 0
fi

printf '%s\n' "$output" >&2
echo "Blocked: the dependency budget rejects this change (ADR 0001)." >&2
exit 2
