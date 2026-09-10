#!/usr/bin/env bash
# Concept: this Open scaffold distinguishes artifact inspection, focused opening
# diagnostics and the future full closure role. None supplies closure evidence.
# Technical depth: the behavioral witness uses a real local Store and session;
# unavailable prerequisites and unimplemented future lanes always exit 2.
set -euo pipefail
set +a

die() { printf 'M3 gate UNAVAILABLE: %s\n' "$*" >&2; exit 2; }
role=full
case "${1:-}" in
  '') [ "$#" -eq 0 ] || die 'an empty role argument is invalid' ;;
  --inspect) role=inspect ;;
  --preflight) role=preflight ;;
  --checkpoint) role=checkpoint ;;
  *) die 'the grammar is [--inspect | --preflight | --checkpoint]' ;;
esac
[ "$#" -le 1 ] || die 'the role grammar accepts at most one argument'
[ -z "${LOOPEX_PROVIDER_API_KEY:-}" ] || die 'this Open scaffold has no credential lane'
for command in git awk shasum cut; do
  command -v "$command" >/dev/null 2>&1 || die "required tool is absent: $command"
done
root=$(git rev-parse --show-toplevel 2>/dev/null) || die 'not inside a Git checkout'
cd "$root" || die 'cannot enter the checkout'
for path in docs/plans/M3.md docs/plans/M3-technical.md docs/plans/M3-gate.md docs/plans/README.md; do
  [ -r "$path" ] || die "M3 artifact is unreadable: $path"
done

# Concept: inspection checks the table's actual bytes, including this runner.
# Technical depth: the mutable Open gate is the only digest inventory. Empty,
# malformed and duplicate rows are unavailable evidence, never a product red.
artifacts=$(awk '
  /^## Bound Artifacts$/ { inside = 1; next }
  inside && /^## / { inside = 0 }
  inside && /^\| `/ {
    if (split($0, fields, "`") != 5 || length(fields[2]) != 64 || fields[2] ~ /[^0-9a-f]/ || fields[4] !~ /^[A-Za-z0-9_.\/-]+$/ || fields[4] ~ /(^|\/)\.\.(\/|$)/ || fields[4] ~ /^\// || seen[fields[4]]++) exit 2
    print fields[2] " " fields[4]
    count++
  }
  END { if (!count) exit 2 }
' docs/plans/M3-gate.md) || die 'Bound Artifacts table is empty or malformed'
for required in scripts/check-m3-gate.sh scripts/m3-opening-probe.exs scripts/m1-exunit-runner.exs apps/loopex/test/m1_exunit_runner_test.exs .tool-versions; do
  found=0
  while read -r expected path; do
    [ "$path" != "$required" ] || found=1
  done <<< "$artifacts"
  [ "$found" = 1 ] || die "Bound Artifacts table omits $required"
done
while read -r expected path; do
  [ -r "$path" ] || die "bound artifact is unreadable: $path"
  actual=$(shasum -a 256 "$path" | cut -d' ' -f1) || die "cannot hash $path"
  [ "$actual" = "$expected" ] || die "bound artifact digest mismatch: $path"
done <<< "$artifacts"
if [ "$role" = inspect ]; then
  printf '%s\n' 'M3 inspection OK: scaffold artifact hashes verified; no behavioral or closure evidence'
  exit 0
fi
for command in mix elixir mktemp mkdir rm cat tail; do
  command -v "$command" >/dev/null 2>&1 || die "required tool is absent: $command"
done

task_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P) || die 'cannot resolve temporary directory'
checkout=$(pwd -P)
case "$task_parent" in
  "$checkout"|"$checkout"/*) die 'temporary directory resolves inside the checkout' ;;
esac
task_root=$(mktemp -d "$task_parent/loopex-m3-gate.XXXXXXXX") || die 'cannot allocate isolated task root'
cleanup() { rm -rf "$task_root"; }
trap cleanup EXIT
trap 'exit 2' INT TERM
mkdir -p "$task_root/home" "$task_root/state" || die 'cannot create isolated directories'

# Concept: only protocol, core and the real local Store are compiled, offline.
# Technical depth: clear the higher-precedence build-path override and isolate
# Mix, Hex, build and temporary state. Print failed compiler output before cleanup.
if ! (
  cd apps/loopex_store_local &&
  env -u MIX_BUILD_PATH -u MIX_DEPS_PATH MIX_ENV=prod \
    MIX_BUILD_ROOT="$task_root/build" HOME="$task_root/home" \
    HEX_HOME="$task_root/home/.hex" MIX_HOME="$task_root/home/.mix" \
    HEX_OFFLINE=1 TMPDIR="$task_root" mix compile </dev/null
) >"$task_root/compile.log" 2>&1; then
  cat "$task_root/compile.log" >&2
  die 'isolated core/local-Store compilation failed'
fi
beam_args=()
for app in loopex_protocol loopex loopex_store_local; do
  ebin="$task_root/build/prod/lib/$app/ebin"
  [ -f "$ebin/$app.app" ] || die "isolated build lacks $app"
  beam_args+=(-pa "$ebin")
done
printf 'M3 %s: running the context-admission opening witness only\n' "$role"
result=0
elixir "${beam_args[@]}" scripts/m3-opening-probe.exs "$task_root/state" </dev/null >"$task_root/probe.log" 2>&1 || result=$?
cat "$task_root/probe.log"
case "$result" in
  0) die 'opening witness passed; protected selectors, skill workflow, inherited and closure evidence lanes remain incomplete in this Open scaffold' ;;
  1)
    [ "$(tail -n 1 "$task_root/probe.log")" = 'M3 gate RED: required-only context overflow evaluates optional project content before refusal' ] || die 'probe exited 1 without its completed behavioral witness'
    exit 1 ;;
  *) die 'opening witness could not establish its prerequisites or complete observation' ;;
esac
