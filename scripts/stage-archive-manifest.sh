#!/usr/bin/env bash
# Concept: retain the exact source-archive manifest and source identity for a
# named commit without changing any prior evidence.
# Technical depth: usage `stage-archive-manifest.sh SHA OUT`. A fresh archive
# extraction uses scoped umask 022 inside a hostile 0777 caller subshell. The
# extracted producer writes NUL-delimited bytes to an exclusive sibling. Both
# final names publish by no-overwrite hard links only after staging succeeds.
set -euo pipefail

fail() { printf 'stage-archive-manifest: %s\n' "$1" >&2; exit 1; }

if [ "$#" -ne 2 ]; then
  printf 'usage: stage-archive-manifest.sh SHA OUT\n' >&2
  exit 2
fi

sha=$1
out=$2
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail invalid_sha
[ -n "$out" ] || fail invalid_output
case "$out" in
  /*|./*|../*) ;;
  *) out="./$out" ;;
esac
[ -d "$(dirname "$out")" ] || fail output_parent_missing
sidecar="$out.source-identity"

if [ -e "$out" ] || [ -L "$out" ] || [ -e "$sidecar" ] || [ -L "$sidecar" ]; then
  fail output_exists
fi

[ "$(git cat-file -t "$sha" 2>/dev/null || true)" = commit ] || fail invalid_sha

umask 077
manifest_tmp=''
identity_tmp=''
work=''
out_created=0
sidecar_created=0
published=0

cleanup() {
  status=$?
  trap - EXIT
  set +e
  if [ "$published" -ne 1 ]; then
    if [ "$out_created" -eq 1 ] && [ -n "$manifest_tmp" ] && [ "$out" -ef "$manifest_tmp" ]; then
      rm -f "$out"
    fi
    if [ "$sidecar_created" -eq 1 ] && [ -n "$identity_tmp" ] && [ "$sidecar" -ef "$identity_tmp" ]; then
      rm -f "$sidecar"
    fi
  fi
  [ -z "$manifest_tmp" ] || rm -f "$manifest_tmp"
  [ -z "$identity_tmp" ] || rm -f "$identity_tmp"
  [ -z "$work" ] || rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

manifest_tmp=$(mktemp "$out.tmp.XXXXXX" 2>/dev/null) || fail output_unavailable
identity_tmp=$(mktemp "$sidecar.tmp.XXXXXX" 2>/dev/null) || fail output_unavailable
work=$(mktemp -d "${TMPDIR:-/tmp}/loopex-stage-archive.XXXXXX" 2>/dev/null) ||
  fail extraction_unavailable
tree="$work/src"

if ! (
  umask 0777
  printf 'CALLER_UMASK=%s\n' "$(umask)" >&2
  (
    umask 022
    printf 'EXTRACTION_UMASK=%s\n' "$(umask)" >&2
    mkdir "$tree" && git archive "$sha" | tar -x -C "$tree"
  )
); then
  fail archive_extraction_failed
fi

[ -f "$tree/SOURCE_IDENTITY" ] && [ ! -L "$tree/SOURCE_IDENTITY" ] ||
  fail source_identity_missing
[ -f "$tree/scripts/source-archive-manifest.sh" ] &&
  [ ! -L "$tree/scripts/source-archive-manifest.sh" ] || fail producer_missing

if ! bash "$tree/scripts/source-archive-manifest.sh" "$tree" >"$manifest_tmp"; then
  fail manifest_failed
fi
cp "$tree/SOURCE_IDENTITY" "$identity_tmp" || fail source_identity_unreadable

ln "$manifest_tmp" "$out" 2>/dev/null || fail output_unavailable
out_created=1
ln "$identity_tmp" "$sidecar" 2>/dev/null || fail output_unavailable
sidecar_created=1
published=1
