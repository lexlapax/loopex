#!/usr/bin/env bash
# Concept: stage retained archive evidence from a commit without modifying an
# existing output or silently substituting the working tree for the archive.
# Technical depth: a private fixture repository exercises binary output and
# source identity under the hostile caller umask required by the M6 plan.
set -euo pipefail

source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
stage="$source_root/scripts/stage-archive-manifest.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/loopex-stage-manifest-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

fail() { printf 'stage-archive-manifest-test: %s\n' "$1" >&2; exit 1; }

repo="$work/repo"
mkdir -p "$repo/scripts" "$work/retained"
cp "$source_root/scripts/source-archive-manifest.sh" "$repo/scripts/source-archive-manifest.sh"
cp "$source_root/SOURCE_IDENTITY" "$repo/SOURCE_IDENTITY"
cp "$source_root/.gitattributes" "$repo/.gitattributes"
printf 'committed bytes\n' >"$repo/README.md"
printf 'backslash-name bytes\n' >"$repo/back\\slash"
printf 'newline-name bytes\n' >"$repo/line"$'\n'"name"
ln -s $'target\n\n' "$repo/newline-link"
git -C "$repo" init -q
git -C "$repo" add .
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
sha=$(git -C "$repo" rev-parse HEAD)
printf 'dirty bytes\n' >"$repo/README.md"

out="$work/retained/manifest"
(cd "$repo" && umask 0777 && bash "$stage" "$sha" "$out") >"$work/stdout" 2>"$work/stderr" ||
  fail 'fresh archive staging failed'

[ ! -s "$work/stdout" ] || fail 'staging emitted manifest data to stdout'
[ -f "$out" ] || fail 'manifest missing'
[ -f "$out.source-identity" ] || fail 'source identity sidecar missing'
grep -qx 'CALLER_UMASK=0777' "$work/stderr" || fail 'hostile caller umask not recorded'
grep -qx 'EXTRACTION_UMASK=0022' "$work/stderr" || fail 'scoped extraction umask not recorded'

mkdir "$work/expected-tree"
(cd "$repo" && umask 022 && git archive "$sha" | tar -x -C "$work/expected-tree")
bash "$work/expected-tree/scripts/source-archive-manifest.sh" "$work/expected-tree" >"$work/expected"
cmp -s "$work/expected" "$out" || fail 'manifest differs from exact executed archive output'
cmp -s "$work/expected-tree/SOURCE_IDENTITY" "$out.source-identity" ||
  fail 'sidecar differs from exact archive bytes'
grep -q "^commit $sha$" "$out.source-identity" || fail 'sidecar does not name archived commit'

# A local replacement ref must not change the archive selected by a full SHA.
printf 'replacement bytes\n' >"$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm replacement
replacement_sha=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" replace "$sha" "$replacement_sha"
replacement_out="$work/retained/replacement-safe"
(cd "$repo" && bash "$stage" "$sha" "$replacement_out") >"$work/replacement.stdout" 2>"$work/replacement.stderr" ||
  fail 'staging failed with a local replacement ref'
cmp -s "$out" "$replacement_out" || fail 'replacement ref changed staged manifest'
cmp -s "$out.source-identity" "$replacement_out.source-identity" ||
  fail 'replacement ref changed staged source identity'
git -C "$repo" replace -d "$sha" >/dev/null

# A replacement of one source blob is just as unsafe as a commit replacement.
original_blob=$(git -C "$repo" rev-parse "$sha:README.md")
replacement_blob=$(printf 'blob replacement bytes\n' | git -C "$repo" hash-object -w --stdin)
git -C "$repo" replace "$original_blob" "$replacement_blob"
[ "$(git -C "$repo" cat-file blob "$original_blob")" = 'blob replacement bytes' ] ||
  fail 'blob replacement control did not take effect'
blob_out="$work/retained/blob-safe"
(cd "$repo" && bash "$stage" "$sha" "$blob_out") >"$work/blob.stdout" 2>"$work/blob.stderr" ||
  fail 'staging failed with a blob replacement ref'
cmp -s "$out" "$blob_out" || fail 'blob replacement ref changed staged manifest'
cmp -s "$out.source-identity" "$blob_out.source-identity" ||
  fail 'blob replacement ref changed staged source identity'
git -C "$repo" replace -d "$original_blob" >/dev/null

mkdir "$work/sort-fault-bin" "$work/sort-tree"
printf 'fixture bytes\n' >"$work/sort-tree/item"
printf '%s\n' '#!/bin/sh' "printf './item\\000'" 'exit 9' >"$work/sort-fault-bin/sort"
chmod +x "$work/sort-fault-bin/sort"
if PATH="$work/sort-fault-bin:$PATH" bash "$source_root/scripts/source-archive-manifest.sh" \
    "$work/sort-tree" >"$work/sort-fault.stdout" 2>"$work/sort-fault.stderr"; then
  fail 'failed sort unexpectedly produced a manifest'
fi
[ ! -s "$work/sort-fault.stdout" ] || fail 'failed sort emitted partial manifest bytes'
grep -qx 'source-archive-manifest: sorting paths failed' "$work/sort-fault.stderr" ||
  fail 'failed sort had no diagnostic'

# Command substitution must not trim bytes from link targets, and a hashing
# utility must not escape a file's name into its digest field.
link_seen=0
backslash_seen=0
newline_seen=0
while IFS= read -r -d '' kind && IFS= read -r -d '' mode &&
      IFS= read -r -d '' path && IFS= read -r -d '' value; do
  if [ "$path" = newline-link ]; then
    [ "$kind" = l ] && [ "$mode" = 0 ] && [ "$value" = $'target\n\n' ] ||
      fail 'trailing symlink-target newlines changed'
    link_seen=1
  elif [ "$path" = 'back\slash' ]; then
    [ "$kind" = f ] && [[ "$value" =~ ^[0-9a-f]{64}$ ]] ||
      fail 'backslash filename escaped its digest'
    backslash_seen=1
  elif [ "$path" = $'line\nname' ]; then
    [ "$kind" = f ] && [[ "$value" =~ ^[0-9a-f]{64}$ ]] ||
      fail 'newline filename escaped its digest'
    newline_seen=1
  fi
done <"$out"
[ "$link_seen" -eq 1 ] && [ "$backslash_seen" -eq 1 ] && [ "$newline_seen" -eq 1 ] ||
  fail 'special-name archive records were not inspected'

(cd "$repo" && bash "$stage" "$sha" '-dash-manifest') >"$work/dash.stdout" 2>"$work/dash.stderr" ||
  fail 'relative output beginning with a dash failed'
cmp -s "$out" "$repo/-dash-manifest" || fail 'relative output changed manifest bytes'
cmp -s "$out.source-identity" "$repo/-dash-manifest.source-identity" ||
  fail 'relative output changed sidecar bytes'

expect_failure() {
  label=$1
  candidate=$2
  target=$3
  reason=$4
  if (cd "$repo" && bash "$stage" "$candidate" "$target") >"$work/$label.stdout" 2>"$work/$label.stderr"; then
    fail "$label unexpectedly succeeded"
  fi
  [ ! -s "$work/$label.stdout" ] || fail "$label wrote stdout"
  grep -qx "stage-archive-manifest: $reason" "$work/$label.stderr" ||
    fail "$label did not return its fixed diagnostic"
}

before_manifest="$work/before-manifest"
before_sidecar="$work/before-sidecar"
cp "$out" "$before_manifest"
cp "$out.source-identity" "$before_sidecar"
expect_failure existing_manifest "$sha" "$out" output_exists
cmp -s "$out" "$before_manifest" || fail 'existing manifest was overwritten'
cmp -s "$out.source-identity" "$before_sidecar" || fail 'existing sidecar was overwritten'

sidecar_only="$work/retained/sidecar-only"
printf 'existing sidecar\n' >"$sidecar_only.source-identity"
expect_failure existing_sidecar "$sha" "$sidecar_only" output_exists
[ ! -e "$sidecar_only" ] || fail 'manifest appeared beside an existing sidecar'
[ "$(cat "$sidecar_only.source-identity")" = 'existing sidecar' ] ||
  fail 'existing sidecar changed'

expect_failure malformed_sha not-a-sha "$work/retained/malformed" invalid_sha
[ ! -e "$work/retained/malformed" ] || fail 'malformed SHA created output'
[ ! -e "$work/retained/malformed.source-identity" ] || fail 'malformed SHA created sidecar'
expect_failure missing_parent "$sha" "$work/missing/manifest" output_parent_missing
[ ! -e "$work/missing" ] || fail 'missing parent was created'

printf '#!/usr/bin/env bash\nprintf "partial\\000"\nexit 9\n' >"$repo/scripts/source-archive-manifest.sh"
git -C "$repo" add scripts/source-archive-manifest.sh
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm failing-producer
failing_sha=$(git -C "$repo" rev-parse HEAD)
failed_out="$work/retained/failure"
expect_failure partial_producer "$failing_sha" "$failed_out" manifest_failed
for path in "$failed_out"*; do
  [ ! -e "$path" ] || fail 'partial producer left a published or temporary file'
done

mkdir "$work/fault-bin"
real_ln=$(command -v ln)
printf '%s\n' '#!/usr/bin/env bash' \
  '[ ! -e "$LOOPEX_TEST_LN_MARKER" ] || exit 1' \
  ': >"$LOOPEX_TEST_LN_MARKER"' \
  'exec "$LOOPEX_TEST_REAL_LN" "$@"' >"$work/fault-bin/ln"
chmod +x "$work/fault-bin/ln"
rollback_out="$work/retained/rollback"
if (cd "$repo" &&
    LOOPEX_TEST_LN_MARKER="$work/ln-marker" LOOPEX_TEST_REAL_LN="$real_ln" \
      PATH="$work/fault-bin:$PATH" bash "$stage" "$sha" "$rollback_out") \
    >"$work/rollback.stdout" 2>"$work/rollback.stderr"; then
  fail 'sidecar publication fault unexpectedly succeeded'
fi
grep -qx 'stage-archive-manifest: output_unavailable' "$work/rollback.stderr" ||
  fail 'sidecar publication fault had wrong diagnostic'
for path in "$rollback_out"*; do
  [ ! -e "$path" ] || fail 'sidecar publication fault left a final or temporary file'
done

printf 'stage-archive-manifest-test: PASS\n'
