#!/usr/bin/env bash
# Concept: opening diagnostics stay cheap; full mode requires every closure lane.
# Technical depth: future selectors must exist and pass when reached. No absent
# fixture, selector, build, credential or authoritative report can produce PASS.
set -euo pipefail
set +a
set +x

die() { printf 'M3 gate UNAVAILABLE: %s\n' "$*" >&2; exit 2; }
lane_finished() { printf 'LOOPEX_M3_LANE name=%s elapsed_seconds=%s exit=%s\n' "$1" "$((SECONDS - $2))" "$3"; }
role=full
comparison=
case "${1:-}" in
  '') [ "$#" -eq 0 ] || die 'an empty role argument is invalid' ;;
  --inspect) role=inspect ;;
  --preflight) role=preflight ;;
  --checkpoint) role=checkpoint; [ "$#" -eq 2 ] || die "checkpoint requires one comparison SHA"; comparison=$2 ;;
  *) die 'the grammar is [--inspect | --preflight | --checkpoint <comparison-SHA>]' ;;
esac
[ "$role" = checkpoint ] || [ "$#" -le 1 ] || die 'the role grammar accepts at most one argument'
[ "${LOOPEX_PROVIDER_API_KEY+x}" != x ] || die 'provider input must use the bounded M3 stdin frame'
unset OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY AZURE_OPENAI_API_KEY
set +x
export LC_ALL=C
operator_home=${HOME:?}
operator_hex_home=${HEX_HOME:-$operator_home/.hex}
operator_mix_home=${MIX_HOME:-$operator_home/.mix}
m3_provider_key=""
export -n m3_provider_key
if ! [ -t 0 ]; then
  frame_header=""
  if [ "$role" = full ]; then
    if IFS= read -r -d '' -n 22 frame_header; then
      [ "$frame_header" = LOOPEX_M3_PROVIDER_V1 ] || die 'malformed provider frame header'
      IFS= read -r -d '' -n 16385 m3_provider_key || die 'unterminated or oversized provider frame'
      [ -n "$m3_provider_key" ] && [ "${#m3_provider_key}" -le 16384 ] || die 'empty or oversized provider frame'
      frame_trailing=""
      if IFS= read -r -d '' -n 1 frame_trailing || [ -n "$frame_trailing" ]; then die 'trailing provider input'; fi
    elif [ -n "$frame_header" ]; then
      die 'unterminated provider frame header'
    fi
  elif IFS= read -r -d '' -n 1 frame_header || [ -n "$frame_header" ]; then
    die 'diagnostic roles accept no provider input'
  fi
fi
for command in git awk shasum cut elixir; do
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
for required in scripts/m3-gate-support.exs scripts/check-closed-gates.sh scripts/m3-outcomes.exs scripts/check-m3-gate.sh scripts/m3-opening-probe.exs scripts/m1-exunit-runner.exs apps/loopex/test/m1_exunit_runner_test.exs .tool-versions; do
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
support() { elixir scripts/m3-gate-support.exs --m3-gate-support "$@"; }
support inspect "$root"
if [ "$role" = checkpoint ]; then
  selected_ids=$(support selection "$root" "$comparison") || exit $?
fi
if [ "$role" = inspect ]; then
  printf '%s\n' 'M3 inspection OK: scaffold artifact hashes verified; no behavioral or closure evidence'
  exit 0
fi
support identity "$root" opening
for command in mix elixir mktemp mkdir rm cat tail; do
  command -v "$command" >/dev/null 2>&1 || die "required tool is absent: $command"
done

task_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P) || die 'cannot resolve temporary directory'
checkout=$(pwd -P)
case "$task_parent" in
  "$checkout"|"$checkout"/*) die 'temporary directory resolves inside the checkout' ;;
esac
for task_protected_root in "${LOOPEX_HOME:-$operator_home/.loopex}" "${LOOPEX_WORKSPACE:-$root}"; do
  if [ -d "$task_protected_root" ]; then
    task_protected_physical=$(cd "$task_protected_root" && pwd -P) || die 'cannot resolve operator state root'
    case "$task_parent" in
      "$task_protected_physical"|"$task_protected_physical"/*) die 'temporary directory resolves inside operator state or workspace' ;;
    esac
  fi
done
task_root=$(mktemp -d "$task_parent/loopex-m3-gate.XXXXXXXX") || die 'cannot allocate isolated task root'
cleanup() { rm -rf "$task_root"; }
trap cleanup EXIT
trap 'exit 2' INT TERM
mkdir -p "$task_root/home" "$task_root/state" || die 'cannot create isolated directories'

# Concept: only protocol, core and the real local Store are compiled, offline.
# Technical depth: clear the higher-precedence build-path override and isolate
# Mix, Hex, build and temporary state. Print failed compiler output before cleanup.
task_compile_started=$SECONDS
if (
  cd apps/loopex_store_local &&
  env -u MIX_BUILD_PATH -u MIX_DEPS_PATH MIX_ENV=prod \
    MIX_BUILD_ROOT="$task_root/build" HOME="$task_root/home" \
    HEX_HOME="$task_root/home/.hex" MIX_HOME="$task_root/home/.mix" \
    HEX_OFFLINE=1 TMPDIR="$task_root" mix compile </dev/null
) >"$task_root/compile.log" 2>&1; then
  lane_finished opening_compile "$task_compile_started" 0
else
  task_compile_result=$?
  lane_finished opening_compile "$task_compile_started" "$task_compile_result"
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
opening_result=0
task_opening_started=$SECONDS
env -u MIX_BUILD_PATH -u MIX_DEPS_PATH MIX_ENV=prod \
  MIX_BUILD_ROOT="$task_root/build" HOME="$task_root/home" \
  HEX_HOME="$task_root/home/.hex" MIX_HOME="$task_root/home/.mix" \
  HEX_OFFLINE=1 TMPDIR="$task_root" \
  elixir "${beam_args[@]}" scripts/m3-opening-probe.exs "$task_root/state" </dev/null >"$task_root/probe.log" 2>&1 || result=$?
cat "$task_root/probe.log"
lane_finished opening "$task_opening_started" "$result"
case "$result" in
  0) ;;
  1)
    [ "$(tail -n 1 "$task_root/probe.log")" = 'M3 gate RED: required-only context overflow evaluates optional project content before refusal' ] || die 'probe exited 1 without its completed behavioral witness'
    if [ "$role" = checkpoint ]; then opening_result=1; else exit 1; fi ;;
  *)
    case "$(tail -n 1 "$task_root/probe.log")" in
      'M3 opening WITNESS ERROR: '*)
        printf '%s\n' 'M3 gate WITNESS ERROR: the opening observation did not establish its named precondition' >&2
        exit 2 ;;
      *) die 'opening witness could not establish its environment or complete observation' ;;
    esac ;;
esac
# Concept: an opening red remains decisive. Once it passes, full and checkpoint
# roles execute their required lanes; missing future selectors fail when reached.
if [ "$role" = preflight ]; then
  printf '%s\n' 'M3 preflight OK: opening only; no closure claim'
  exit 0
fi
if [ "$role" = full ]; then
  full_identity=$(support identity "$root" full) || exit $?
  printf '%s\n' "$full_identity"
  selected_ids=1,2,3,4,5
fi

support prepare-build "$task_root" "$operator_mix_home" "${LOOPEX_HOME:-$operator_home/.loopex}" "${LOOPEX_WORKSPACE:-$root}" || exit $?
if ! elixir -r apps/loopex/lib/mix/tasks/loopex.deps_budget.ex \
  -e 'Loopex.Checks.DepsBudget.main(System.argv())' -- \
  --materialize "$operator_hex_home/packages" "$task_root/deps" "$task_root/protected-file-ids" </dev/null; then
  die 'lock-bound dependency source could not be materialized offline'
fi
mkdir -p "$task_root/workspace" "$task_root/rebar-cache"
isolated() {
  env -u MIX_BUILD_PATH -u MIX_REBAR3 HOME="$task_root/home" TMPDIR="$task_root" \
    HEX_HOME="$task_root/home/.hex" MIX_HOME="$task_root/home/.mix" \
    HEX_OFFLINE=1 MIX_BUILD_ROOT="$task_root/build" MIX_DEPS_PATH="$task_root/deps" \
    LOOPEX_HOME="$task_root/state" LOOPEX_WORKSPACE="$task_root/workspace" \
    REBAR_CACHE_DIR="$task_root/rebar-cache" MIX_ENV=test "$@"
}
run_step() {
  printf 'M3 gate step: %s\n' "$*"
  local result=0
  local task_step_started=$SECONDS
  isolated "$@" </dev/null || result=$?
  lane_finished "$*" "$task_step_started" "$result"
  [ "$result" = 0 ] || { printf 'M3 gate RED: required command failed (exit %s)\n' "$result" >&2; exit "$result"; }
}
# Every selector sees an isolated test build, and all ordinary commands inherit
# the same isolated homes and no provider environment variables.
task_compile_started=$SECONDS
task_compile_result=0
isolated mix compile --warnings-as-errors </dev/null || task_compile_result=$?
lane_finished test_compile "$task_compile_started" "$task_compile_result"
[ "$task_compile_result" = 0 ] || die 'isolated full test compilation failed'
build_identity=$(support build "$task_root/build/test") || exit $?
printf '%s\n' "$build_identity"

run_selector() {
  local selector=$1 kind=$2 result=0 nonce
  local task_selector_started=$SECONDS
  local argv=() value
  support args "$root" "$task_root/build/test" "$selector" > "$task_root/selector-args" || exit $?
  while IFS= read -r -d '' value; do argv+=("$value"); done < "$task_root/selector-args"
  [ "${#argv[@]}" -ge 10 ] || die 'selector argument construction incomplete'
  nonce=$(elixir -e 'IO.write(Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))') || die 'cannot allocate selector nonce'
  printf 'M3 selector: %s kind=%s\n' "$selector" "$kind"
  if [ "$kind" = real ]; then
    [ -n "$m3_provider_key" ] || die 'full gate requires provider input for the real workflow'
    builtin printf 'LOOPEX_M1_SELECTOR_V1\0%s\0%s\0' "$nonce" "$m3_provider_key" |
      isolated elixir scripts/m1-exunit-runner.exs --loopex-m1-selector --only-real-provider --real-path combined "${argv[@]}" > "$task_root/selector.log" 2>&1 || result=$?
  else
    builtin printf 'LOOPEX_M1_SELECTOR_V1\0%s\0\0' "$nonce" |
      isolated elixir scripts/m1-exunit-runner.exs --loopex-m1-selector "${argv[@]}" > "$task_root/selector.log" 2>&1 || result=$?
  fi
  cat "$task_root/selector.log"
  lane_finished "$selector" "$task_selector_started" "$result"
  [ "$result" = 0 ] || { printf 'M3 gate RED: selector failed: %s\n' "$selector" >&2; exit "$result"; }
  support report "$task_root/selector.log" "$nonce" "$selector" "${argv[7]}" "$kind" || exit $?
}
support selectors "$root" "$selected_ids" > "$task_root/selectors" || exit $?
while IFS= read -r selector; do
  [ -z "$selector" ] || run_selector "$selector" deterministic
done < "$task_root/selectors"
if [ "$role" = checkpoint ]; then
  printf 'M3 checkpoint selected outcomes passed: outcomes=%s opening_exit=%s; diagnostic only, not closure evidence\n' "$selected_ids" "$opening_result"
  exit "$opening_result"
fi
run_step mix test --exclude real_provider --seed 3107
run_step mix format --check-formatted
run_step mix loopex.docs_check
run_step mix loopex.deps_budget
run_step bash scripts/check-bootstrap.sh
# Restore the operator's nonsecret package caches for immutable inherited gates;
# their own runners establish their locked isolation and credential boundaries.
result=0
task_inherited_started=$SECONDS
if [ -n "$m3_provider_key" ]; then
  builtin printf 'LOOPEX_M3_PROVIDER_V1\0%s\0' "$m3_provider_key" |
    env -u MIX_BUILD_ROOT -u MIX_ENV HOME="$operator_home" HEX_HOME="$operator_hex_home" MIX_HOME="$operator_mix_home" TMPDIR="$task_parent" \
      bash scripts/check-closed-gates.sh --before M3 > "$task_root/inherited.log" 2>&1 || result=$?
else
  env -u MIX_BUILD_ROOT -u MIX_ENV HOME="$operator_home" HEX_HOME="$operator_hex_home" MIX_HOME="$operator_mix_home" TMPDIR="$task_parent" \
    bash scripts/check-closed-gates.sh --before M3 </dev/null > "$task_root/inherited.log" 2>&1 || result=$?
fi
cat "$task_root/inherited.log"
lane_finished inherited "$task_inherited_started" "$result"
[ "$result" = 0 ] || exit "$result"
[ "$(tail -n 1 "$task_root/inherited.log")" = 'LOOPEX_CLOSED_GATES_REPORT caller=M3 complete=true' ] || die 'inherited gate invocation report missing'
real_selector=$(support real "$root") || exit $?
run_selector "$real_selector" real
final_identity=$(support identity "$root" full) || exit $?
[ "$full_identity" = "$final_identity" ] || die 'source identity changed during the full gate'
[ "$build_identity" = "$(support build "$task_root/build/test")" ] || die 'selector build identity changed during the full gate'
printf '%s\n' "$final_identity"
printf 'LOOPEX_M3_GATE_REPORT source=%s gate=sha256:%s seed=3107 outcome_ids=1,2,3,4,5 inherited=true real_workflow=true result=PASS\n' \
  "$(git rev-parse HEAD)" "$(shasum -a 256 docs/plans/M3-gate.md | cut -d' ' -f1)"
