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
# the suite. --select chooses between the two from the diff against the
# integration base: a change that touches only Markdown runs the documentation
# mode, anything else -- or no diff at all, as on the integration branch itself
# -- runs the full check. Hosted CI calls --select so a prose change does not
# spend the suite; a changed operator command lives in a script or a test and
# therefore still runs it.
mode=${1:-full}
case "$mode" in
  full | --docs) ;;
  --select)
    base=$(git merge-base origin/main HEAD 2>/dev/null || true)
    changed=$([ -n "$base" ] && git diff --name-only "$base" HEAD || true)
    if [ -n "$changed" ] && ! printf '%s\n' "$changed" | grep -qvE '\.md$'; then
      mode=--docs
    else
      mode=full
    fi
    printf 'check: selected %s from %s changed paths\n' "$mode" "$(printf '%s\n' "$changed" | grep -c . || true)"
    ;;
  *) echo 'check: usage: check.sh [--docs|--select]' >&2; exit 2 ;;
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
     summary=$(bash scripts/suite-summary.sh "$log"); then
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

# Terminates a process and everything it started, deepest first, so a mix
# process cannot be left running under a dead runner.
kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -TERM "$1" 2>/dev/null || true
}

suite() {
  local cores jobs logs status=0 app
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
  # An application named in LOOPEX_CHECK_ALONE runs with the box to itself
  # before the rest share it. The provider suite boots a real child VM per
  # case under the product's ten-second deadline; on a four-core hosted runner
  # that boot starved behind another application's compile and crossed the
  # deadline, which is the runner measuring itself, not the product. The knob
  # is empty by default so a developer box keeps the fully parallel run.
  local alone=() shared=()
  for app in "${ordered[@]}"; do
    case " ${LOOPEX_CHECK_ALONE:-} " in
      *" ${app#apps/} "*) alone+=("$app") ;;
      *) shared+=("$app") ;;
    esac
  done
  printf 'check: suite %s applications, %s alone, then %s at a time\n' \
    "${#ordered[@]}" "${#alone[@]}" "$jobs"

  if [ "${#alone[@]}" -gt 0 ]; then
    phase 1 "${alone[@]}" || status=$?
  fi
  if [ "${#shared[@]}" -gt 0 ]; then
    phase "$jobs" "${shared[@]}" || status=$?
  fi
  rm -rf "$logs"
  return "$status"
}

# Names what is still running, every thirty seconds, while the runner lives.
# It is its own process so the phase can wait on the workers directly and end
# the instant they do; the earlier shape slept inside the phase and held a
# finished phase for up to thirty seconds.
heartbeat() {
  local pid=$1 remaining app
  shift
  while sleep 30 && kill -0 "$pid" 2>/dev/null; do
    remaining=""
    for app in "$@"; do
      [ -e "$LOOPEX_CHECK_LOGS/${app#apps/}.done" ] || remaining="$remaining ${app#apps/}"
    done
    printf 'check: suite running total=%ss, still running:%s\n' "$((SECONDS - started))" "$remaining"
  done
}

# One scheduling phase: the named applications, at most $1 at a time. An
# interruption must reach every VM beneath the runner, not only xargs, so the
# trap walks the whole process tree under it; Bash returns from the builtin
# wait as soon as a trapped signal arrives, so nothing holds the VMs.
phase() {
  local jobs=$1 pid pulse status=0
  shift
  printf '%s\n' "$@" | xargs -P "$jobs" -I{} bash -c 'run_app "$1"' _ {} &
  pid=$!
  heartbeat "$pid" "$@" &
  pulse=$!
  trap 'trap - INT TERM; kill "$pulse" 2>/dev/null; kill_tree "$pid"; wait "$pid" 2>/dev/null || true; rm -rf "$LOOPEX_CHECK_LOGS"; printf "check: interrupted\n"; exit 130' INT TERM
  wait "$pid" || status=$?
  trap - INT TERM
  kill "$pulse" 2>/dev/null || true
  wait "$pulse" 2>/dev/null || true
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
