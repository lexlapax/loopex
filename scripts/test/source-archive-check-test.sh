#!/usr/bin/env bash
# Prove the fresh-source judge binds archive contents to Git blobs and refuses
# a symlink in the one declared build-output slot.
set -euo pipefail

source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/loopex-source-archive-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
tree="$work/tree"
mkdir -p "$repo/scripts" "$repo/apps/loopex_cli" "$tree"
cp "$source_root/scripts/source-archive-manifest.sh" "$repo/scripts/"
printf 'SOURCE_IDENTITY export-subst\n' >"$repo/.gitattributes"
printf 'commit $Format:%%H$\ncommitter-date $Format:%%cI$\n' >"$repo/SOURCE_IDENTITY"
printf 'committed bytes\n' >"$repo/source.txt"
printf 'backslash bytes\n' >"$repo/back\\slash"
printf 'newline bytes\n' >"$repo/line"$'\n'"name"
printf 'fixture\n' >"$repo/apps/loopex_cli/seed"
ln -s 'source.txt' "$repo/source-link"
git -C "$repo" init -q
git -C "$repo" add .
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
sha=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" archive "$sha" | tar -x -C "$tree"
git -C "$repo" ls-files -z >"$work/inventory"
producer="$repo/scripts/source-archive-manifest.sh"
cp "$producer" "$work/retained-producer"
checker="$source_root/scripts/source-archive-check.exs"
bash "$producer" "$tree" >"$work/before"

(cd "$repo" && elixir "$checker" verify "$work/before" "$work/inventory" "$sha" "$tree") \
  >"$work/positive.log"
grep -q 'source-archive-check: verified' "$work/positive.log"

printf 'unmanifested bytes\n' >"$tree/extra.txt"
if (cd "$repo" && elixir "$checker" verify "$work/before" "$work/inventory" "$sha" "$tree") \
  >"$work/extra-file.log" 2>&1; then
  echo 'source-archive-check-test: unmanifested extracted file passed' >&2
  exit 1
fi
grep -q 'unmanifested or missing path' "$work/extra-file.log"
rm "$tree/extra.txt"
mkdir "$tree/empty-extra"
if (cd "$repo" && elixir "$checker" verify "$work/before" "$work/inventory" "$sha" "$tree") \
  >"$work/extra-directory.log" 2>&1; then
  echo 'source-archive-check-test: unmanifested extracted directory passed' >&2
  exit 1
fi
grep -q 'unmanifested or missing path' "$work/extra-directory.log"
rmdir "$tree/empty-extra"

for output_root in deps _build; do
  mkdir -p "$tree/$output_root/injected"
  printf 'hidden dependency\n' >"$tree/$output_root/injected/code"
  if (cd "$repo" && elixir "$checker" verify "$work/before" "$work/inventory" "$sha" "$tree") \
    >"$work/prebuild-$output_root.log" 2>&1; then
    echo "source-archive-check-test: hidden pre-build $output_root passed" >&2
    exit 1
  fi
  grep -q 'build output root exists before the source build' "$work/prebuild-$output_root.log"
  rm -rf "$tree/$output_root"
done

printf 'changed bytes\n' >"$tree/source.txt"
if (cd "$repo" && elixir "$checker" verify "$work/before" "$work/inventory" "$sha" "$tree") \
  >"$work/stale-manifest.log" 2>&1; then
  echo 'source-archive-check-test: stale valid manifest hid changed tree bytes' >&2
  exit 1
fi
grep -q 'file content differs from the extracted tree' "$work/stale-manifest.log"
bash "$producer" "$tree" >"$work/changed-file"
if (cd "$repo" && elixir "$checker" verify "$work/changed-file" "$work/inventory" "$sha" "$tree") \
  >"$work/changed-file.log" 2>&1; then
  echo 'source-archive-check-test: changed file bytes passed Git blob proof' >&2
  exit 1
fi
grep -q "file content differs from the commit's blob" "$work/changed-file.log"

printf 'committed bytes\n' >"$tree/source.txt"
rm "$tree/source-link"
ln -s 'different-target' "$tree/source-link"
bash "$producer" "$tree" >"$work/changed-link"
if (cd "$repo" && elixir "$checker" verify "$work/changed-link" "$work/inventory" "$sha" "$tree") \
  >"$work/changed-link.log" 2>&1; then
  echo 'source-archive-check-test: changed link target passed Git blob proof' >&2
  exit 1
fi
grep -q "link target differs from the commit's blob" "$work/changed-link.log"

rm "$tree/source-link"
ln -s 'source.txt' "$tree/source-link"
ln -s "$tree/source.txt" "$tree/apps/loopex_cli/loopex"
bash "$producer" "$tree" >"$work/link-output"
if elixir "$checker" unchanged "$work/before" "$work/link-output" \
  >"$work/link-output.log" 2>&1; then
  echo 'source-archive-check-test: symlinked escript output passed' >&2
  exit 1
fi
grep -q 'declared escript output is not an executable ordinary file' "$work/link-output.log"

rm "$tree/apps/loopex_cli/loopex"
printf 'built command\n' >"$tree/apps/loopex_cli/loopex"
chmod 755 "$tree/apps/loopex_cli/loopex"
bash "$producer" "$tree" >"$work/ordinary-output"
elixir "$checker" unchanged "$work/before" "$work/ordinary-output" >"$work/ordinary-output.log"
grep -q 'the build left the extraction unchanged' "$work/ordinary-output.log"

printf 'changed source after build\n' >"$tree/source.txt"
printf '%s\n' '#!/bin/sh' "cat '$work/before'" >"$tree/scripts/source-archive-manifest.sh"
bash "$work/retained-producer" "$tree" >"$work/producer-tamper"
if elixir "$checker" unchanged "$work/before" "$work/producer-tamper" \
  >"$work/producer-tamper.log" 2>&1; then
  echo 'source-archive-check-test: mutated source and producer passed' >&2
  exit 1
fi
grep -q 'build changed the extraction' "$work/producer-tamper.log"

# Git can name an otherwise empty tree entry through plumbing even though
# ordinary git add does not record empty directories. A missing entry cannot
# be hidden by the tracked file/link inventory.
empty_oid=$(git -C "$repo" mktree </dev/null)
attrs_oid=$(git -C "$repo" rev-parse "$sha:.gitattributes")
identity_oid=$(git -C "$repo" rev-parse "$sha:SOURCE_IDENTITY")
root_oid=$(
  printf '100644 blob %s\t.gitattributes\n100644 blob %s\tSOURCE_IDENTITY\n040000 tree %s\tempty-dir\n' \
    "$attrs_oid" "$identity_oid" "$empty_oid" | git -C "$repo" mktree
)
empty_sha=$(
  printf 'empty directory witness\n' | git -C "$repo" -c user.name=Fixture \
    -c user.email=fixture@example.invalid commit-tree "$root_oid" -p "$sha"
)
mkdir "$work/empty-tree"
git -C "$repo" archive "$empty_sha" | tar -x -C "$work/empty-tree"
if [ -d "$work/empty-tree/empty-dir" ]; then rmdir "$work/empty-tree/empty-dir"; fi
printf '.gitattributes\000SOURCE_IDENTITY\000' >"$work/empty-inventory"
bash "$producer" "$work/empty-tree" >"$work/empty-omitted"
if (cd "$repo" && elixir "$checker" verify "$work/empty-omitted" \
  "$work/empty-inventory" "$empty_sha" "$work/empty-tree") >"$work/empty-omitted.log" 2>&1; then
  echo 'source-archive-check-test: missing Git empty directory passed' >&2
  exit 1
fi
grep -q 'manifest omits or adds a Git-tree path' "$work/empty-omitted.log"
printf 'source-archive-check-test: PASS Git blob, ordinary-output and retained-producer controls\n'
