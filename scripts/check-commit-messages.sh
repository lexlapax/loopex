#!/usr/bin/env bash
# Portable commit-message policy check.
#
# AGENTS.md requires repository checks, not client hooks, to own enforcement.
# This check is read-only: it inspects git history and writes nothing, so an
# effectively read-only reviewer can run it.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Last commit written under the pre-marker convention. Commits at or before this
# SHA are historical and exempt. Advancing this baseline is a policy weakening
# and requires the same authority as any other gate change.
baseline="${LOOPEX_COMMIT_BASELINE:-f19d2a6c941aeeebdb125f85a02ef5bd47198bed}"

if ! git cat-file -e "${baseline}^{commit}" 2>/dev/null; then
  echo "commit message check unavailable: baseline ${baseline} not in this clone" >&2
  echo "fetch full history (for example actions/checkout with fetch-depth: 0)" >&2
  exit 1
fi

# area(marker): summary
#   area   - lowercase subsystem, matching the existing history
#   marker - planning | seed | a milestone name (M0, v0.1, 1.0)
title_pattern='^[a-z][a-z0-9_-]*\((planning|seed|M[0-9]+|v[0-9]+\.[0-9]+|1\.0)\): [^ ].*$'
banned_pattern='co-authored-by|generated with|generated-by|🤖'

status=0
range="${baseline}..HEAD"

for sha in $(git rev-list --no-merges "$range"); do
  title="$(git log -1 --format=%s "$sha")"
  body="$(git log -1 --format=%B "$sha")"

  if ! printf '%s' "$title" | grep -qE "$title_pattern"; then
    echo "$sha: title must be 'area(marker): summary' with marker planning, seed, or a milestone" >&2
    echo "  got: $title" >&2
    status=1
  fi

  if [ "${#title}" -gt 72 ]; then
    echo "$sha: title is ${#title} characters; keep it at 72 or fewer" >&2
    status=1
  fi

  if printf '%s' "$body" | grep -qiE "$banned_pattern"; then
    echo "$sha: no AI-attribution or generated-by claims in commit messages" >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  exit 1
fi

# Always report the baseline. The override exists so the check can be tested
# against known-bad history; printing it keeps a raised baseline visible in
# retained evidence instead of silently shrinking the checked range.
echo "commit message check passed (baseline ${baseline})"
