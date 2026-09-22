#!/usr/bin/env bash
# Concept: one repository-owned description of a source extraction, so a build
# from an archive can prove it built exactly the committed tree and changed
# nothing in it.
#
# Technical depth: usage `source-archive-manifest.sh <extraction-root>`. Walks
# the tree with lstat semantics, never following a symbolic link, excluding
# only the top-level `_build` and `deps` paths and their descendants (a nested
# path with either name is included). It collects the complete result before
# writing, then writes only manifest bytes to standard output: records sorted
# by raw path bytes, each `kind NUL mode NUL path NUL value NUL`. `kind` is `f`,
# `l` or `d`; a regular file's mode is `755` when any execute bit is set and
# `644` otherwise, and links and directories use `0`; `value` is the lowercase
# SHA-256 of a file, the raw target of a link, or empty for a directory.
# Diagnostics go to standard error, and an unsupported entry or incomplete walk
# exits non-zero with no output.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ] || [ -L "$1" ]; then
  echo 'usage: source-archive-manifest.sh <extraction-root>' >&2
  exit 2
fi

cd "$1"

if stat -c %a . >/dev/null 2>&1; then
  permissions() { stat -c %a "$1"; }
else
  permissions() { stat -f %Lp "$1"; }
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
else
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

paths=$(mktemp "${TMPDIR:-/tmp}/loopex-manifest-paths.XXXXXX")
records=$(mktemp "${TMPDIR:-/tmp}/loopex-manifest-records.XXXXXX")
trap 'rm -f "$paths" "$records"' EXIT

find . -mindepth 1 \( -path ./_build -o -path ./deps \) -prune -o -print0 >"$paths" ||
  { echo 'source-archive-manifest: the walk did not complete' >&2; exit 1; }

while IFS= read -r -d '' entry; do
  path=${entry#./}

  if [ -L "$entry" ]; then
    target=$(readlink "$entry") ||
      { echo "source-archive-manifest: unreadable link" >&2; exit 1; }
    printf 'l\0000\000%s\000%s\000' "$path" "$target" >>"$records"
  elif [ -d "$entry" ]; then
    printf 'd\0000\000%s\000\000' "$path" >>"$records"
  elif [ -f "$entry" ]; then
    mode=644
    [ $(( 8#$(permissions "$entry") & 8#111 )) -ne 0 ] && mode=755
    digest=$(sha256 "$entry") ||
      { echo 'source-archive-manifest: unreadable file' >&2; exit 1; }
    printf 'f\000%s\000%s\000%s\000' "$mode" "$path" "$digest" >>"$records"
  else
    echo 'source-archive-manifest: unsupported entry kind' >&2
    exit 1
  fi
done < <(LC_ALL=C sort -z "$paths")

cat "$records"
