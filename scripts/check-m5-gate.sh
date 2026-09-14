#!/usr/bin/env bash
# Concept: opening diagnostics stay cheap; full mode requires every closure lane.
# Technical depth: future selectors must exist and pass when reached. No absent
# fixture, selector, build, credential or authoritative report can produce PASS.
# The inherited lane is register-derived, so while M4 is not Closed it reports
# UNAVAILABLE rather than pretending the M5 closure base exists.
set -euo pipefail
set +a
set +x

die() { printf 'M5 gate UNAVAILABLE: %s\n' "$*" >&2; exit 2; }
lane_finished() { printf 'LOOPEX_M5_LANE name=%s elapsed_seconds=%s exit=%s\n' "$1" "$((SECONDS - $2))" "$3"; }
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
[ "${LOOPEX_PROVIDER_API_KEY+x}" != x ] || die 'provider input must use the bounded M5 stdin frame'
unset OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY AZURE_OPENAI_API_KEY
set +x
export LC_ALL=C
operator_home=${HOME:?}
operator_hex_home=${HEX_HOME:-$operator_home/.hex}
operator_mix_home=${MIX_HOME:-$operator_home/.mix}
m5_provider_key=""
export -n m5_provider_key
if ! [ -t 0 ]; then
  frame_header=""
  if [ "$role" = full ]; then
    if IFS= read -r -d '' -n 22 frame_header; then
      [ "$frame_header" = LOOPEX_M5_PROVIDER_V1 ] || die 'malformed provider frame header'
      IFS= read -r -d '' -n 16385 m5_provider_key || die 'unterminated or oversized provider frame'
      [ -n "$m5_provider_key" ] && [ "${#m5_provider_key}" -le 16384 ] || die 'empty or oversized provider frame'
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
for path in docs/plans/M5.md docs/plans/M5-technical.md docs/plans/M5-gate.md docs/plans/README.md; do
  [ -r "$path" ] || die "M5 artifact is unreadable: $path"
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
' docs/plans/M5-gate.md) || die 'Bound Artifacts table is empty or malformed'
for required in scripts/m5-gate-support.exs scripts/m3-gate-support.exs scripts/check-closed-gates.sh scripts/m5-outcomes.exs scripts/check-m5-gate.sh scripts/m5-opening-probe.exs scripts/m1-exunit-runner.exs apps/loopex/test/m1_exunit_runner_test.exs .tool-versions; do
  printf '%s\n' "$artifacts" |
    awk -v required="$required" '$2 == required { found = 1 } END { exit(found ? 0 : 1) }' ||
    die "Bound Artifacts table omits $required"
done
printf '%s\n' "$artifacts" | while read -r expected path; do
  [ -r "$path" ] || die "bound artifact is unreadable: $path"
  actual=$(shasum -a 256 "$path" | cut -d' ' -f1) || die "cannot hash $path"
  [ "$actual" = "$expected" ] || die "bound artifact digest mismatch: $path"
done
support() { env LANG=C.UTF-8 LC_ALL=C.UTF-8 elixir scripts/m5-gate-support.exs --m5-gate-support "$@"; }
support inspect "$root"
if [ "$role" = inspect ]; then
  printf '%s\n' 'M5 inspection OK: scaffold artifact hashes verified; no behavioral or closure evidence'
  exit 0
fi
if [ "$role" = checkpoint ]; then
  selected_ids=$(support selection "$root" "$comparison") || exit $?
  source_identity=$(support identity "$root" working) || exit $?
else
  source_identity=$(support identity "$root" committed) || exit $?
fi
printf '%s\n' "$source_identity"
for command in mix elixir mktemp mkdir rm cat tail tar; do
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
task_root=$(mktemp -d "$task_parent/loopex-m5-gate.XXXXXXXX") || die 'cannot allocate isolated task root'
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
  env -u MIX_BUILD_PATH -u MIX_DEPS_PATH LANG=C.UTF-8 LC_ALL=C.UTF-8 MIX_ENV=prod \
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
printf 'M5 %s: running the cross-process attachment opening witness only\n' "$role"
result=0
opening_result=0
task_opening_started=$SECONDS
env -u MIX_BUILD_PATH -u MIX_DEPS_PATH LANG=C.UTF-8 LC_ALL=C.UTF-8 MIX_ENV=prod \
  MIX_BUILD_ROOT="$task_root/build" HOME="$task_root/home" \
  HEX_HOME="$task_root/home/.hex" MIX_HOME="$task_root/home/.mix" \
  HEX_OFFLINE=1 TMPDIR="$task_root" \
  elixir "${beam_args[@]}" scripts/m5-opening-probe.exs "$task_root/state" </dev/null >"$task_root/probe.log" 2>&1 || result=$?
cat "$task_root/probe.log"
lane_finished opening "$task_opening_started" "$result"
case "$result" in
  0)
    [ "$(tail -n 1 "$task_root/probe.log")" = 'M5 opening GREEN: a second process attaches to the live session through the daemon socket while the store stays single-writer' ] || die 'probe exited 0 without its completed behavioral witness' ;;
  1)
    [ "$(tail -n 1 "$task_root/probe.log")" = 'M5 gate RED: a second process cannot attach to a live session; the local Store refuses the path as store_writer_active and no daemon socket exists' ] || die 'probe exited 1 without its completed behavioral witness'
    if [ "$role" = checkpoint ]; then opening_result=1; else exit 1; fi ;;
  *)
    case "$(tail -n 1 "$task_root/probe.log")" in
      'M5 opening WITNESS ERROR: '*)
        printf '%s\n' 'M5 gate WITNESS ERROR: the opening observation did not establish its named precondition' >&2
        exit 2 ;;
      *) die 'opening witness could not establish its environment or complete observation' ;;
    esac ;;
esac
# Concept: an opening red remains decisive. Once it passes, full and checkpoint
# roles execute their required lanes; missing future selectors fail when reached.
if [ "$role" = preflight ]; then
  printf '%s\n' 'M5 preflight OK: opening only; no closure claim'
  exit 0
fi
if [ "$role" = full ]; then
  [ -n "$m5_provider_key" ] || die 'full gate requires provider input for the real workflow'
  full_identity=$source_identity
  selected_ids=1,2,3,4,5,6
fi

if [ "$role" = checkpoint ] && [ -z "$selected_ids" ]; then
  final_identity=$(support identity "$root" working) || exit $?
  [ "$source_identity" = "$final_identity" ] || die 'source identity changed during the checkpoint'
  printf 'M5 checkpoint no outcomes selected: comparison=%s opening_exit=%s; diagnostic only, not closure evidence\n' "$comparison" "$opening_result"
  exit "$opening_result"
fi

# Concept: client lanes run only under the pinned interpreters the gate binds.
# Technical depth: outcome 6 executes external clients, so their pins are
# verified before any selector for them runs; an absent or different interpreter
# is unavailable evidence, never a product red. The pin file names exact
# `node=` and `python=` versions.
client_pins=scripts/fixtures/m5/client-toolchain.txt
pinned_node=""
pinned_python=""
require_client_pins() {
  [ -r "$client_pins" ] || die "client toolchain pins are absent: $client_pins"
  pinned_node=$(awk -F= '$1 == "node" { print $2 }' "$client_pins")
  pinned_python=$(awk -F= '$1 == "python" { print $2 }' "$client_pins")
  [ -n "$pinned_node" ] && [ -n "$pinned_python" ] || die 'client toolchain pins are incomplete'
  observed_node=$(node --version 2>/dev/null </dev/null) || die 'pinned Node interpreter is unavailable'
  observed_python=$(python3 --version 2>/dev/null </dev/null | cut -d' ' -f2) || die 'pinned Python interpreter is unavailable'
  [ "$observed_node" = "v$pinned_node" ] || die "Node version differs from the pin: $observed_node"
  [ "$observed_python" = "$pinned_python" ] || die "Python version differs from the pin: $observed_python"
}

support prepare-build "$task_root" "$operator_mix_home" "${LOOPEX_HOME:-$operator_home/.loopex}" "${LOOPEX_WORKSPACE:-$root}" || exit $?
if ! env LANG=C.UTF-8 LC_ALL=C.UTF-8 elixir -r apps/loopex/lib/mix/tasks/loopex.deps_budget.ex \
  -e 'Loopex.Checks.DepsBudget.main(System.argv())' -- \
  --materialize "$operator_hex_home/packages" "$task_root/deps" "$task_root/protected-file-ids" </dev/null; then
  die 'lock-bound dependency source could not be materialized offline'
fi
mkdir -p "$task_root/workspace" "$task_root/rebar-cache"
isolated() {
  env -u MIX_BUILD_PATH -u MIX_REBAR3 LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    HOME="$task_root/home" TMPDIR="$task_root" \
    HEX_HOME="$task_root/home/.hex" MIX_HOME="$task_root/home/.mix" \
    HEX_OFFLINE=1 MIX_BUILD_ROOT="$task_root/build" MIX_DEPS_PATH="$task_root/deps" \
    LOOPEX_HOME="$task_root/state" LOOPEX_WORKSPACE="$task_root/workspace" \
    REBAR_CACHE_DIR="$task_root/rebar-cache" MIX_ENV=test "$@"
}
run_step() {
  printf 'M5 gate step: %s\n' "$*"
  local result=0
  local task_step_started=$SECONDS
  isolated "$@" </dev/null || result=$?
  lane_finished "$*" "$task_step_started" "$result"
  [ "$result" = 0 ] || { printf 'M5 gate RED: required command failed (exit %s)\n' "$result" >&2; exit "$result"; }
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
  support args "$root" "$task_root/build/test" "$selector" </dev/null > "$task_root/selector-args" || exit $?
  while IFS= read -r -d '' value; do argv+=("$value"); done < "$task_root/selector-args"
  [ "${#argv[@]}" -ge 10 ] || die 'selector argument construction incomplete'
  nonce=$(env LANG=C.UTF-8 LC_ALL=C.UTF-8 elixir -e 'IO.write(Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))' </dev/null) || die 'cannot allocate selector nonce'
  printf 'M5 selector: %s kind=%s\n' "$selector" "$kind"
  # Client-backed selectors run only under the pinned interpreters.
  case "$selector" in
    */multi_client_workflow_test.exs|*/multi_client_workflow_real_test.exs) require_client_pins ;;
  esac
  if [ "$kind" = real ]; then
    [ -n "$m5_provider_key" ] || die 'full gate requires provider input for the real workflow'
    # The real selector and its compiled applications come from the staged
    # archive, not from the checkout that supplied the deterministic lanes.
    argv[0]=$source_root
    argv[1]=$source_build/test
    builtin printf 'LOOPEX_M1_SELECTOR_V1\0%s\0%s\0' "$nonce" "$m5_provider_key" |
      isolated env MIX_BUILD_ROOT="$source_build" GIT_DIR="$source_git_dir" GIT_WORK_TREE="$source_root" LOOPEX_M5_SOURCE_ROOT="$source_root" \
        elixir "$source_root/scripts/m1-exunit-runner.exs" --loopex-m1-selector --only-real-provider --real-path combined "${argv[@]}" > "$task_root/selector.log" 2>&1 || result=$?
  else
    builtin printf 'LOOPEX_M1_SELECTOR_V1\0%s\0\0' "$nonce" |
      isolated elixir scripts/m1-exunit-runner.exs --loopex-m1-selector "${argv[@]}" > "$task_root/selector.log" 2>&1 || result=$?
  fi
  cat "$task_root/selector.log"
  lane_finished "$selector" "$task_selector_started" "$result"
  [ "$result" = 0 ] || { printf 'M5 gate RED: selector failed: %s\n' "$selector" >&2; exit "$result"; }
  support report "$root" "$task_root/selector.log" "$nonce" "$selector" "${argv[7]}" "$kind" </dev/null || exit $?
  printf '%s\n' "$selector" >> "$task_root/selector-ledger"
}
support selectors "$root" "$selected_ids" > "$task_root/selectors" || exit $?
: > "$task_root/selector-ledger"
while IFS= read -r selector; do
  [ -z "$selector" ] || run_selector "$selector" deterministic
done < "$task_root/selectors"
support selector-account "$task_root/selectors" "$task_root/selector-ledger" </dev/null || exit $?
if [ "$role" = checkpoint ]; then
  final_identity=$(support identity "$root" working) || exit $?
  [ "$source_identity" = "$final_identity" ] || die 'source identity changed during the checkpoint'
  printf 'M5 checkpoint selected outcomes passed: outcomes=%s opening_exit=%s; diagnostic only, not closure evidence\n' "$selected_ids" "$opening_result"
  exit "$opening_result"
fi
run_step mix test --exclude real_provider --seed 3107
run_step mix format --check-formatted
run_step mix loopex.docs_check
run_step mix loopex.deps_budget
: > "$task_root/bootstrap-backedge-ledger"
exec 9>"$task_root/bootstrap-backedge-ledger"
run_step env LOOPEX_M3_BOOTSTRAP_ACTIVE=1 LOOPEX_M3_BOOTSTRAP_SENTINEL_FD=9 \
  bash scripts/check-bootstrap.sh
exec 9>&-
[ ! -s "$task_root/bootstrap-backedge-ledger" ] || die 'bootstrap invoked the closed-gate aggregate'
# Restore the operator's nonsecret package caches for immutable inherited gates;
# their own runners establish their locked isolation and credential boundaries.
# The aggregate's declared input frame is the M3-bound `LOOPEX_M3_PROVIDER_V1`;
# M5 forwards the same unexported value through that existing contract.
result=0
task_inherited_started=$SECONDS
if [ -n "$m5_provider_key" ]; then
  builtin printf 'LOOPEX_M3_PROVIDER_V1\0%s\0' "$m5_provider_key" |
    env -u MIX_BUILD_ROOT -u MIX_ENV HOME="$operator_home" HEX_HOME="$operator_hex_home" MIX_HOME="$operator_mix_home" TMPDIR="$task_parent" \
      bash scripts/check-closed-gates.sh --before M5 > "$task_root/inherited.log" 2>&1 || result=$?
else
  env -u MIX_BUILD_ROOT -u MIX_ENV HOME="$operator_home" HEX_HOME="$operator_hex_home" MIX_HOME="$operator_mix_home" TMPDIR="$task_parent" \
    bash scripts/check-closed-gates.sh --before M5 </dev/null > "$task_root/inherited.log" 2>&1 || result=$?
fi
cat "$task_root/inherited.log"
lane_finished inherited "$task_inherited_started" "$result"
[ "$result" = 0 ] || exit "$result"
[ "$(tail -n 1 "$task_root/inherited.log")" = 'LOOPEX_CLOSED_GATES_REPORT caller=M5 complete=true' ] || die 'inherited gate invocation report missing'
require_client_pins
# Concept: prove the operator can build and use source bytes from one exact
# archive. The later release tag is a separate, post-closure act.
# Technical depth: bind the archive's commit, tree, lockfile and actual tar
# digest in the retained report, then execute the attended selector from the
# fresh extraction with an isolated build and the original tracked index.
source_commit=$(git rev-parse HEAD) || die 'source commit is unavailable'
source_tree=$(git rev-parse 'HEAD^{tree}') || die 'source tree is unavailable'
source_git_dir=$(git rev-parse --absolute-git-dir) || die 'Git index is unavailable for the extracted selector'
source_archive=$task_root/m5-candidate.tar
source_root=$task_root/source-extract
source_build=$task_root/source-build
source_started=$SECONDS
mkdir -p "$source_root" || die 'cannot allocate source extraction'
git archive --format=tar --output="$source_archive" "$source_commit" || die 'cannot stage the source archive'
source_archive_digest=$(shasum -a 256 "$source_archive" | cut -d' ' -f1) || die 'cannot hash the source archive'
tar -xf "$source_archive" -C "$source_root" || die 'cannot extract the source archive'
[ -r "$source_root/VERSION" ] && [ -r "$source_root/mix.lock" ] &&
  [ -r "$source_root/docs/operator/daemon.md" ] || die 'source archive lacks the version, lockfile or operator guide'
source_lock_digest=$(shasum -a 256 "$source_root/mix.lock" | cut -d' ' -f1) || die 'cannot hash the extracted lockfile'
[ "$source_lock_digest" = "$(shasum -a 256 mix.lock | cut -d' ' -f1)" ] || die 'source archive lockfile differs from the candidate'
[ "$(tr -d '[:space:]' < "$source_root/VERSION")" = "$(tr -d '[:space:]' < VERSION)" ] || die 'source archive VERSION differs from the candidate'
(
  cd "$source_root" &&
  isolated env MIX_BUILD_ROOT="$source_build" mix compile --warnings-as-errors </dev/null
) > "$task_root/source-compile.log" 2>&1 || {
  cat "$task_root/source-compile.log" >&2
  die 'fresh-source isolated compilation failed'
}
lane_finished source_archive_build "$source_started" 0
source_build_identity=$(support build "$source_build/test") || exit $?
source_build_digest=${source_build_identity#LOOPEX_M5_BUILD digest=sha256:}
[ "${#source_build_digest}" -eq 64 ] || die 'fresh-source build digest is malformed'
real_selector=$(support real "$root") || exit $?
printf '%s\n' "$real_selector" >> "$task_root/selectors"
run_selector "$real_selector" real
env GIT_DIR="$source_git_dir" GIT_WORK_TREE="$source_root" git -C "$source_root" diff --quiet --exit-code HEAD -- . ||
  die 'the attended workflow changed tracked extracted source bytes'
[ "$source_build_identity" = "$(support build "$source_build/test")" ] || die 'fresh-source build identity changed during the attended workflow'
support selector-account "$task_root/selectors" "$task_root/selector-ledger" </dev/null || exit $?
final_identity=$(support identity "$root" committed) || exit $?
[ "$full_identity" = "$final_identity" ] || die 'source identity changed during the full gate'
[ "$build_identity" = "$(support build "$task_root/build/test")" ] || die 'selector build identity changed during the full gate'
printf '%s\n' "$final_identity"
# Concept: the retained report is validated against its grammar before it is
# printed, so a missing identity can never be retained as evidence.
source_version=$(tr -d '[:space:]' < VERSION) || die 'source VERSION is unreadable'
toolchain=$(printf '%s\n' "$final_identity" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(elixir|otp|erts|platform)=/) printf "%s ", $i }')
[ -n "$toolchain" ] || die 'toolchain identity is missing from the source identity line'
schema_path=apps/loopex_protocol/priv/schema/loopex-experimental-1.json
[ -r "$schema_path" ] || die "canonical schema bytes are absent: $schema_path"
schema_digest=$(shasum -a 256 "$schema_path" | cut -d' ' -f1) || die 'cannot hash the canonical schema'
selector_count=$(grep -c . "$task_root/selector-ledger") || die 'selector ledger is empty'
clients_digest=$(shasum -a 256 "$client_pins" | cut -d' ' -f1) || die 'cannot hash the client toolchain pins'
report=$(printf 'LOOPEX_M5_GATE_REPORT source=%s tree=%s archive=sha256:%s archive_build=sha256:%s lock=sha256:%s gate=sha256:%s version=%s role=full seed=3107 outcome_ids=1,2,3,4,5,6 selectors=%s elapsed_seconds=%s %snode=%s python=%s clients=sha256:%s schema=sha256:%s inherited=true fresh_source=true real_workflow=true result=PASS' \
  "$source_commit" "$source_tree" "$source_archive_digest" "$source_build_digest" "$source_lock_digest" "$(shasum -a 256 docs/plans/M5-gate.md | cut -d' ' -f1)" "$source_version" "$selector_count" "$SECONDS" "$toolchain" "$pinned_node" "$pinned_python" "$clients_digest" "$schema_digest")
support evidence "$report" </dev/null || exit $?
printf '%s\n' "$report"
