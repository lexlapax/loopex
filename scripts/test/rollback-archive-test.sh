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
printf 'unmanifested bytes\n' >"$work/tree/extra.txt"
if elixir "$root/scripts/rollback-archive-check.exs" \
  "$work/manifest" "$work/projection" "$work/identity" "$sha" "$work/tree" \
  >"$work/extra-file.log" 2>&1; then
  echo 'rollback-archive-test: unmanifested file passed' >&2
  exit 1
fi
grep -q 'unmanifested or missing path' "$work/extra-file.log"
rm "$work/tree/extra.txt"
mkdir "$work/tree/empty-extra"
if elixir "$root/scripts/rollback-archive-check.exs" \
  "$work/manifest" "$work/projection" "$work/identity" "$sha" "$work/tree" \
  >"$work/extra-directory.log" 2>&1; then
  echo 'rollback-archive-test: unmanifested directory passed' >&2
  exit 1
fi
grep -q 'unmanifested or missing path' "$work/extra-directory.log"
rmdir "$work/tree/empty-extra"
for output_root in deps _build; do
  mkdir -p "$work/tree/$output_root/injected"
  printf 'hidden build input\n' >"$work/tree/$output_root/injected/code"
  if elixir "$root/scripts/rollback-archive-check.exs" \
    "$work/manifest" "$work/projection" "$work/identity" "$sha" "$work/tree" \
    >"$work/prebuild-$output_root.log" 2>&1; then
    echo "rollback-archive-test: hidden pre-build $output_root passed" >&2
    exit 1
  fi
  grep -q 'build output root exists before the rollback build' "$work/prebuild-$output_root.log"
  rm -rf "$work/tree/$output_root"
done
git -C "$root" ls-tree -rz -r -t --full-tree HEAD >"$work/wrong-projection"
if elixir "$root/scripts/rollback-archive-check.exs" \
  "$work/manifest" "$work/wrong-projection" "$work/identity" "$sha" "$work/tree" \
  >"$work/wrong-output" 2>&1; then
  echo 'rollback-archive-test: mismatched tree projection passed' >&2
  exit 1
fi
grep -q 'archive kind, mode or path projection differs' "$work/wrong-output" ||
  { echo 'rollback-archive-test: wrong failure reason' >&2; exit 1; }

printf 'changed rollback source\n' >"$work/tree/README.md"
bash "$root/scripts/source-archive-manifest.sh" "$work/tree" >"$work/changed-file-manifest"
if elixir "$root/scripts/rollback-archive-check.exs" \
  "$work/changed-file-manifest" "$work/projection" "$work/identity" "$sha" "$work/tree" \
  >"$work/changed-file-output" 2>&1; then
  echo 'rollback-archive-test: changed file bytes passed' >&2
  exit 1
fi
grep -q 'archive file differs from the commit blob' "$work/changed-file-output" ||
  { echo 'rollback-archive-test: changed file gave wrong failure' >&2; exit 1; }
tar -xf "$work/archive.tar" -C "$work/tree" README.md

rm "$work/tree/.claude/skills"
ln -s 'different-target' "$work/tree/.claude/skills"
bash "$root/scripts/source-archive-manifest.sh" "$work/tree" >"$work/changed-link-manifest"
if elixir "$root/scripts/rollback-archive-check.exs" \
  "$work/changed-link-manifest" "$work/projection" "$work/identity" "$sha" "$work/tree" \
  >"$work/changed-link-output" 2>&1; then
  echo 'rollback-archive-test: changed link target passed' >&2
  exit 1
fi
grep -q 'archive link differs from the commit blob' "$work/changed-link-output" ||
  { echo 'rollback-archive-test: changed link gave wrong failure' >&2; exit 1; }
printf 'rollback-archive-test: PASS\n'
