#!/usr/bin/env bash
# Exercise the floor runner in a tiny committed repository. Tool commands are
# local fixtures; the runner still clones the exact commit and retains logs.
set -euo pipefail

source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/loopex-floor-lane-test.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
fail() { printf 'floor-lane-test: %s\n' "$1" >&2; exit 1; }
assert_retained_identity() {
  local transcript=$1 log=$2 digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$log" | awk '{print $1}')
  else
    digest=$(shasum -a 256 "$log" | awk '{print $1}')
  fi
  grep -Fqx "floor-lane: retained $log sha256=$digest" "$transcript" ||
    fail "retained reference or SHA-256 missing for $log"
}

repo=$work/repo
retained=$work/retained
bin=$work/bin
mkdir -p "$repo/scripts" "$repo/apps/loopex" "$repo/apps/loopex_executor_local" \
  "$repo/apps/loopex_daemon" "$repo/apps/loopex_llm_reqllm/test" "$retained" "$bin"
cp "$source_root/scripts/floor-lane.sh" "$repo/scripts/floor-lane.sh"
cp "$source_root/scripts/suite-summary.sh" "$repo/scripts/suite-summary.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "fixture fast stdout\n"' \
  'printf "fixture fast stderr\n" >&2' \
  'printf "fixture fast native encoding=%s\n" "$(locale charmap)"' \
  'if [[ -n ${FLOOR_TEST_FAST_SLEEP:-} ]]; then' \
  '  sleep "$FLOOR_TEST_FAST_SLEEP" &' \
  '  child=$!' \
  '  printf "CHILD_PID=%s\n" "$child"' \
  '  wait "$child"' \
  'fi' \
  'exit "${FLOOR_TEST_FAST_EXIT:-0}"' >"$repo/scripts/check.sh"
for app in loopex loopex_executor_local loopex_daemon; do
  printf 'fixture app\n' >"$repo/apps/$app/.fixture"
done
printf 'one selected case lives here\n' >"$repo/apps/loopex_llm_reqllm/test/in_process_transport_drain_test.exs"
git -C "$repo" init -q
git -C "$repo" add .
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
sha=$(git -C "$repo" rev-parse HEAD)
runner=$repo/scripts/floor-lane.sh
printf 'this dirty line must not run\n' >>"$repo/scripts/check.sh"

# A fixture pair makes the command selection observable without downloading
# toolchains or running the full project suite. The production runner has no
# test-mode branch.
printf '%s\n' '#!/usr/bin/env bash' \
  '[[ ${1:-} == exec ]] || exit 17' \
  '[[ ${2:-} == erlang@27.3.4 && ${3:-} == elixir@1.18.5-otp-27 && ${4:-} == -- ]] || exit 20' \
  '[[ -z ${FLOOR_TEST_MISE_FAIL:-} ]] || exit 18' \
  'shift' \
  'while [[ ${1:-} != -- ]]; do shift; done' \
  'shift' \
  'if [[ ${1:-} == elixir ]]; then printf "%s\n" "${FLOOR_TEST_VERSION:-1.18.5:27}"; exit 0; fi' \
  'exec "$@"' >"$bin/mise"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  deps.get) printf "fixture deps fetched\n"; exit "${FLOOR_TEST_DEPS_EXIT:-0}" ;;' \
  '  test)' \
  '    printf "fixture test cwd=%s args=%s\n" "$(basename "$PWD")" "$*"' \
  '    if [[ $PWD == */loopex_llm_reqllm ]]; then' \
  '      count=${FLOOR_TEST_REQ_COUNT:-1}' \
  '    else' \
  '      count=1' \
  '    fi' \
  '    printf "%s tests, 0 failures\n" "$count"' \
  '    exit "${FLOOR_TEST_LONG_EXIT:-0}" ;;' \
  '  *) exit 19 ;;' \
  'esac' >"$bin/mix"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [[ ${1:-} == -s && -n ${FLOOR_TEST_PLATFORM:-} ]]; then' \
  '  printf "%s\n" "$FLOOR_TEST_PLATFORM"' \
  'else' \
  '  exec /usr/bin/uname "$@"' \
  'fi' >"$bin/uname"
chmod +x "$bin/mise" "$bin/mix" "$bin/uname"

expect_preflight_failure() {
  local label=$1 target=$2
  shift 2
  if PATH="$bin:$PATH" "$@" >"$work/$label.stdout" 2>"$work/$label.stderr"; then
    fail "$label unexpectedly passed"
  fi
  [[ ! -e $target && ! -L $target ]] || fail "$label created its output directory"
  [[ ! -e $target-source && ! -L $target-source ]] || fail "$label created a clone"
  [[ ! -e $target-M6-otp27-build && ! -L $target-M6-otp27-build ]] ||
    fail "$label created a build root"
}

expect_preflight_failure missing_args "$retained/missing-args" bash "$runner" "$sha"
expect_preflight_failure malformed_sha "$retained/malformed-sha" \
  bash "$runner" not-a-sha --output-dir "$retained/malformed-sha"
expect_preflight_failure unknown_sha "$retained/unknown-sha" \
  bash "$runner" 0000000000000000000000000000000000000000 --output-dir "$retained/unknown-sha"
expect_preflight_failure missing_flag "$retained/missing-flag" \
  bash "$runner" "$sha" "$retained/missing-flag" --long-bound
expect_preflight_failure wrong_flag "$retained/wrong-flag" \
  bash "$runner" "$sha" --output-dir "$retained/wrong-flag" --unknown
expect_preflight_failure missing_parent "$work/missing/output" \
  bash "$runner" "$sha" --output-dir "$work/missing/output"
[[ ! -e $work/missing ]] || fail 'missing-parent preflight created its parent'
expect_preflight_failure wrong_version "$retained/wrong-version" \
  env FLOOR_TEST_VERSION=1.19.0:27 bash "$runner" "$sha" --output-dir "$retained/wrong-version"
expect_preflight_failure unsupported_platform "$retained/unsupported-platform" \
  env FLOOR_TEST_PLATFORM=Solaris bash "$runner" "$sha" --output-dir "$retained/unsupported-platform"
expect_preflight_failure low_nofile "$retained/low-nofile" \
  bash -c 'ulimit -Sn 2048 && ulimit -Hn 2048 && exec bash "$1" "$2" --output-dir "$3"' \
    _ "$runner" "$sha" "$retained/low-nofile"
grep -q 'at least 4096 open files' "$work/low_nofile.stderr" ||
  fail 'low open-file limit did not receive a refusal'
expect_preflight_failure ignored_hup "$retained/ignored-hup" \
  bash -c 'trap "" HUP; exec bash "$1" "$2" --output-dir "$3"' \
    _ "$runner" "$sha" "$retained/ignored-hup"
grep -q 'SIGHUP is ignored' "$work/ignored_hup.stderr" ||
  fail 'ignored SIGHUP did not receive a refusal'

for platform in Darwin Linux; do
  case "$platform" in
    Darwin) out=$retained/darwin ;;
    Linux) out=$retained/linux ;;
  esac
  if [[ $platform == Linux ]]; then
    PATH="$bin:$PATH" LC_ALL=C LANG=C FLOOR_TEST_PLATFORM=$platform \
      bash "$runner" "$sha" --output-dir "$out" --long-bound \
      >"$work/$platform.stdout" 2>"$work/$platform.stderr" ||
      fail "$platform fixture run failed"
  else
    PATH="$bin:$PATH" LC_ALL=C LANG=C FLOOR_TEST_PLATFORM=$platform \
      bash "$runner" "$sha" --output-dir "$out" \
      >"$work/$platform.stdout" 2>"$work/$platform.stderr" ||
      fail "$platform fixture run failed"
  fi
  [[ -d $out && -d $out-source && -d $out-M6-otp27-build ]] ||
    fail "$platform did not make all three sibling directories"
  case "$(uname -s)" in
    Darwin) mode=$(stat -f %Lp "$out") ;;
    Linux) mode=$(stat -c %a "$out") ;;
    *) fail 'unsupported fixture host' ;;
  esac
  [[ $mode == 700 ]] || fail "$platform output directory mode is $mode, not 700"
  grep -qx "SHA=$sha" "$out/check.log" || fail "$platform SHA was not retained"
  grep -qx "PLATFORM=$platform" "$out/check.log" || fail "$platform platform was not retained"
  grep -qx 'NATIVE_ENCODING=UTF-8' "$out/check.log" ||
    fail "$platform did not retain the selected native encoding"
  grep -qx 'RUN=fast-check' "$out/check.log" || fail "$platform fast command was not run"
  grep -qx 'fixture fast stdout' "$out/check.log" || fail "$platform lost stdout"
  grep -qx 'fixture fast stderr' "$out/check.log" || fail "$platform lost stderr"
  grep -qx 'fixture fast native encoding=UTF-8' "$out/check.log" ||
    fail "$platform did not select UTF-8 from a POSIX login locale"
  ! grep -q 'this dirty line must not run' "$out/check.log" ||
    fail "$platform used the working tree instead of the commit"
  grep -q '^DURATION_S=[0-9][0-9]*$' "$out/check.log" || fail "$platform lost duration"
  grep -q '^EXIT=0$' "$out/check.log" || fail "$platform lost exit status"
  assert_retained_identity "$work/$platform.stdout" "$out/check.log"
done
[[ ! -e $retained/darwin/long-bound.log ]] || fail 'long bounds ran without selection'
for app in loopex loopex_executor_local loopex_daemon; do
  grep -qx "RUN=long-bound-$app" "$retained/linux/long-bound.log" ||
    fail "$app long bound was not selected"
  grep -q '^EXECUTED_CASES=1$' "$retained/linux/long-bound-$app.log" ||
    fail "$app executed count was not retained"
done
grep -q 'test/in_process_transport_drain_test.exs --only long_bound' \
  "$retained/linux/long-bound-loopex_llm_reqllm.log" ||
  fail 'the single transport-drain file was not selected'
grep -qx 'EXECUTED_CASES=1' "$retained/linux/long-bound-loopex_llm_reqllm.log" ||
  fail 'transport-drain exact count was not retained'
assert_retained_identity "$work/Linux.stdout" "$retained/linux/long-bound.log"
assert_retained_identity "$work/Linux.stdout" "$retained/linux/long-bound-loopex_llm_reqllm.log"

# A second call cannot replace any retained byte or reuse the clone/build root.
cp "$retained/linux/check.log" "$work/check-before"
if PATH="$bin:$PATH" bash "$runner" "$sha" --output-dir "$retained/linux" \
    >"$work/no-overwrite.stdout" 2>"$work/no-overwrite.stderr"; then
  fail 'existing output unexpectedly passed'
fi
cmp -s "$work/check-before" "$retained/linux/check.log" || fail 'existing log was overwritten'

printf 'reserved clone\n' >"$retained/collision-source"
if PATH="$bin:$PATH" bash "$runner" "$sha" --output-dir "$retained/collision" \
    >"$work/collision.stdout" 2>"$work/collision.stderr"; then
  fail 'existing clone sibling unexpectedly passed'
fi
[[ ! -e $retained/collision ]] || fail 'clone collision created output'
[[ $(cat "$retained/collision-source") == 'reserved clone' ]] ||
  fail 'clone collision overwrote the existing file'

deps_failure=$retained/failed-deps
if PATH="$bin:$PATH" FLOOR_TEST_DEPS_EXIT=6 \
    bash "$runner" "$sha" --output-dir "$deps_failure" \
    >"$work/failed-deps.stdout" 2>"$work/failed-deps.stderr"; then
  fail 'failing dependency fetch unexpectedly passed'
fi
grep -qx 'fixture deps fetched' "$deps_failure/check.log" || fail 'dependency failure lost output'
grep -qx 'EXIT=6' "$deps_failure/check.log" || fail 'dependency failure lost exact exit status'
assert_retained_identity "$work/failed-deps.stdout" "$deps_failure/check.log"

failure=$retained/failed-fast
if PATH="$bin:$PATH" FLOOR_TEST_FAST_EXIT=7 \
    bash "$runner" "$sha" --output-dir "$failure" \
    >"$work/failed-fast.stdout" 2>"$work/failed-fast.stderr"; then
  fail 'failing fast check unexpectedly passed'
fi
grep -qx 'fixture fast stdout' "$failure/check.log" || fail 'failed run lost stdout'
grep -qx 'fixture fast stderr' "$failure/check.log" || fail 'failed run lost stderr'
grep -qx 'EXIT=7' "$failure/check.log" || fail 'failed run lost exact exit status'
grep -q '^DURATION_S=[0-9][0-9]*$' "$failure/check.log" || fail 'failed run lost duration'
assert_retained_identity "$work/failed-fast.stdout" "$failure/check.log"

interrupted=$retained/interrupted
PATH="$bin:$PATH" FLOOR_TEST_FAST_SLEEP=3 \
  bash "$runner" "$sha" --output-dir "$interrupted" \
  >"$work/interrupted.stdout" 2>"$work/interrupted.stderr" &
runner_pid=$!
seen_child=0
for ((attempt = 0; attempt < 100; attempt++)); do
  if [[ -f $interrupted/check.log ]] && grep -q '^CHILD_PID=' "$interrupted/check.log"; then
    seen_child=1
    break
  fi
  sleep 0.05
done
[[ $seen_child -eq 1 ]] || fail 'signal fixture never reached the running check'
child_pid=$(sed -n 's/^CHILD_PID=//p' "$interrupted/check.log" | tail -n 1)
kill -TERM "$runner_pid" || fail 'could not signal the running floor runner'
set +e
wait "$runner_pid"
signal_status=$?
set -e
[[ $signal_status -eq 143 ]] || fail "signalled runner exited $signal_status, expected 143"
grep -qx 'EXIT=143' "$interrupted/check.log" || fail 'signal exit was not retained'
grep -qx 'TOTAL_EXIT=143' "$interrupted/check.log" || fail 'total signal exit was not retained'
assert_retained_identity "$work/interrupted.stdout" "$interrupted/check.log"
for ((attempt = 0; attempt < 20; attempt++)); do
  kill -0 "$child_pid" 2>/dev/null || break
  sleep 0.05
done
! kill -0 "$child_pid" 2>/dev/null || fail 'signalled check left its sleep child alive'

long_failure=$retained/failed-long
if PATH="$bin:$PATH" FLOOR_TEST_LONG_EXIT=8 \
    bash "$runner" "$sha" --output-dir "$long_failure" --long-bound \
    >"$work/failed-long.stdout" 2>"$work/failed-long.stderr"; then
  fail 'failing long-bound command unexpectedly passed'
fi
grep -qx 'EXIT=8' "$long_failure/long-bound.log" || fail 'long-bound failure lost exact exit status'
grep -q '^DURATION_S=[0-9][0-9]*$' "$long_failure/long-bound.log" ||
  fail 'long-bound failure lost duration'
assert_retained_identity "$work/failed-long.stdout" "$long_failure/long-bound.log"

no_count=$retained/no-count
if PATH="$bin:$PATH" FLOOR_TEST_REQ_COUNT=0 \
    bash "$runner" "$sha" --output-dir "$no_count" --long-bound \
    >"$work/no-count.stdout" 2>"$work/no-count.stderr"; then
  fail 'transport-drain summary parser refusal unexpectedly passed'
fi
grep -qx 'SUMMARY_EXIT=1' "$no_count/long-bound-loopex_llm_reqllm.log" ||
  fail 'summary parser failure status was not retained'
grep -qx 'EXECUTED_CASES=unavailable' "$no_count/long-bound-loopex_llm_reqllm.log" ||
  fail 'unavailable executed count was not retained'
assert_retained_identity "$work/no-count.stdout" "$no_count/long-bound-loopex_llm_reqllm.log"

too_many=$retained/too-many
if PATH="$bin:$PATH" FLOOR_TEST_REQ_COUNT=2 \
    bash "$runner" "$sha" --output-dir "$too_many" --long-bound \
    >"$work/too-many.stdout" 2>"$work/too-many.stderr"; then
  fail 'two transport-drain cases unexpectedly passed'
fi
grep -qx 'EXECUTED_CASES=2' "$too_many/long-bound-loopex_llm_reqllm.log" ||
  fail 'bad exact count was not retained'

printf 'floor-lane-test: PASS\n'
