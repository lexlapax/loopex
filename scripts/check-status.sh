#!/usr/bin/env bash
# Keeps the human-facing status surfaces honest.
#
# A stale status line is worse than no status line, because both humans and
# agents act on it. This check does not judge whether the prose is accurate --
# it enforces that the entry points exist and that no plan file is invisible
# from the index a reader actually lands on.
#
# Read-only: inspects tracked files, writes nothing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

readme="README.md"
index="docs/plans/README.md"
status=0

# The README is the landing page; it must carry a status block and route to the
# plans index rather than leaving a reader to guess.
if ! grep -qE '^## Where Things Stand' "$readme"; then
  echo "${readme}: missing the '## Where Things Stand' status block" >&2
  status=1
fi

if ! grep -qE '\(docs/plans/?\)' "$readme"; then
  echo "${readme}: status block must link to docs/plans/" >&2
  status=1
fi

if [ ! -f "$index" ]; then
  echo "${index}: the plans index is missing" >&2
  exit 1
fi

for plan in docs/plans/*.md; do
  name="$(basename "$plan" .md)"
  [ "$name" = "README" ] && continue

  case "$name" in
    *-gate)
      # A gate is an acceptance contract for a plan; an orphan gate means the
      # locked bytes describe work no plan claims.
      if [ ! -f "docs/plans/${name%-gate}.md" ]; then
        echo "${plan}: gate has no matching docs/plans/${name%-gate}.md" >&2
        status=1
      fi
      ;;
    *)
      # Every milestone must be reachable from the index a reader lands on.
      if ! grep -qE "\`${name}\`" "$index"; then
        echo "${plan}: milestone '${name}' is not listed in ${index}" >&2
        echo "  remedy: add a row for it to the milestone table" >&2
        status=1
      fi
      ;;
  esac
done

if [ "$status" -ne 0 ]; then
  exit 1
fi

echo "status check passed"
