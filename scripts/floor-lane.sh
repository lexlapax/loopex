#!/usr/bin/env bash
# Run the M6 fast check under the floor toolchain in a fresh local clone.
# The output directory, clone, and build root are new siblings. A refusal in
# preflight creates none of them; a started run keeps its complete logs.
set -euo pipefail

usage() {
  printf 'floor-lane: usage: floor-lane.sh SHA --output-dir DIR [--long-bound]\n' >&2
  exit 2
}

refuse() {
  printf 'floor-lane: %s\n' "$1" >&2
  exit 2
}

[[ $# -eq 3 || $# -eq 4 ]] || usage
sha=$1
[[ $2 == --output-dir ]] || usage
requested_dir=$3
[[ $# -eq 3 || $4 == --long-bound ]] || usage
[[ $sha =~ ^[0-9a-f]{40}$ ]] || refuse 'SHA must be a full lowercase commit ID'
[[ -n $requested_dir ]] || usage

script_dir=$(cd "$(dirname "$0")" && pwd -P)
repo=$(git -C "$script_dir/.." rev-parse --show-toplevel 2>/dev/null) ||
  refuse 'the script must run from a Git checkout'
repo=$(cd "$repo" && pwd -P)
[[ $(git -C "$repo" cat-file -t "$sha" 2>/dev/null || true) == commit ]] ||
  refuse 'SHA is not a local commit'

parent=$(cd "$(dirname "$requested_dir")" 2>/dev/null && pwd -P) ||
  refuse 'the output parent must exist'
[[ -d $parent && -w $parent ]] || refuse 'the output parent must be writable'
name=$(basename "$requested_dir")
[[ $name != . && $name != .. && -n $name ]] || usage
output_dir=$parent/$name
clone_dir=$parent/$name-source
build_root=$parent/$name-M6-otp27-build
case "$output_dir/" in
  "$repo/"*) refuse 'the output directory must be outside the checkout' ;;
esac
for target in "$output_dir" "$clone_dir" "$build_root"; do
  [[ ! -e $target && ! -L $target ]] || refuse "target already exists: $target"
done

platform=$(uname -s)
case "$platform" in
  Darwin | Linux) ;;
  *) refuse "unsupported platform: $platform" ;;
esac
# Elixir and OTP require UTF-8 native names. A remote login shell can inherit
# the POSIX locale even when the floor toolchain itself is correct; that would
# change filesystem bytes and contaminate exact-output child-VM witnesses.
native_encoding=$(locale charmap 2>/dev/null || true)
case "$native_encoding" in
  UTF-8 | utf8) ;;
  *)
    selected_locale=
    for candidate in C.UTF-8 en_US.UTF-8; do
      candidate_encoding=$(LC_ALL="$candidate" locale charmap 2>/dev/null || true)
      case "$candidate_encoding" in
        UTF-8 | utf8) selected_locale=$candidate; break ;;
      esac
    done
    [[ -n $selected_locale ]] || refuse 'a UTF-8 locale is required for the floor lane'
    export LC_ALL="$selected_locale" LANG="$selected_locale"
    ;;
esac
native_encoding=$(locale charmap 2>/dev/null || true)
case "$native_encoding" in
  UTF-8 | utf8) ;;
  *) refuse 'the selected floor locale is not UTF-8' ;;
esac
command -v mise >/dev/null 2>&1 || refuse 'mise is required for the floor toolchain'
observed=$(mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- \
  elixir -e 'IO.puts(System.version() <> ":" <> to_string(:erlang.system_info(:otp_release)))' \
  2>/dev/null) || refuse 'the floor toolchain is unavailable'
[[ $observed == 1.18.5:27 ]] ||
  refuse "wrong floor toolchain: ${observed:-no version}"

hard_files=$(ulimit -Hn)
if [[ $hard_files == unlimited ]] || [[ $hard_files =~ ^[0-9]+$ && $hard_files -ge 65536 ]]; then
  target_files=65536
elif [[ $hard_files =~ ^[0-9]+$ ]]; then
  target_files=$hard_files
else
  refuse 'cannot read the hard open-file limit'
fi
[[ $target_files -ge 4096 ]] || refuse "at least 4096 open files are required, found $target_files"
ulimit -Sn "$target_files" || refuse 'cannot raise the soft open-file limit'
soft_files=$(ulimit -Sn)
[[ $soft_files =~ ^[0-9]+$ && $soft_files -ge 4096 ]] ||
  refuse "at least 4096 open files are required, found $soft_files"

# A separate sh process tests the disposition inherited by future commands.
# Never signal this runner or its invoking shell. POSIX shells return 128+HUP
# when HUP terminates them; an ignored HUP reaches the sentinel exit 99.
set +e
sh -c 'kill -HUP "$$" || exit 98; exit 99' >/dev/null 2>&1
hup_status=$?
set -e
[[ $hup_status -eq 129 ]] || refuse 'SIGHUP is ignored or its disposition cannot be proved'

umask 077
mkdir -m 700 -- "$output_dir" || refuse 'cannot create the output directory'
check_log=$output_dir/check.log
(set -C; : > "$check_log") || refuse 'cannot create check.log'
retained_logs=("$check_log")
active_pid=
tee_pid=
interrupted_status=0
kill_tree() {
  local pid=$1 signal=$2 child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$child" "$signal"
  done
  kill -"$signal" "$pid" 2>/dev/null || true
}
terminate_active() {
  [[ -n $active_pid ]] || return 0
  kill_tree "$active_pid" TERM
  sleep 1
  kill_tree "$active_pid" KILL
}
on_signal() {
  [[ $interrupted_status -eq 0 ]] || return 0
  interrupted_status=$1
  terminate_active
}
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
retain_identity() {
  local path=$1 digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum <"$path" | awk '{print $1}') || return 1
  else
    digest=$(shasum -a 256 <"$path" | awk '{print $1}') || return 1
  fi
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'floor-lane: retained %s sha256=%s\n' "$path" "$digest"
}
finish() {
  local status=$? path digest_status=0
  trap - EXIT
  trap '' HUP INT TERM
  [[ $interrupted_status -eq 0 ]] || status=$interrupted_status
  printf 'TOTAL_EXIT=%s\nTOTAL_DURATION_S=%s\n' "$status" "$SECONDS" >>"$check_log" || status=1
  for path in "${retained_logs[@]}"; do
    retain_identity "$path" || {
      printf 'floor-lane: retained digest unavailable: %s\n' "$path" >&2
      digest_status=1
    }
  done
  [[ $digest_status -eq 0 ]] || status=1
  exit "$status"
}
trap finish EXIT
printf 'SHA=%s\nPLATFORM=%s\nTOOLCHAIN=erlang@27.3.4 elixir@1.18.5-otp-27\nNATIVE_ENCODING=%s\nOPEN_FILES=%s\nSOURCE=%s\nBUILD_ROOT=%s\n' \
  "$sha" "$platform" "$native_encoding" "$soft_files" "$clone_dir" "$build_root" | tee -a "$check_log"

# The first file is the required retained transcript. The optional second
# file isolates one app's ExUnit summary without losing the combined stream.
run_logged() {
  local label=$1 primary=$2 secondary=$3 started command_status tee_status stream
  shift 3
  local logs=("$primary")
  [[ -z $secondary ]] || logs+=("$secondary")
  printf 'RUN=%s\n' "$label" | tee -a "${logs[@]}"
  started=$SECONDS
  stream=$output_dir/.floor-lane-stream.$$
  mkfifo "$stream" || return 1
  tee -a "${logs[@]}" <"$stream" &
  tee_pid=$!
  if [[ $interrupted_status -ne 0 ]]; then
    kill -TERM "$tee_pid" 2>/dev/null || true
    wait "$tee_pid" 2>/dev/null || true
    tee_pid=
    rm -f -- "$stream"
    printf 'EXIT=%s\nDURATION_S=%s\nLOG_EXIT=1\n' \
      "$interrupted_status" "$((SECONDS - started))" | tee -a "${logs[@]}"
    return "$interrupted_status"
  fi
  "$@" >"$stream" 2>&1 &
  active_pid=$!
  [[ $interrupted_status -eq 0 ]] || terminate_active
  set +e
  wait "$active_pid"
  command_status=$?
  if [[ $interrupted_status -ne 0 ]]; then
    wait "$active_pid" 2>/dev/null || true
    command_status=$interrupted_status
  fi
  active_pid=
  wait "$tee_pid"
  tee_status=$?
  tee_pid=
  set -e
  rm -f -- "$stream"
  printf 'EXIT=%s\nDURATION_S=%s\nLOG_EXIT=%s\n' \
    "$command_status" "$((SECONDS - started))" "$tee_status" | tee -a "${logs[@]}"
  [[ $command_status -eq 0 && $tee_status -eq 0 && $interrupted_status -eq 0 ]]
}

floor_env() {
  env -u MIX_BUILD_PATH -u LOOPEX_PROVIDER_API_KEY -u OPENAI_API_KEY \
    -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY \
    MIX_BUILD_ROOT="$build_root" mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- "$@"
}

fetch_deps() { (cd "$clone_dir" && floor_env mix deps.get); }
fast_check() {
  (cd "$clone_dir" &&
    env -u MIX_BUILD_PATH -u LOOPEX_PROVIDER_API_KEY -u OPENAI_API_KEY \
      -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY \
      MIX_BUILD_ROOT="$build_root" LOOPEX_CHECK_ALONE=loopex_llm_reqllm \
      mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh)
}
long_check() {
  local app=$1
  shift
  (cd "$clone_dir/apps/$app" && floor_env mix test "$@")
}

run_logged build-root "$check_log" '' mkdir -m 700 -- "$build_root" || exit 1
run_logged clone "$check_log" '' git clone --quiet --no-hardlinks "$repo" "$clone_dir" || exit 1
run_logged checkout "$check_log" '' git -C "$clone_dir" checkout --quiet --detach "$sha" || exit 1
run_logged deps-get "$check_log" '' fetch_deps || exit 1
run_logged fast-check "$check_log" '' fast_check || exit 1

if [[ $# -eq 4 ]]; then
  long_log=$output_dir/long-bound.log
  (set -C; : > "$long_log") || exit 1
  retained_logs+=("$long_log")
  for app in loopex loopex_executor_local loopex_daemon; do
    app_log=$output_dir/long-bound-$app.log
    (set -C; : > "$app_log") || exit 1
    retained_logs+=("$app_log")
    run_logged "long-bound-$app" "$long_log" "$app_log" long_check "$app" --only long_bound || exit 1
    count=$(bash "$clone_dir/scripts/suite-summary.sh" "$app_log" --count) || {
      printf 'SUMMARY_EXIT=1\nEXECUTED_CASES=unavailable\n' | tee -a "$long_log" "$app_log"
      printf 'floor-lane: no executed long_bound case in %s\n' "$app" | tee -a "$long_log" "$app_log" >&2
      exit 1
    }
    printf 'SUMMARY_EXIT=0\nEXECUTED_CASES=%s\n' "$count" | tee -a "$long_log" "$app_log"
  done

  drain_log=$output_dir/long-bound-loopex_llm_reqllm.log
  (set -C; : > "$drain_log") || exit 1
  retained_logs+=("$drain_log")
  run_logged long-bound-loopex_llm_reqllm "$drain_log" '' long_check loopex_llm_reqllm \
    test/in_process_transport_drain_test.exs --only long_bound || exit 1
  count=$(bash "$clone_dir/scripts/suite-summary.sh" "$drain_log" --count) || {
    printf 'SUMMARY_EXIT=1\nEXECUTED_CASES=unavailable\n' | tee -a "$drain_log"
    printf 'floor-lane: the transport-drain case did not execute\n' | tee -a "$drain_log" >&2
    exit 1
  }
  printf 'SUMMARY_EXIT=0\nEXECUTED_CASES=%s\n' "$count" | tee -a "$drain_log"
  [[ $count -eq 1 ]] || {
    printf 'floor-lane: expected exactly one transport-drain case, found %s\n' "$count" | tee -a "$drain_log" >&2
    exit 1
  }
fi

printf 'floor-lane: PASS SHA=%s DURATION_S=%s\n' "$sha" "$SECONDS" | tee -a "$check_log"
