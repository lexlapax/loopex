#!/usr/bin/env bash
# Runs the no-Git archive verifier on an actual released archive and one
# deliberately mismatched complete tree projection.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/loopex-rollback-archive-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
sha=$(git -C "$root" rev-parse 'v0.2.0^{commit}')
mkdir "$work/tree"
git -C "$root" archive "$sha" >"$work/archive.tar"
(umask 022; tar -xf "$work/archive.tar" -C "$work/tree")
bash "$root/scripts/source-archive-manifest.sh" "$work/tree" >"$work/manifest"
git -C "$root" ls-tree -rz -r -t --full-tree "$sha" >"$work/projection"
git -C "$root" show -s --format='commit %H%ncommitter-date %cI' "$sha" >"$work/identity"
elixir "$root/scripts/rollback-archive-check.exs" \
  "$work/manifest" "$work/projection" "$work/identity" "$sha" "$work/tree"
git -C "$root" ls-tree -rz -r -t --full-tree HEAD >"$work/wrong-projection"
if elixir "$root/scripts/rollback-archive-check.exs" \
  "$work/manifest" "$work/wrong-projection" "$work/identity" "$sha" "$work/tree" \
  >"$work/wrong-output" 2>&1; then
  echo 'rollback-archive-test: mismatched tree projection passed' >&2
  exit 1
fi
grep -q 'archive kind, mode or path projection differs' "$work/wrong-output" ||
  { echo 'rollback-archive-test: wrong failure reason' >&2; exit 1; }
printf 'rollback-archive-test: PASS\n'
