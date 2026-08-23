#!/usr/bin/env bash
# Portable working-state hygiene check.
#
# Landed work must leave no residue: a branch already contained in the
# integration branch, or a worktree whose path is gone, is state a later agent
# or client can misread as in-flight work. In-flight work is untouched — an
# unmerged branch and a live worktree are legitimate parallel writers.
#
# Read-only: inspects git refs and worktree metadata, writes nothing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

integration="${LOOPEX_INTEGRATION_REF:-origin/main}"
status=0

# Worktrees whose path no longer exists are always residue, remote or not.
prunable="$(git worktree prune --dry-run 2>/dev/null || true)"
if [ -n "$prunable" ]; then
  echo "stale worktree metadata:" >&2
  printf '%s\n' "$prunable" >&2
  echo "  remedy: git worktree prune" >&2
  status=1
fi

if git rev-parse --verify --quiet "$integration" >/dev/null; then
  # Branches already contained in the integration ref are landed work.
  # Query refs directly: `git branch` emits a synthetic detached-HEAD display
  # line that is not a branch and must not become cleanup residue.
  merged="$(git for-each-ref --merged "$integration" --format='%(refname:short)' refs/heads \
    | grep -vxE 'main' || true)"
  if [ -n "$merged" ]; then
    echo "branches already merged into ${integration}:" >&2
    printf '%s\n' "$merged" | sed 's/^/  /' >&2
    echo "  remedy: git branch -d <branch>" >&2
    status=1
  fi

  # A worktree checked out on a landed branch is the same residue.
  while read -r wt_path; do
    [ -n "$wt_path" ] || continue
    [ "$wt_path" = "$(git rev-parse --show-toplevel)" ] && continue
    if [ ! -d "$wt_path" ]; then
      continue
    fi
    # A detached worktree has no branch, so compare its commit directly.
    # Skipping it would let landed work hide behind a detached HEAD.
    wt_branch="$(git -C "$wt_path" symbolic-ref --quiet --short HEAD || true)"
    # The integration branch is never residue: a worktree on it is the checkout
    # an integrator works from. The branch scan above already exempts main, but
    # this loop did not, so running the check from any linked worktree reported
    # the primary checkout as landed work and offered to delete it.
    [ "$wt_branch" = "main" ] && continue
    if [ -n "$wt_branch" ]; then
      wt_ref="$wt_branch"
      wt_label="$wt_branch"
    else
      wt_ref="$(git -C "$wt_path" rev-parse --quiet --verify HEAD || true)"
      [ -n "$wt_ref" ] || continue
      wt_label="detached at ${wt_ref}"
    fi
    if git merge-base --is-ancestor "$wt_ref" "$integration" 2>/dev/null; then
      echo "worktree on work already merged into ${integration}:" >&2
      echo "  ${wt_path} (${wt_label})" >&2
      echo "  remedy: git worktree remove ${wt_path}" >&2
      status=1
    fi
  done < <(git worktree list --porcelain | sed -n 's/^worktree //p')

  scope="against ${integration}"
else
  # A fork with no remote must still be able to develop, so a missing
  # integration ref cannot fail the aggregate. Say so out loud rather than
  # passing silently — an unstated skip is an ineffective check.
  echo "note: ${integration} not present; branch residue not checked" >&2
  scope="worktree paths only (${integration} absent)"
fi

if [ "$status" -ne 0 ]; then
  exit 1
fi

echo "repo hygiene check passed (${scope})"
