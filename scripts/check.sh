#!/usr/bin/env bash
# The fast check: everything a push must pass, credential-free, in minutes.
# Each step prints its name when it starts and its elapsed seconds when it
# ends; output streams as it happens. Stops at the first failing step.
#
# The test suite runs one application per VM, several at once, heaviest first,
# so the wall-clock time is the longest application rather than the sum. Set
# LOOPEX_CHECK_JOBS to bound the concurrency; the default is half the cores.
# While the suite runs, a line every 30 seconds names what is still running.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# --docs: a documentation-only change runs compilation, formatting, the
# structure checks and the documentation check, and skips the test build and
# the suite.
mode=${1:-full}
case "$mode" in
  full | --docs) ;;
  *) echo 'check: usage: check.sh [--docs]' >&2; exit 2 ;;
esac

started=$SECONDS
step() {
  local name=$1 step_started=$SECONDS
  shift
  printf 'check: %s\n' "$name"
  "$@"
  printf 'check: done %s step=%ss total=%ss\n' "$name" "$((SECONDS - step_started))" "$((SECONDS - started))"
}

# One application's suite, against the test build the step above produced.
# Its output is kept in a log and printed only when it fails, so ten
# concurrent suites do not interleave; the green line names the application,
# its ExUnit summary and its elapsed seconds. A suite that executed nothing
# is red, not green, and a compile warning inside the suite is red too.
run_app() {
  local app=$1 name=${1#apps/} app_started=$SECONDS log summary
  log="$LOOPEX_CHECK_LOGS/$name.log"
  if (cd "$app" && mix test --no-compile --warnings-as-errors </dev/null) > "$log" 2>&1 &&
     summary=$(grep -aE '^Result: [1-9][0-9]* passed|^[1-9][0-9]* tests?, 0 failures' "$log" | tail -n 1) &&
     [ -n "$summary" ]; then
    : > "$LOOPEX_CHECK_LOGS/$name.done"
    printf 'check: suite %s green %s in %ss\n' "$name" "${summary#Result: }" "$((SECONDS - app_started))"
  else
    : > "$LOOPEX_CHECK_LOGS/$name.done"
    printf 'check: suite %s RED after %ss\n' "$name" "$((SECONDS - app_started))"
    cat "$log"
    return 1
  fi
}
export -f run_app

suite() {
  local cores jobs logs pid status=0 app remaining
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
  jobs=${LOOPEX_CHECK_JOBS:-$((cores / 2))}
  [ "$jobs" -ge 1 ] || jobs=1
  logs=$(mktemp -d "${TMPDIR:-/tmp}/loopex-check.XXXXXX")
  export LOOPEX_CHECK_LOGS=$logs

  # Heaviest first, measured at M4 closure, then any other application.
  local ordered=(apps/loopex apps/loopex_llm_reqllm apps/loopex_executor_local apps/loopex_cli)
  for app in apps/*/; do
    app=${app%/}
    [ -d "$app/test" ] || continue
    case " ${ordered[*]} " in *" $app "*) ;; *) ordered+=("$app") ;; esac
  done
  printf 'check: suite %s applications, %s at a time\n' "${#ordered[@]}" "$jobs"

  # The runner starts in its own process group, so an interruption reaches
  # every VM beneath it, not only xargs.
  set -m
  printf '%s\n' "${ordered[@]}" | xargs -P "$jobs" -I{} bash -c 'run_app "$1"' _ {} &
  pid=$!
  set +m
  trap 'trap - INT TERM; kill -TERM -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf "$logs"; exit 130' INT TERM
  while kill -0 "$pid" 2>/dev/null; do
    sleep 30
    if kill -0 "$pid" 2>/dev/null; then
      remaining=""
      for app in "${ordered[@]}"; do
        [ -e "$logs/${app#apps/}.done" ] || remaining="$remaining ${app#apps/}"
      done
      printf 'check: suite running total=%ss, still running:%s\n' "$((SECONDS - started))" "$remaining"
    fi
  done
  wait "$pid" || status=$?
  trap - INT TERM
  rm -rf "$logs"
  return "$status"
}

step "warning-free compilation" mix compile --warnings-as-errors
step "formatting" mix format --check-formatted
step "repository structure" bash scripts/check-bootstrap.sh
step "documentation ordering" mix loopex.docs_check
if [ "$mode" = --docs ]; then
  printf 'check: PASS (documentation only) total=%ss\n' "$((SECONDS - started))"
  exit 0
fi
step "dependency budget and direction" mix loopex.deps_budget
step "one version across applications" mix loopex.version_train
step "test build" env MIX_ENV=test mix compile --warnings-as-errors
step "credential-free test suite" suite
printf 'check: PASS total=%ss\n' "$((SECONDS - started))"
