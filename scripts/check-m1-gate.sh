#!/usr/bin/env bash
# Executable acceptance gate for milestone M1.
#
# CONCEPT
#
# This runner judges mechanics: locked commands passed, protected selectors ran
# without skips or exclusions, retained evidence has the required structure, and
# real user state was contained. Review still judges whether a test asserts what
# it names and whether retained evidence tells the truth.
#
# TECHNICAL DEPTH
#
# Every protected selector and exact locked name is checked before allocation or
# Mix. At the accepted opening checkpoint the runner therefore reaches the
# declared product red while it is still read-only. The later writable lane owns
# its HOME, build, dependency copy, workspace, and Rebar cache.
if ! [[ -o privileged ]]; then
  builtin printf '%s\n' \
    "M1 gate RED: invoke exactly /bin/bash -p scripts/check-m1-gate.sh" >&2
  builtin exit 1
fi
builtin set +x
builtin set +a
builtin set +e
builtin set +u

emit_gate_output() {
  local destination="$1" bytes="$2"
  if [ -n "${provider_key_value-}" ]; then
    case "$bytes" in
      *"$provider_key_value"*) return 1 ;;
    esac
  fi
  case "$destination" in
    stdout)
      if [ "${loopex_m1_output_fds_sealed-}" = 1 ]; then
        builtin printf '%s' "$bytes" >&8
      else
        builtin printf '%s' "$bytes"
      fi
      ;;
    stderr)
      if [ "${loopex_m1_output_fds_sealed-}" = 1 ]; then
        builtin printf '%s' "$bytes" >&9
      else
        builtin printf '%s' "$bytes" >&2
      fi
      ;;
    *) return 1 ;;
  esac
}

fail() {
  local failure_output="M1 gate RED: $1"$'\n'
  emit_gate_output stderr "$failure_output" || :
  builtin exit 1
}

# Read the sealed child stream with Bash builtins so NUL bytes are refused
# without asking another process to inspect provider-bearing output. The
# non-LF suffix makes every preceding LF and the exact child status observable.
capture_outer_gate_output() {
  local loopex_m1_output_max=16777216
  local loopex_m1_output_chunk loopex_m1_read_status
  local loopex_m1_capture_refusal
  local loopex_m1_terminal_prefix loopex_m1_terminal_status
  local loopex_m1_terminal_suffix loopex_m1_output_destination
  local LC_ALL=C
  builtin export -n LC_ALL \
    || fail "the sealed gate output byte locale could not be isolated"

  loopex_m1_output_chunk=""
  if IFS= builtin read -r -d '' -n $((loopex_m1_output_max + 1)) \
    loopex_m1_output_chunk
  then
    if [ "${#loopex_m1_output_chunk}" -ge $((loopex_m1_output_max + 1)) ]; then
      loopex_m1_capture_refusal="the sealed gate output exceeds its byte bound"
    else
      loopex_m1_capture_refusal="the sealed gate output contains a NUL byte"
    fi
    while IFS= builtin read -r -d '' -n $((loopex_m1_output_max + 1)) \
      loopex_m1_output_chunk
    do
      :
    done
    fail "$loopex_m1_capture_refusal"
  else
    loopex_m1_read_status=$?
  fi
  [ "$loopex_m1_read_status" -eq 1 ] \
    || fail "the sealed gate output could not be captured"
  loopex_m1_output="$loopex_m1_output_chunk"

  loopex_m1_terminal_prefix=$'\035'LOOPEX_M1_OUTER_STATUS_V1:
  case "$loopex_m1_output" in
    *"$loopex_m1_terminal_prefix"*)
      loopex_m1_terminal_status="${loopex_m1_output##*"$loopex_m1_terminal_prefix"}"
      ;;
    *) fail "the sealed gate output status is malformed" ;;
  esac
  [[ "$loopex_m1_terminal_status" =~ ^(0|[1-9][0-9]{0,2})$ ]] &&
    [ "$loopex_m1_terminal_status" -le 255 ] \
    || fail "the sealed gate output status is malformed"
  loopex_m1_terminal_suffix="$loopex_m1_terminal_prefix$loopex_m1_terminal_status"
  case "$loopex_m1_output" in
    *"$loopex_m1_terminal_suffix")
      loopex_m1_output="${loopex_m1_output%"$loopex_m1_terminal_suffix"}"
      ;;
    *) fail "the sealed gate output status is malformed" ;;
  esac
  loopex_m1_status="$loopex_m1_terminal_status"
  if [ "$loopex_m1_status" -eq 0 ]; then
    loopex_m1_output_destination=stdout
  else
    loopex_m1_output_destination=stderr
  fi
  emit_gate_output "$loopex_m1_output_destination" "$loopex_m1_output" \
    || fail "gate-owned output collides with provider credential bytes"
}

# After the clean role begins capture, these helpers derive the absolute OTP
# launcher and send private bytes to it through stdin. The launcher owns the only
# child-environment construction; shell code never changes the incoming
# search-path value or its export attribute.
find_tool_directory() {
  local tool="$1" entry
  loopex_m1_found_tool_directory=""
  for entry in "${loopex_m1_original_path_entries[@]}"; do
    case "$entry" in
      /*)
        if [ -x "$entry/$tool" ] && [ ! -d "$entry/$tool" ]; then
          loopex_m1_found_tool_directory="$entry"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

append_safe_tool_path() {
  local entry="$1"
  case ":$loopex_m1_safe_path:" in
    *":$entry:"*) ;;
    *) loopex_m1_safe_path="${loopex_m1_safe_path:+$loopex_m1_safe_path:}$entry" ;;
  esac
}

refuse_provider_carrier_collision() {
  local loopex_m1_carrier
  [ -n "$provider_key_value" ] || return 0
  for loopex_m1_carrier in "$@"; do
    case "$loopex_m1_carrier" in
      *"$provider_key_value"*) return 1 ;;
    esac
  done
}

validate_m0_absence_root() {
  local root="$1" entry base line1 line2 line3 extra core seen=" "
  local physical environment_manager="py""env"
  [ -d "$root" ] && [ ! -L "$root" ] \
    || fail "the leading M0 absence root is not an ordinary directory"
  physical="$(builtin cd -P -- "$root" 2>/dev/null && builtin pwd -P)" \
    || fail "the leading M0 absence root could not be resolved physically"
  [ -n "$physical" ] || fail "the leading M0 absence root resolved empty"

  builtin shopt -s nullglob dotglob
  for entry in "$physical"/*; do
    [ -f "$entry" ] && [ ! -L "$entry" ] && [ -x "$entry" ] \
      || fail "M0 absence root contains a non-ordinary executable"
    base="${entry##*/}"
    case "$base" in
      python | python2 | python3 | jq | xcrun | uv | "$environment_manager" | pipx | poetry | conda | \
        python[0-9] | python[0-9].[0-9] | python[0-9].[0-9][0-9]) ;;
      *) fail "M0 absence root contains an unexpected entry" ;;
    esac
    {
      IFS= builtin read -r line1 &&
        IFS= builtin read -r line2 &&
        IFS= builtin read -r line3 &&
        ! IFS= builtin read -r extra
    } < "$entry" || fail "M0 absence root contains a noncanonical stub"
    [ "$line1" = '#!/bin/sh' ] &&
      [ "$line2" = "echo \"$base is retired; outcome 8 requires its absence\" >&2" ] &&
      [ "$line3" = 'exit 127' ] \
      || fail "M0 absence root contains a noncanonical stub"
    seen="$seen$base "
  done
  builtin shopt -u nullglob dotglob
  # M0's immutable bypass regex reads the environment manager's suffix as an
  # `env` invocation when its full name appears inside a data list. Keep that
  # one identity assembled above while validating the exact same stub set.
  for core in python python2 python3 jq xcrun uv "$environment_manager" pipx poetry conda; do
    case "$seen" in
      *" $core "*) ;;
      *) fail "M0 absence root is missing a core retired-name stub" ;;
    esac
  done
  loopex_m1_absence_root="$physical"
}

outer_launch() {
  local loopex_m1_control loopex_m1_initial_bytes=0
  local loopex_m1_initial_max=16384 loopex_m1_initial_total_max=131072
  local LC_ALL=C
  builtin export -n LC_ALL \
    || fail "the pre-frame byte-counting locale could not be isolated"

  builtin cd -P . || fail "the initial repository root could not be resolved physically"
  local loopex_m1_repository_input="$PWD"
  local loopex_m1_clean_script="$loopex_m1_repository_input/scripts/check-m1-gate.sh"
  local loopex_m1_clean_command='builtin source "$1" || builtin exit 1; builtin shift; clean_outer_launch "$@"'
  local loopex_m1_clean_command_name=loopex-m1-clean-outer
  local loopex_m1_real_home_input="${HOME-}"
  local loopex_m1_task_tmp_input="${TMPDIR:-/tmp}"
  local loopex_m1_source_mix_home_input="${MIX_HOME:-${HOME-}/.mix}"
  local loopex_m1_gate_seed_input="${LOOPEX_GATE_SEED-}"
  local loopex_m1_original_tool_path="${PATH-}"

  builtin unset -v provider_key_value \
    || fail "the pre-frame provider holder could not be cleared"
  builtin ulimit -S -c 0 || fail "the soft core-file limit could not be sealed"
  builtin ulimit -H -c 0 || fail "the hard core-file limit could not be sealed"

  if [ "${LOOPEX_PROVIDER_API_KEY+x}" = x ]; then
    fail "canonical provider credential is forbidden in the initial environment"
  fi

  [ -n "$PWD" ] && [ -n "$loopex_m1_real_home_input" ] &&
    [ -n "$loopex_m1_task_tmp_input" ] && [ -n "$loopex_m1_source_mix_home_input" ] &&
    [ -n "$loopex_m1_original_tool_path" ] \
    || fail "a required pre-frame control is empty"
  [ -f "$loopex_m1_clean_script" ] && [ ! -L "$loopex_m1_clean_script" ] \
    || fail "the fixed M1 clean re-exec script is unavailable"

  case "$#" in
    0) ;;
    1) [ "$1" = --environment-fixture ] \
      || fail "the public M1 gate role is invalid" ;;
    2) [ "$1" = --capture ] &&
      case "$2" in floor | current | linux-current) : ;; *) false ;; esac \
      || fail "the public M1 gate role is invalid" ;;
    *) fail "the public M1 gate role is invalid" ;;
  esac

  for loopex_m1_control in \
    "$loopex_m1_repository_input" \
    "$loopex_m1_real_home_input" \
    "$loopex_m1_task_tmp_input" \
    "$loopex_m1_source_mix_home_input" \
    "$loopex_m1_gate_seed_input" \
    "$loopex_m1_original_tool_path" \
    "$loopex_m1_clean_command" \
    "$loopex_m1_clean_command_name" \
    "$@"
  do
    [ "${#loopex_m1_control}" -le "$loopex_m1_initial_max" ] \
      || fail "a pre-frame control exceeds its byte bound"
    case "$loopex_m1_control" in
      *$'\n'* | *$'\r'*) fail "a pre-frame control contains a line break" ;;
    esac
    loopex_m1_initial_bytes=$((loopex_m1_initial_bytes + ${#loopex_m1_control}))
  done
  [ "$loopex_m1_initial_bytes" -le "$loopex_m1_initial_total_max" ] \
    || fail "the pre-frame controls exceed their total byte bound"

  builtin exec -c /bin/bash -p -c "$loopex_m1_clean_command" \
    "$loopex_m1_clean_command_name" \
    "$loopex_m1_clean_script" \
    LOOPEX_M1_CLEAN_OUTER_V1 \
    "$loopex_m1_repository_input" \
    "$loopex_m1_real_home_input" \
    "$loopex_m1_task_tmp_input" \
    "$loopex_m1_source_mix_home_input" \
    "$loopex_m1_gate_seed_input" \
    "$loopex_m1_original_tool_path" \
    -- \
    "$@"
  fail "the fixed M1 clean re-exec failed"
}

clean_outer_launch() {
  local loopex_m1_status loopex_m1_control loopex_m1_clean_bytes=0
  local loopex_m1_clean_max=16384 loopex_m1_clean_total_max=131072
  local provider_frame_header provider_frame_trailing provider_frame_header_limit
  local provider_frame_version=LOOPEX_M1_PROVIDER_V1
  local provider_frame_max=16384

  builtin unset -v LC_ALL \
    || fail "the byte-counting locale could not be isolated"
  local LC_ALL=C
  builtin export -n LC_ALL \
    || fail "the byte-counting locale could not be made private"

  [ "$#" -ge 8 ] && [ "$1" = LOOPEX_M1_CLEAN_OUTER_V1 ] && [ "$8" = -- ] \
    || fail "the internal clean re-exec grammar is invalid"
  loopex_m1_clean_header="$1"
  loopex_m1_repository_control="$2"
  loopex_m1_real_home_input="$3"
  loopex_m1_task_tmp_input="$4"
  loopex_m1_source_mix_home_input="$5"
  loopex_m1_gate_seed_input="$6"
  loopex_m1_original_tool_path="$7"
  shift 8
  loopex_m1_original_arguments=("$@")
  loopex_m1_clean_command="${BASH_EXECUTION_STRING-}"
  loopex_m1_clean_command_name="$0"

  case "$#" in
    0) ;;
    1) [ "$1" = --environment-fixture ] \
      || fail "the internal clean re-exec grammar is invalid" ;;
    2) [ "$1" = --capture ] &&
      case "$2" in floor | current | linux-current) : ;; *) false ;; esac \
      || fail "the internal clean re-exec grammar is invalid" ;;
    *) fail "the internal clean re-exec grammar is invalid" ;;
  esac

  [ "$loopex_m1_clean_command" = 'builtin source "$1" || builtin exit 1; builtin shift; clean_outer_launch "$@"' ] &&
    [ "$loopex_m1_clean_command_name" = loopex-m1-clean-outer ] &&
    [ "$PWD" = "$loopex_m1_repository_control" ] && [ "$SHLVL" = 1 ] &&
    [ "${HOME+x}" != x ] && [ "${TMPDIR+x}" != x ] &&
    [ "${MIX_HOME+x}" != x ] && [ "${LOOPEX_GATE_SEED+x}" != x ] &&
    [ "${LOOPEX_PROVIDER_API_KEY+x}" != x ] && [ "${provider_key_value+x}" != x ] &&
    [ "${BASH_ENV+x}" != x ] && [ "${ENV+x}" != x ] \
    || fail "the internal clean re-exec state is invalid"
  builtin ulimit -S -c 0 || fail "the inherited soft core-file limit is not sealed"
  builtin ulimit -H -c 0 || fail "the inherited hard core-file limit is not sealed"

  for loopex_m1_control in \
    "$loopex_m1_repository_control" \
    "$loopex_m1_real_home_input" \
    "$loopex_m1_task_tmp_input" \
    "$loopex_m1_source_mix_home_input" \
    "$loopex_m1_gate_seed_input" \
    "$loopex_m1_original_tool_path" \
    "$loopex_m1_clean_command" \
    "$loopex_m1_clean_command_name" \
    "${loopex_m1_original_arguments[@]}"
  do
    [ "${#loopex_m1_control}" -le "$loopex_m1_clean_max" ] \
      || fail "an internal clean re-exec control exceeds its byte bound"
    case "$loopex_m1_control" in
      *$'\n'* | *$'\r'*) fail "an internal clean re-exec control contains a line break" ;;
    esac
    loopex_m1_clean_bytes=$((loopex_m1_clean_bytes + ${#loopex_m1_control}))
  done
  [ "$loopex_m1_clean_bytes" -le "$loopex_m1_clean_total_max" ] \
    || fail "the internal clean re-exec controls exceed their total byte bound"

  loopex_m1_path_control_name=PATH
  loopex_m1_path_control_record="${loopex_m1_path_control_name}=${loopex_m1_original_tool_path}"
  loopex_m1_pre_frame_carriers=(
    /bin/bash
    -c
    -p
    "$loopex_m1_clean_command"
    "$loopex_m1_clean_command_name"
    "$loopex_m1_repository_control/scripts/check-m1-gate.sh"
    "$loopex_m1_clean_header"
    PWD
    "$loopex_m1_repository_control"
    "PWD=$loopex_m1_repository_control"
    HOME
    "$loopex_m1_real_home_input"
    "HOME=$loopex_m1_real_home_input"
    TMPDIR
    "$loopex_m1_task_tmp_input"
    "TMPDIR=$loopex_m1_task_tmp_input"
    MIX_HOME
    "$loopex_m1_source_mix_home_input"
    "MIX_HOME=$loopex_m1_source_mix_home_input"
    LOOPEX_GATE_SEED
    "$loopex_m1_gate_seed_input"
    "LOOPEX_GATE_SEED=$loopex_m1_gate_seed_input"
    "$loopex_m1_path_control_name"
    "$loopex_m1_original_tool_path"
    "$loopex_m1_path_control_record"
    SHLVL
    1
    SHLVL=1
    LOOPEX_PROVIDER_API_KEY
    provider_key_value
    /dev/null
    loopex_m1_output_fds_sealed
    8
    9
    --
    "${loopex_m1_original_arguments[@]}"
  )

  exec 8>&1 9>&2 2>/dev/null \
    || fail "the private gate output descriptors could not be sealed"
  loopex_m1_output_fds_sealed=1
  builtin export -n loopex_m1_output_fds_sealed \
    || fail "the private gate output state could not be made unexported"

  builtin unset -v provider_key_value \
    || fail "the private provider holder could not be reset"
  provider_key_value=""
  builtin export -n provider_key_value \
    || fail "the private provider holder could not be made unexported"
  provider_frame_header=""
  if ! [ -t 0 ]; then
    provider_frame_header_limit=$((${#provider_frame_version} + 1))
    if IFS= builtin read -r -d '' -n "$provider_frame_header_limit" provider_frame_header; then
      [ "$provider_frame_header" = "$provider_frame_version" ] \
        || fail "provider input is malformed"
      IFS= builtin read -r -d '' -n $((provider_frame_max + 1)) provider_key_value \
        || fail "provider input is malformed"
      [ -n "$provider_key_value" ] && [ "${#provider_key_value}" -le "$provider_frame_max" ] \
        || fail "provider input is malformed"
      provider_frame_trailing=""
      if IFS= builtin read -r -d '' -n 1 provider_frame_trailing ||
        [ -n "$provider_frame_trailing" ]
      then
        fail "provider input is malformed"
      fi
    elif [ -n "$provider_frame_header" ]; then
      fail "provider input is malformed"
    fi
  fi

  refuse_provider_carrier_collision "${loopex_m1_pre_frame_carriers[@]}" \
    || fail "a pre-frame carrier collides with provider credential bytes"

  capture_outer_gate_output < <(
    {
      exec 8>&- 9>&- \
        || builtin exit 1
      loopex_m1_output_fds_sealed=0
      (outer_launch_captured "${loopex_m1_original_arguments[@]}")
      loopex_m1_status=$?
      builtin printf '\035LOOPEX_M1_OUTER_STATUS_V1:%s' "$loopex_m1_status"
    } 2>&1
  )
  builtin exit "$loopex_m1_status"
}

outer_launch_captured() {
  loopex_m1_outer_child_executable=/usr/bin/env
  loopex_m1_outer_child_pwd_name=PWD
  loopex_m1_outer_child_pwd_value="$PWD"
  loopex_m1_outer_child_pwd_record="${loopex_m1_outer_child_pwd_name}=${loopex_m1_outer_child_pwd_value}"
  loopex_m1_outer_child_shlvl_name=SHLVL
  loopex_m1_outer_child_shlvl_value="$SHLVL"
  loopex_m1_outer_child_shlvl_record="${loopex_m1_outer_child_shlvl_name}=${loopex_m1_outer_child_shlvl_value}"
  loopex_m1_outer_child_under_name=_
  loopex_m1_outer_child_under_value="$loopex_m1_outer_child_executable"
  loopex_m1_outer_child_under_record="${loopex_m1_outer_child_under_name}=${loopex_m1_outer_child_under_value}"
  loopex_m1_outer_child_carriers=(
    "$loopex_m1_outer_child_executable"
    "$loopex_m1_outer_child_pwd_name"
    "$loopex_m1_outer_child_pwd_value"
    "$loopex_m1_outer_child_pwd_record"
    "$loopex_m1_outer_child_shlvl_name"
    "$loopex_m1_outer_child_shlvl_value"
    "$loopex_m1_outer_child_shlvl_record"
    "$loopex_m1_outer_child_under_name"
    "$loopex_m1_outer_child_under_value"
    "$loopex_m1_outer_child_under_record"
  )
  refuse_provider_carrier_collision "${loopex_m1_outer_child_carriers[@]}" \
    || fail "an outer child carrier collides with provider credential bytes"

  loopex_m1_original_path_entries=()
  loopex_m1_path_rest="$loopex_m1_original_tool_path"
  loopex_m1_path_done=0
  while [ "$loopex_m1_path_done" -eq 0 ]; do
    case "$loopex_m1_path_rest" in
      *:*)
        loopex_m1_path_entry="${loopex_m1_path_rest%%:*}"
        loopex_m1_path_rest="${loopex_m1_path_rest#*:}"
        ;;
      *)
        loopex_m1_path_entry="$loopex_m1_path_rest"
        loopex_m1_path_rest=""
        loopex_m1_path_done=1
        ;;
    esac
    [ -n "$loopex_m1_path_entry" ] \
      || fail "the incoming toolchain path contains an empty component"
    loopex_m1_original_path_entries+=("$loopex_m1_path_entry")
  done

  find_tool_directory mix || fail "mix is not available on the incoming toolchain path"
  loopex_m1_mix_directory="$loopex_m1_found_tool_directory"
  find_tool_directory elixir || fail "elixir is not available on the incoming toolchain path"
  loopex_m1_elixir_directory="$loopex_m1_found_tool_directory"
  find_tool_directory erl || fail "erl is not available on the incoming toolchain path"
  loopex_m1_erl_directory="$loopex_m1_found_tool_directory"
  loopex_m1_escript="$loopex_m1_erl_directory/escript"
  [ -f "$loopex_m1_escript" ] && [ -x "$loopex_m1_escript" ] \
    || fail "escript is not executable beside erl"

  loopex_m1_safe_path=""
  loopex_m1_absence_root=""
  loopex_m1_first_path_entry="${loopex_m1_original_path_entries[0]}"
  case "$loopex_m1_first_path_entry" in
    */loopex-m0-absence.*)
      validate_m0_absence_root "$loopex_m1_first_path_entry"
      append_safe_tool_path "$loopex_m1_absence_root"
      ;;
  esac
  append_safe_tool_path /usr/bin
  append_safe_tool_path /bin
  append_safe_tool_path /usr/sbin
  append_safe_tool_path /sbin
  append_safe_tool_path "$loopex_m1_mix_directory"
  append_safe_tool_path "$loopex_m1_elixir_directory"
  append_safe_tool_path "$loopex_m1_erl_directory"

  loopex_m1_launcher="$PWD/scripts/m1-gate-launcher.escript"
  [ -f "$loopex_m1_launcher" ] && [ ! -L "$loopex_m1_launcher" ] \
    || fail "the bound M1 gate launcher is unavailable"

  loopex_m1_launcher_frame=(
    LOOPEX_M1_LAUNCHER_V1
    "$loopex_m1_real_home_input"
    "$loopex_m1_task_tmp_input"
    "$loopex_m1_source_mix_home_input"
    "$loopex_m1_gate_seed_input"
    "$loopex_m1_safe_path"
  )
  loopex_m1_launcher_environment=(
    ERL_CRASH_DUMP=/dev/null
    ERL_CRASH_DUMP_SECONDS=0
    LANG=C.UTF-8
    LC_ALL=C.UTF-8
  )
  loopex_m1_launcher_arguments=(
    "$loopex_m1_escript"
    "$loopex_m1_launcher"
    "$@"
  )
  refuse_provider_carrier_collision \
    /usr/bin/env \
    -i \
    "${loopex_m1_launcher_frame[@]}" \
    "${loopex_m1_launcher_environment[@]}" \
    "${loopex_m1_launcher_arguments[@]}" \
    || fail "a launcher carrier collides with provider credential bytes"

  for loopex_m1_value in \
    "$loopex_m1_real_home_input" \
    "$loopex_m1_task_tmp_input" \
    "$loopex_m1_source_mix_home_input" \
    "$loopex_m1_gate_seed_input" \
    "$loopex_m1_safe_path" \
    / C.UTF-8 0
  do
    case "$loopex_m1_value" in
      *$'\n'* | *$'\r'*) fail "a required runner control contains a line break" ;;
    esac
  done

  {
    builtin printf '%s\0' \
      "${loopex_m1_launcher_frame[@]}" \
      "$provider_key_value"
  } | /usr/bin/env -i \
    "${loopex_m1_launcher_environment[@]}" \
    "${loopex_m1_launcher_arguments[@]}"
  return "${PIPESTATUS[1]}"
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

case "${1-}" in
  --loopex-m1-sealed-inner)
    shift
    ;;
  *) outer_launch "$@" ;;
esac

read_sealed_field() {
  IFS= builtin read -r -d '' "$1" \
    || fail "sealed launcher input is unavailable"
}

read_sealed_field loopex_m1_inner_header
read_sealed_field loopex_m1_real_home_input
read_sealed_field loopex_m1_task_tmp_input
read_sealed_field loopex_m1_source_mix_home_input
read_sealed_field loopex_m1_gate_seed_input
read_sealed_field loopex_m1_safe_path_input
read_sealed_field provider_key_value
[ "$loopex_m1_inner_header" = LOOPEX_M1_SEALED_INNER_V1 ] \
  || fail "sealed launcher input is malformed"
[ "$PATH" = "$loopex_m1_safe_path_input" ] \
  || fail "sealed child search path does not match launcher authority"

builtin unset -v PWD OLDPWD SHLVL _ 2>/dev/null \
  || fail "Bash-created child state could not be removed"
IFS=$' \t\n'
builtin unset -v CDPATH ENV BASH_ENV GLOBIGNORE POSIXLY_CORRECT OPTARG 2>/dev/null \
  || fail "ambient shell controls could not be cleared"
OPTIND=1
builtin unalias -a 2>/dev/null || fail "ambient aliases could not be cleared"
builtin hash -r
builtin set +a +b +C +e +f +h +k +m +n +t +u +v +x
builtin set -B
builtin set +o posix
builtin set +o pipefail
builtin shopt -u cdable_vars cdspell dotglob execfail expand_aliases extdebug extglob \
  failglob nocaseglob nocasematch nullglob sourcepath xpg_echo
builtin shopt -s extquote
builtin umask 077

loopex_m1_env_capture="$(
  /usr/bin/env
  loopex_m1_env_status=$?
  builtin printf 'LOOPEX_M1_ENV_STATUS=%s' "$loopex_m1_env_status"
)"
case "$loopex_m1_env_capture" in
  *$'\nLOOPEX_M1_ENV_STATUS=0')
    loopex_m1_env_output="${loopex_m1_env_capture%$'\nLOOPEX_M1_ENV_STATUS=0'}"
    ;;
  *) fail "the canonical child environment could not be inspected" ;;
esac
loopex_m1_path_count=0
loopex_m1_home_count=0
loopex_m1_lang_count=0
loopex_m1_lc_count=0
loopex_m1_git_count=0
loopex_m1_under_count=0
loopex_m1_env_rest="$loopex_m1_env_output"
while [ -n "$loopex_m1_env_rest" ]; do
  case "$loopex_m1_env_rest" in
    *$'\n'*)
      loopex_m1_line="${loopex_m1_env_rest%%$'\n'*}"
      loopex_m1_env_rest="${loopex_m1_env_rest#*$'\n'}"
      ;;
    *) loopex_m1_line="$loopex_m1_env_rest"; loopex_m1_env_rest="" ;;
  esac
  loopex_m1_env_name="${loopex_m1_line%%=*}"
  loopex_m1_env_value="${loopex_m1_line#*=}"
  case "$loopex_m1_env_name:$loopex_m1_env_value" in
    PATH:"$PATH") loopex_m1_path_count=$((loopex_m1_path_count + 1)) ;;
    HOME:/) loopex_m1_home_count=$((loopex_m1_home_count + 1)) ;;
    LANG:C.UTF-8) loopex_m1_lang_count=$((loopex_m1_lang_count + 1)) ;;
    LC_ALL:C.UTF-8) loopex_m1_lc_count=$((loopex_m1_lc_count + 1)) ;;
    GIT_OPTIONAL_LOCKS:0) loopex_m1_git_count=$((loopex_m1_git_count + 1)) ;;
    _:/usr/bin/env) loopex_m1_under_count=$((loopex_m1_under_count + 1)) ;;
    *) fail "the first child received an ambient or invalid environment entry" ;;
  esac
done
[ "$loopex_m1_path_count" -eq 1 ] &&
  [ "$loopex_m1_home_count" -eq 1 ] &&
  [ "$loopex_m1_lang_count" -eq 1 ] &&
  [ "$loopex_m1_lc_count" -eq 1 ] &&
  [ "$loopex_m1_git_count" -eq 1 ] &&
  [ "$loopex_m1_under_count" -eq 1 ] \
  || fail "the first child did not receive exactly the canonical environment"

loopex_m1_original_path_entries=()
loopex_m1_path_rest="$PATH"
loopex_m1_path_done=0
while [ "$loopex_m1_path_done" -eq 0 ]; do
  case "$loopex_m1_path_rest" in
    *:*)
      loopex_m1_path_entry="${loopex_m1_path_rest%%:*}"
      loopex_m1_path_rest="${loopex_m1_path_rest#*:}"
      ;;
    *)
      loopex_m1_path_entry="$loopex_m1_path_rest"
      loopex_m1_path_rest=""
      loopex_m1_path_done=1
      ;;
  esac
  loopex_m1_original_path_entries+=("$loopex_m1_path_entry")
done
find_tool_directory mix || fail "mix is unavailable in the sealed child"
loopex_m1_mix_directory="$loopex_m1_found_tool_directory"
find_tool_directory elixir || fail "elixir is unavailable in the sealed child"
loopex_m1_elixir_directory="$loopex_m1_found_tool_directory"
find_tool_directory erl || fail "erl is unavailable in the sealed child"
loopex_m1_erl_directory="$loopex_m1_found_tool_directory"

builtin set -euo pipefail

# Every later BEAM child, including read-only project inspection before task-root
# allocation, must suppress crash dumps. Provider bytes never belong in a
# checkout or ambient-home dump even when the emulator itself fails.
ERL_CRASH_DUMP=/dev/null
ERL_CRASH_DUMP_SECONDS=0
builtin export ERL_CRASH_DUMP ERL_CRASH_DUMP_SECONDS

# HOME is an ambient convenience, not identity authority. Resolve the current
# account name with the baseline POSIX `id`, validate it as data, and let Bash's
# own `~name` account expansion resolve the home. This avoids adding a platform-
# specific directory-service command. The supplied HOME must later name the
# same physical directory.
account_home_from_os() {
  local account_name account_spec account_home
  account_name="$(/usr/bin/id -un 2>/dev/null)" || return 1
  case "$account_name" in
    "" | *$'\n'* | *$'\r'* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  account_spec="~$account_name"
  builtin eval "account_home=$account_spec" || return 1

  case "$account_home" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$account_home" in
    *$'\n'* | *$'\r'*) return 1 ;;
  esac
  if [ -n "$provider_key_value" ]; then
    case "$account_home" in
      *"$provider_key_value"*) return 1 ;;
    esac
  fi
  builtin printf '%s' "$account_home"
}

loopex_m1_account_home="$(account_home_from_os)" \
  || fail "the operating-system account home could not be resolved safely"

case "$#:$*" in
  0:) gate_role=ordinary ;;
  1:--environment-fixture) gate_role=environment-fixture ;;
  2:--capture\ floor | 2:--capture\ current | 2:--capture\ linux-current)
    capture_lane="$2"
    gate_role=capture
    ;;
  *)
    fail "usage: /bin/bash -p scripts/check-m1-gate.sh [--capture floor|current|linux-current]"
    ;;
esac

SECONDS=0

# Provider diagnostics are captured and redacted in this shell before printing.
# If a literal-removal pass cannot prove the key bytes absent, diagnostics are
# suppressed instead. The value is neither an argv element nor input to a
# redaction subprocess.
redacted() {
  local redacted_output
  if [ -n "$provider_key_value" ]; then
    local cleaned="${1//"$provider_key_value"/}"
    case "$cleaned" in
      *"$provider_key_value"*) redacted_output="provider diagnostic suppressed"$'\n' ;;
      *) redacted_output="$cleaned"$'\n' ;;
    esac
  else
    redacted_output="$1"$'\n'
  fi
  emit_gate_output stdout "$redacted_output"
}

repository_output="$(command -p git rev-parse --show-toplevel 2>&1)" \
  || fail "the repository root could not be resolved"
if [ -n "$provider_key_value" ]; then
  case "$repository_output" in
    *"$provider_key_value"*) fail "the repository root contains provider credential bytes" ;;
  esac
fi
repository_root="$(printf '%s\n' "$repository_output" | grep -v 'DARWIN_USER_TEMP_DIR')" \
  || fail "the repository root lookup returned no usable path"
case "$repository_root" in
  "" | *$'\n'*) fail "the repository root lookup returned an ambiguous path" ;;
esac
cd -- "$repository_root" || fail "the repository root could not be entered"
builtin export -n PWD OLDPWD 2>/dev/null \
  || fail "derived working-directory state could not be kept private"

# Physical containment is the safety property. Lexical path checks miss relative
# paths, `..`, dangling links, link chains, case folding, and the macOS Data-volume
# alias. Define and apply the account-home identity check before selector
# preflight so a caller cannot redirect protected-state authority through HOME,
# even at the accepted opening red checkpoint.
user_state_dirname=".loopex"

resolve_physical() {
  local remaining="$1" resolved="" comp link guard=0
  case "$remaining" in
    /*) ;;
    *) remaining="$PWD/$remaining" ;;
  esac
  while [ -n "$remaining" ]; do
    remaining="${remaining#/}"
    case "$remaining" in
      */*)
        comp="${remaining%%/*}"
        remaining="/${remaining#*/}"
        ;;
      *)
        comp="$remaining"
        remaining=""
        ;;
    esac
    case "$comp" in
      "" | .) continue ;;
      ..)
        resolved="${resolved%/*}"
        continue
        ;;
    esac
    if [ -L "$resolved/$comp" ]; then
      guard=$((guard + 1))
      [ "$guard" -le 64 ] || { printf '%s' ""; return 0; }
      link="$(readlink "$resolved/$comp")"
      case "$link" in
        /*)
          resolved=""
          remaining="$link$remaining"
          ;;
        *) remaining="/$link$remaining" ;;
      esac
    else
      resolved="$resolved/$comp"
    fi
  done
  printf '%s' "${resolved:-/}"
}

valid_node_id() { [[ "$1" =~ ^[0-9]+:[0-9]+$ ]]; }

valid_entry_mode() { [[ "$1" =~ ^[0-7]{3,6}$ ]]; }

detect_stat_style() {
  local probe
  if probe="$(stat -f '%d:%i' -- / 2>/dev/null)" && valid_node_id "$probe"; then
    builtin printf '%s' bsd
    return 0
  fi
  if probe="$(stat -c '%d:%i' -- / 2>/dev/null)" && valid_node_id "$probe"; then
    builtin printf '%s' gnu
    return 0
  fi
  return 1
}

stat_style="$(detect_stat_style)" \
  || fail "no supported stat identity format is available"

valid_utf8_charmap() { [ "$#" -eq 1 ] && [ "$1" = UTF-8 ]; }

locale_charmap="$(/usr/bin/locale charmap 2>/dev/null)" \
  || fail "the canonical UTF-8 locale is unavailable"
valid_utf8_charmap "$locale_charmap" \
  || fail "the canonical locale does not resolve to UTF-8"

system_name="$(uname -s 2>/dev/null)" \
  || fail "the operating-system identity is unavailable"
case "$system_name" in
  Darwin) runtime_os=darwin ;;
  Linux) runtime_os=linux ;;
  *) fail "only Darwin and Linux are supported M1 execution platforms" ;;
esac
runtime_arch="$(uname -m 2>/dev/null)" \
  || fail "the machine architecture identity is unavailable"
[[ "$runtime_arch" =~ ^[A-Za-z0-9._-]+$ ]] \
  || fail "the machine architecture identity is malformed"
runtime_nofile="$(ulimit -n)" \
  || fail "the open-file limit is unavailable"
runtime_nproc="$(ulimit -u)" \
  || fail "the process limit is unavailable"
runtime_core_soft="$(ulimit -S -c)" \
  || fail "the soft core-file limit is unavailable"
runtime_core_hard="$(ulimit -H -c)" \
  || fail "the hard core-file limit is unavailable"
[ "$runtime_core_soft" = 0 ] && [ "$runtime_core_hard" = 0 ] \
  || fail "the inherited core-file limits are not sealed at zero"
[[ "$runtime_nofile" =~ ^([1-9][0-9]*|unlimited)$ ]] \
  || fail "the open-file limit is malformed"
[[ "$runtime_nproc" =~ ^([1-9][0-9]*|unlimited)$ ]] \
  || fail "the process limit is malformed"
runtime_limits="core-soft-$runtime_core_soft,core-hard-$runtime_core_hard,nofile-$runtime_nofile,nproc-$runtime_nproc"

detect_sha256_style() {
  local output digest
  if output="$(builtin printf '' | shasum -a 256 2>/dev/null)"; then
    digest="${output%% *}"
    if [ "$digest" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]; then
      builtin printf '%s' shasum
      return 0
    fi
  fi
  if output="$(builtin printf '' | sha256sum 2>/dev/null)"; then
    digest="${output%% *}"
    if [ "$digest" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]; then
      builtin printf '%s' sha256sum
      return 0
    fi
  fi
  return 1
}

sha256_style="$(detect_sha256_style)" \
  || fail "no validated SHA-256 command is available"

sha256_stream() {
  local output digest
  case "$sha256_style" in
    shasum) output="$(shasum -a 256)" || return 1 ;;
    sha256sum) output="$(sha256sum)" || return 1 ;;
    *) return 1 ;;
  esac
  digest="${output%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  builtin printf '%s' "$digest"
}

sha256_file() {
  [ "$#" -eq 1 ] || return 1
  sha256_stream < "$1"
}

if [ "$gate_role" = capture ]; then
  case "$capture_lane:$runtime_os" in
    floor:darwin | current:darwin | linux-current:linux) ;;
    *) fail "capture lane $capture_lane does not match execution platform $runtime_os" ;;
  esac
fi

node_id() {
  local value
  [ -e "$1" ] || [ -L "$1" ] || return 1
  case "$stat_style" in
    bsd) value="$(stat -f '%d:%i' -- "$1" 2>/dev/null)" || return 2 ;;
    gnu) value="$(stat -c '%d:%i' -- "$1" 2>/dev/null)" || return 2 ;;
    *) return 2 ;;
  esac
  valid_node_id "$value" || return 2
  builtin printf '%s' "$value"
}

entry_mode() {
  local value
  case "$stat_style" in
    bsd) value="$(stat -f '%Lp' -- "$1" 2>/dev/null)" || return 1 ;;
    gnu) value="$(stat -c '%a' -- "$1" 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
  esac
  valid_entry_mode "$value" || return 1
  builtin printf '%s' "$value"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

account_home_resolved="$(resolve_physical "$loopex_m1_account_home")"
supplied_home_resolved="$(resolve_physical "$loopex_m1_real_home_input")"
[ -n "$account_home_resolved" ] && [ -d "$account_home_resolved" ] \
  || fail "the operating-system account home is not an existing directory"
[ -n "$supplied_home_resolved" ] && [ -d "$supplied_home_resolved" ] \
  || fail "the supplied HOME is not an existing directory"
account_home_id="$(node_id "$account_home_resolved")" \
  || fail "the operating-system account home identity is unavailable"
supplied_home_id="$(node_id "$supplied_home_resolved")" \
  || fail "the supplied HOME identity is unavailable"
[ "$account_home_id" = "$supplied_home_id" ] \
  || fail "the supplied HOME does not physically match the operating-system account home"
real_home="${account_home_resolved%/}"
real_user_state_path="$real_home/$user_state_dirname"

protected_resolved="$(resolve_physical "$real_user_state_path")"
[ -n "$protected_resolved" ] \
  || fail "the protected state path could not be resolved; refusing to run"
protected_parent="${protected_resolved%/*}"
[ -n "$protected_parent" ] || protected_parent=/
protected_name="${protected_resolved##*/}"
protected_parent_id="$(node_id "$protected_parent")" || {
  [ "$?" -eq 1 ] \
    || fail "the identity of $protected_parent could not be read; containment evidence is unavailable"
  protected_parent_id=""
}
protected_id="$(node_id "$protected_resolved")" || {
  [ "$?" -eq 1 ] \
    || fail "the identity of $protected_resolved could not be read; containment evidence is unavailable"
  protected_id=""
}
protected_lc="$(lower "${protected_resolved%/}")"
protected_name_lc="$(lower "$protected_name")"

outside_protected_state() {
  local candidate cand_lc prefix rest base parent id
  candidate="$(resolve_physical "$1")"
  [ -n "$candidate" ] || return 1
  cand_lc="$(lower "${candidate%/}")"
  case "$cand_lc/" in
    "$protected_lc"/* | "$protected_lc"/) return 1 ;;
  esac
  prefix=""
  rest="${candidate#/}"
  while [ -n "$rest" ]; do
    case "$rest" in
      */*)
        base="${rest%%/*}"
        rest="${rest#*/}"
        ;;
      *)
        base="$rest"
        rest=""
        ;;
    esac
    [ -n "$base" ] || continue
    parent="${prefix:-/}"
    prefix="$prefix/$base"
    if [ -n "$protected_id" ]; then
      id="$(node_id "$prefix")" || {
        [ "$?" -eq 1 ] || return 1
        id=""
      }
      [ -z "$id" ] || [ "$id" != "$protected_id" ] || return 1
    fi
    if [ -n "$protected_parent_id" ] && [ "$(lower "$base")" = "$protected_name_lc" ]; then
      id="$(node_id "$parent")" || {
        [ "$?" -eq 1 ] || return 1
        id=""
      }
      [ -z "$id" ] || [ "$id" != "$protected_parent_id" ] || return 1
    fi
  done
  return 0
}

source_mix_home="$(resolve_physical "$loopex_m1_source_mix_home_input")"
[ -n "$source_mix_home" ] \
  || fail "the installed Mix-prerequisite root could not be resolved physically"
source_hex_packages="$real_home/.hex/packages"
task_tmp_root="$loopex_m1_task_tmp_input"
for inherited in \
  "$repository_root" \
  "$task_tmp_root" \
  "$source_mix_home" \
  "$source_hex_packages" \
  "$loopex_m1_mix_directory" \
  "$loopex_m1_elixir_directory" \
  "$loopex_m1_erl_directory" \
  "$loopex_m1_mix_directory/mix" \
  "$loopex_m1_elixir_directory/elixir" \
  "$loopex_m1_erl_directory/erl"
do
  outside_protected_state "$inherited" \
    || fail "$inherited is inside the protected user state directory; refusing to run"
done

if [ "$gate_role" = environment-fixture ]; then
  environment_fixture_output="$(
    /usr/bin/env
    environment_fixture_status=$?
    builtin printf '\035LOOPEX_M1_ENV_FIXTURE_STATUS_V1:%s' "$environment_fixture_status"
  )"
  case "$environment_fixture_output" in
    *$'\035LOOPEX_M1_ENV_FIXTURE_STATUS_V1:0')
      environment_fixture_output="${environment_fixture_output%$'\035LOOPEX_M1_ENV_FIXTURE_STATUS_V1:0'}"
      ;;
    *) fail "the canonical environment fixture could not be captured" ;;
  esac
  environment_fixture_output="$environment_fixture_output"\
"M1 environment preflight OK os=$runtime_os arch=$runtime_arch locale=$locale_charmap stat=$stat_style sha256=$sha256_style limits=$runtime_limits"$'\n'
  emit_gate_output stdout "$environment_fixture_output" \
    || fail "environment fixture output collides with provider credential bytes"
  builtin exit 0
fi

plan="docs/plans/M1.md"
gate="docs/plans/M1-gate.md"
[ -f "$plan" ] || fail "no $plan; the gate has no plan to enforce"
[ -f "$gate" ] || fail "no $gate; the gate has no locked text"
[ -f mix.exs ] || fail "no umbrella project at mix.exs"

require_named_test() {
  local file="$1" name="$2"
  [ -f "$file" ] || fail "no $file; the outcome it proves does not exist yet"
  require_tracked_regular "$file" "protected selector"
  grep -qF "test \"${name}\"" "$file" \
    || fail "$file does not define the locked test \"$name\""
}

require_tracked_regular() {
  local file="$1" label="$2" entry mode rest object stage tracked
  local path_rest component prefix=""
  [ -f "$file" ] && [ ! -L "$file" ] \
    || fail "$label $file is not an ordinary regular file"
  path_rest="$file"
  while [ -n "$path_rest" ]; do
    case "$path_rest" in
      */*)
        component="${path_rest%%/*}"
        path_rest="${path_rest#*/}"
        ;;
      *)
        component="$path_rest"
        path_rest=""
        ;;
    esac
    prefix="${prefix:+$prefix/}$component"
    [ ! -L "$prefix" ] || fail "$label $file crosses a symlink component"
  done

  entry="$(git ls-files --stage -- "$file")" \
    || fail "$label $file is unavailable from the candidate index"
  case "$entry" in
    "" | *$'\n'*) fail "$label $file does not have one candidate index entry" ;;
  esac
  mode="${entry%% *}"
  rest="${entry#* }"
  object="${rest%% *}"
  rest="${rest#* }"
  case "$rest" in
    *$'\t'*)
      stage="${rest%%$'\t'*}"
      tracked="${rest#*$'\t'}"
      ;;
    *) fail "$label $file has a malformed candidate index entry" ;;
  esac
  [ "$mode" = 100644 ] && [ "$stage" = 0 ] && [ "$tracked" = "$file" ] &&
    [[ "$object" =~ ^[0-9a-f]+$ ]] \
    || fail "$label $file is not one tracked ordinary 100644 blob"
}

require_real_provider_test() {
  local file="$1" name="$2"
  awk -v name="$name" '
    /^[[:space:]]*@tag[[:space:]]+:real_provider[[:space:]]*$/ { tagged = 1; next }
    /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (tagged && index(line, "test \"" name "\"") == 1) found = 1
      tagged = 0
    }
    END { exit(found ? 0 : 1) }
  ' "$file" || fail "$file does not tag the locked test \"$name\" as real_provider"
}

# READ-ONLY PREFLIGHT. Do not move allocation or a Mix command above this block.
# The first absent selector is the declared opening red condition.
require_named_test apps/loopex/test/runtime_test.exs \
  "two runtimes coexist without a global name"
require_named_test apps/loopex/test/runtime_test.exs \
  "a runtime reference is required rather than inferred"
require_named_test apps/loopex/test/runtime_test.exs \
  "a supervised runtime starts and stops with explicit configuration"

require_named_test apps/loopex/test/session_lifecycle_test.exs \
  "session creation atomically records its runtime command mapping and genesis re-presents identical bytes idempotently and conflicts on changed bytes"
require_named_test apps/loopex/test/session_lifecycle_test.exs \
  "initial and resumed coordinators commit advance_owner before admitting commands"
require_named_test apps/loopex/test/session_lifecycle_test.exs \
  "a superseded owner cannot newly commit or use a delayed result to update cache publish dispatch or authorize"
require_named_test apps/loopex/test/session_lifecycle_test.exs \
  "declared injected and observed transition and fault point pairs are equal"
require_named_test apps/loopex/test/session_lifecycle_test.exs \
  "a prompt cannot start a second active run"
require_named_test apps/loopex/test/session_lifecycle_test.exs \
  "only one coordinator owns a session at a time after durable succession"

require_named_test apps/loopex_store_local/test/store_conformance_test.exs \
  "every implementation atomically refuses a stale owner epoch incarnation and version"
require_named_test apps/loopex_store_local/test/store_conformance_test.exs \
  "a killed writer loses no acknowledged fact"
require_named_test apps/loopex_store_local/test/store_conformance_test.exs \
  "replay audits durable truth but grants no write authority"
require_named_test apps/loopex_store_local/test/store_conformance_test.exs \
  "known transactions return their retained resolution without a second mutation"
require_named_test apps/loopex_store_local/test/store_conformance_test.exs \
  "the durable local store survives process death with consecutive store-stamped history"

require_named_test apps/loopex/test/embedded_api_test.exs \
  "progress and diagnostics never carry durable truth"
require_named_test apps/loopex/test/embedded_api_test.exs \
  "committed events survive delivery with stable identity"
require_named_test apps/loopex/test/embedded_api_test.exs \
  "attachment snapshots at N and streams events after N without a gap"
require_named_test apps/loopex/test/embedded_api_test.exs \
  "a full attachment queue disconnects with a durable-history cursor and resumes gap-free after runtime restart without persisted attachment state"

require_named_test apps/loopex_llm_reqllm/test/real_model_lane_test.exs \
  "deterministic and ReqLLM adapters satisfy one model conformance suite"
require_named_test apps/loopex_reference_client/test/real_model_session_test.exs \
  "model dispatch receives only the committed canonical request bytes and digest"
require_named_test apps/loopex_reference_client/test/real_model_session_test.exs \
  "one real non-streaming model call receives the committed canonical request bytes and digest and completes inside a session"
require_real_provider_test apps/loopex_reference_client/test/real_model_session_test.exs \
  "one real non-streaming model call receives the committed canonical request bytes and digest and completes inside a session"

require_named_test apps/loopex_executor_local/test/executor_test.exs \
  "required grant bindings equal the independent contract oracle"
require_named_test apps/loopex_executor_local/test/executor_test.exs \
  "each missing and wrong grant binding is refused before process start"
require_named_test apps/loopex_executor_local/test/executor_test.exs \
  "only an explicit host-policy allow decision can issue or widen a grant"
require_named_test apps/loopex_executor_local/test/executor_test.exs \
  "the executor recomputes the canonical JobRequest digest and the receipt retains verified origin identity"
require_named_test apps/loopex_executor_local/test/executor_test.exs \
  "the workspace lease is held for the job lifetime and loss kills owned work with retained evidence"
require_named_test apps/loopex_executor_local/test/executor_test.exs \
  "the executor starts one credential-free OS tool that writes the expected workspace bytes and retains its receipt"

require_named_test apps/loopex_reference_client/test/reference_client_test.exs \
  "the client drives the loop through the embedded API only"
require_named_test apps/loopex_reference_client/test/reference_client_test.exs \
  "the reference client owns no policy durable state or alternate loop"

require_named_test apps/loopex_reference_client/test/end_to_end_recovery_test.exs \
  "one real-provider trace forces a credential-free tool survives an untrappable runtime-tree kill after receipt before fact reconciles one effect without redispatch preserves its fact and completes a second real call"
require_real_provider_test apps/loopex_reference_client/test/end_to_end_recovery_test.exs \
  "one real-provider trace forces a credential-free tool survives an untrappable runtime-tree kill after receipt before fact reconciles one effect without redispatch preserves its fact and completes a second real call"
require_named_test apps/loopex_reference_client/test/end_to_end_recovery_test.exs \
  "reconciliation schema covers the independent recovery contract oracle"
require_named_test apps/loopex_reference_client/test/end_to_end_recovery_test.exs \
  "exactly one dispatch ever carried each effect across the restart"
require_named_test apps/loopex_reference_client/test/end_to_end_recovery_test.exs \
  "an effect without a durable receipt becomes outcome_unknown and is not blindly retried"
require_named_test apps/loopex_reference_client/test/end_to_end_recovery_test.exs \
  "every acknowledged fact survives the restart"
require_named_test apps/loopex_reference_client/test/end_to_end_recovery_test.exs \
  "each wrong reconciliation and receipt identity is refused"

require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "M1 pair verifier derives only the exact running locked pair"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "M1 evidence verifier requires one exact capture and inherited M0 proof per locked lane"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "M1 evidence verifier binds source evidence and closure transition ancestry"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "M1 evidence verifier binds each negative mechanism to committed and restored bytes"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "the environment preflight removes credential aliases and unrelated ambient state"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "the read-only prefix disables optional Git locks before repository inspection"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "the user-state fingerprint includes every entry identity and a command-line symlink target root"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "prerequisite copies refuse protected-state hard links and symlinks"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "platform filesystem identity and SHA-256 select validated dialects"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "owned candidate and generated closures exclude ambient aliases"

require_named_test apps/loopex/test/m1_exunit_runner_test.exs \
  "the standalone selector grammar admits every planned owner and rejects foreign paths"
require_named_test apps/loopex/test/m1_exunit_runner_test.exs \
  "the standalone runner requires one tracked ordinary selector owned by its compiled app"
require_named_test apps/loopex/test/m1_exunit_runner_test.exs \
  "official counts and exact events refuse failures skips exclusions and missing names"
require_named_test apps/loopex/test/m1_exunit_runner_test.exs \
  "fake stdout at_exit and early halt cannot manufacture one authoritative result"
require_named_test apps/loopex/test/m1_exunit_runner_test.exs \
  "only the declared internal dependency closure is reachable and startup never receives the provider key"

require_named_test apps/loopex/test/deps_budget_test.exs \
  "the repository satisfies the dependency budget and direction"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "a forbidden core dependency is rejected"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "an extension may carry external dependencies but not the runtime"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "dependency identity and role come only from the canonical project declaration"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "internal dependencies cannot redirect canonical umbrella source ownership"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "compiled source roots remain inside their owning application"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "duplicate dependency names are rejected"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "the tracked inventory is dynamic and includes its ordinary root"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "the dynamic inventory cannot omit the fixed contract or core"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "unrelated project metadata helpers application data and ordinary aliases are permitted"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "root and child aliases may not interpose on locked commands"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "M1 planned applications accept only their declared dependency shapes"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "dependency context separates discovered apps from the selector's declared closure"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "each role rejects an adjacent outward or wrong-environment edge"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "child identity must match its directory and decoys cannot supply it"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "an extra guarded project clause cannot hide behind one literal clause"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "the bound dependency verdict bypasses evaluated Mix tasks"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "offline materializer proves the exact floor-compatible lock closure"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "the contract protocol namespace is not a runtime reverse edge"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "static runtime references outside the protocol namespace are rejected"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "a reverse edge from contract to runtime is rejected"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "dynamic module dispatch is rejected independent of formatting"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "a dynamic module reference across the boundary is rejected"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "plain module-like data is not treated as an executable reference"
require_named_test apps/loopex/test/deps_budget_test.exs \
  "all declared contract compile roots receive reverse-edge checks"

# The standalone selector and evidence programs plus the one dependency-policy
# authority are the M1-specific trust root. Verify their tracked ordinary bytes
# before loading them. The runner itself is bound by the gate document and cannot
# carry its own digest without a self-reference. Product Mix files remain source
# candidate bytes and are discovered and checked structurally on every run.
require_bound_artifact() {
  local file="$1" expected="$2" label="$3" actual
  require_tracked_regular "$file" "$label"
  actual="$(sha256_file "$file")" \
    || fail "$label digest is unavailable"
  [ "$actual" = "$expected" ] \
    || fail "$label changed after gate acceptance"
}

selector_runner_source="scripts/m1-exunit-runner.exs"
evidence_verifier_source="scripts/m1-evidence-verifier.exs"
gate_launcher_source="scripts/m1-gate-launcher.escript"
deps_budget_source="apps/loopex/lib/mix/tasks/loopex.deps_budget.ex"
require_bound_artifact "$gate_launcher_source" \
  4bba03d218eee656991444a3c22c8753bfef1ab86f688036a4440048752f48bd \
  "bound sealed gate launcher"
require_bound_artifact "$selector_runner_source" \
  6aa177be0672179cb0713a7e73ccf54a52fa4dc957d5e7d00e3e514d5015f8c2 \
  "bound standalone selector runner"
require_bound_artifact "$evidence_verifier_source" \
  360ed080598e757d03fc33ac003f24cc2bb787de423f8df4bc62d1d77221572c \
  "bound M1 evidence verifier"
require_bound_artifact apps/loopex/lib/mix/tasks/loopex.deps_budget.ex \
  1b9d41d083ace5f39ac9af0c289065d9eb52aea129d04c174b1acc63d33b6861 \
  "bound dependency-direction reader"
require_bound_artifact apps/loopex/test/m1_gate_evidence_test.exs \
  87172408ac43f325d0e13e5228fd2cec41a4d193d5359e0838a47a8140b67a7d \
  "bound M1 mechanics corpus"
require_bound_artifact apps/loopex/test/m1_exunit_runner_test.exs \
  558544b6ac08c8fe814d00e315594e33a07eeee2220aad0f8659b909371cd00b \
  "bound selector-runner corpus"
require_bound_artifact apps/loopex/test/deps_budget_test.exs \
  36d86e989d39507b971c3be6726d300373ceebc2c80b2574a21fd2d32604d750 \
  "bound dependency-direction corpus"
require_bound_artifact .tool-versions \
  fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999 \
  "bound toolchain pair record"

project_config_output="$(git ls-files -- 'mix.exs' 'apps/*/mix.exs')" \
  || fail "the umbrella project inventory is unavailable"
[ -n "$project_config_output" ] || fail "the umbrella project inventory is empty"
project_configs=()
project_config_rest="$project_config_output"
project_config_root_count=0
while [ -n "$project_config_rest" ]; do
  case "$project_config_rest" in
    *$'\n'*)
      project_config="${project_config_rest%%$'\n'*}"
      project_config_rest="${project_config_rest#*$'\n'}"
      ;;
    *)
      project_config="$project_config_rest"
      project_config_rest=""
      ;;
  esac
  if [ "$project_config" = mix.exs ]; then
    project_config_root_count=$((project_config_root_count + 1))
  elif [[ "$project_config" =~ ^apps/[a-z][a-z0-9_]*/mix\.exs$ ]]; then
    :
  else
    fail "the umbrella project inventory contains a noncanonical path"
  fi
  require_tracked_regular "$project_config" "umbrella project configuration"
  project_configs+=("$project_config")
done
[ "$project_config_root_count" -eq 1 ] \
  || fail "the umbrella project inventory must contain exactly one root mix.exs"
tree_state="$(git status --porcelain=v1 --untracked-files=all)" \
  || fail "working-tree state is unavailable"
[ -z "$tree_state" ] \
  || fail "the gate requires a clean whole tree; retained evidence cannot bind a dirty run"
source_candidate="$(git rev-parse --verify 'HEAD^{commit}')" \
  || fail "the source candidate commit is unavailable"
[[ "$source_candidate" =~ ^[0-9a-f]{40}$ ]] \
  || fail "the source candidate is not one full lowercase commit SHA"
gate_sha256="$(sha256_file "$gate")" \
  || fail "the M1 gate digest is unavailable"
[[ "$gate_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || fail "the M1 gate digest is malformed"

command -v mix >/dev/null 2>&1 \
  || fail "mix is not installed; the accepted toolchain is required"

# The writable lane starts here. Each invocation owns its candidate checkout and
# every mutable Mix/dependency path. The exact committed candidate is checked out
# with no local hard links; ignored physical paths and ambient repository `deps/`
# therefore cannot enter the build. Dependency source is reconstructed below
# only from package archives whose SHA-256 is bound by this candidate's mix.lock.
source_repository_root="$repository_root"
isolated_root="$(mktemp -d "$task_tmp_root/loopex-m1-task.XXXXXX")" \
  || fail "could not create an isolated task root"
isolated_root="$(resolve_physical "$isolated_root")"
[ -n "$isolated_root" ] \
  || fail "the isolated task root could not be resolved physically"
trap 'rm -rf "$isolated_root"' EXIT

export MIX_HOME="$isolated_root/mix-home"
export HEX_HOME="$isolated_root/hex-home"
export MIX_BUILD_PATH="$isolated_root/build/dev"
test_build_path="$isolated_root/build/test"
export MIX_DEPS_PATH="$isolated_root/deps"
export REBAR_CACHE_DIR="$isolated_root/rebar-cache"
export HEX_OFFLINE=1
export ERL_CRASH_DUMP=/dev/null
export ERL_CRASH_DUMP_SECONDS=0
export TMPDIR="$isolated_root/tmp"
export HOME="$isolated_root/home"
export LOOPEX_HOME="$isolated_root/home/$user_state_dirname"
export LOOPEX_WORKSPACE="$isolated_root/workspace"
mkdir -p \
  "$HOME" \
  "$MIX_HOME" \
  "$HEX_HOME" \
  "$LOOPEX_HOME" \
  "$LOOPEX_WORKSPACE" \
  "$MIX_DEPS_PATH" \
  "$REBAR_CACHE_DIR" \
  "$TMPDIR"
protected_file_ids="$isolated_root/protected-file-ids"

manifest_record() {
  # Filesystem names and symlink targets cannot contain NUL. Hash a NUL-framed
  # tuple of every field, using a content/target digest as the final fixed-width
  # field, so newlines, tabs, backslashes, and delimiter-like names remain
  # injective. The manifest then sorts only fixed-width record digests.
  builtin printf '%s\0%s\0%s\0%s\0%s\0' "$1" "$2" "$3" "$4" "$5" \
    | sha256_stream
}

# `find -H` traverses a command-line symlink, but the root entry it emits is
# still the link path. Record the fully resolved root separately so a target
# directory mode/identity change or a target-file content change cannot hide
# behind unchanged link metadata.
root_target_record() {
  local source="$1" target mode identity type payload
  [ -L "$source" ] || return 0
  target="$(resolve_physical "$source")"
  [ -n "$target" ] || return 1
  mode="$(entry_mode "$target")" || return 1
  identity="$(node_id "$target")" || return 1
  if [ -f "$target" ]; then
    type=root-target-file
    payload="$(sha256_file "$target")" || return 1
  elif [ -d "$target" ]; then
    type=root-target-directory
    payload=-
  else
    type=root-target-other
    payload=-
  fi
  manifest_record "$target" "$type" "$mode" "$identity" "$payload"
}

# Defense in depth records paths, types, permission modes, symlink targets, and
# regular-file contents. Capture the baseline before any prerequisite inventory,
# copy, or other writable-lane child can observe or mutate real user state.
real_user_state() {
  local entries="$isolated_root/user-state.entries"
  local manifest="$isolated_root/user-state.manifest"
  local protected_ids_raw="$isolated_root/protected-file-ids.raw"
  local entry relative mode identity type payload target
  : > "$protected_file_ids"
  : > "$protected_ids_raw"
  if [ ! -e "$real_user_state_path" ] && [ ! -L "$real_user_state_path" ]; then
    printf '%s' absent
    return 0
  fi
  # -H follows a command-line symlink while shell `-L` still records that root
  # link's own target and mode. Both the alias and the target tree are therefore
  # fingerprinted.
  find -H "$real_user_state_path" -print0 > "$entries" || return 1
  : > "$manifest"
  root_target_record "$real_user_state_path" >> "$manifest" || return 1
  if [ -L "$real_user_state_path" ]; then
    target="$(resolve_physical "$real_user_state_path")" || return 1
    if [ -f "$target" ]; then
      node_id "$target" >> "$protected_ids_raw" || return 1
    fi
  fi
  while IFS= read -r -d '' entry; do
    relative="${entry#"$real_user_state_path"}"
    mode="$(entry_mode "$entry")" || return 1
    identity="$(node_id "$entry")" || return 1
    if [ -L "$entry" ]; then
      type=symlink
      payload="$(readlink "$entry" | sha256_stream)" || return 1
    elif [ -f "$entry" ]; then
      type=file
      payload="$(sha256_file "$entry")" || return 1
      printf '%s\n' "$identity" >> "$protected_ids_raw" || return 1
    elif [ -d "$entry" ]; then
      type=directory
      payload=-
    else
      type=other
      payload=-
    fi
    manifest_record "$relative" "$type" "$mode" "$identity" "$payload" \
      >> "$manifest" || return 1
  done < "$entries"
  LC_ALL=C sort -u "$protected_ids_raw" > "$protected_file_ids" || return 1
  LC_ALL=C sort "$manifest" | sha256_stream
}

user_state_before="$(real_user_state)" \
  || fail "real user state could not be fingerprinted; containment evidence is unavailable"

# Every source that will be traversed or copied is checked by physical identity,
# including a command-line symlink and every descendant symlink. Validation and
# copying are adjacent under the ordinary non-hostile-concurrent-mutation
# assumption; this gate does not claim a filesystem handle or cross-process lock.
refuse_protected_file_aliases() {
  local inventory="$1" label="$2"
  local identities="$isolated_root/file-identities-$source_validation_index.raw"
  local sorted="$isolated_root/file-identities-$source_validation_index.sorted"
  local overlap="$isolated_root/file-identities-$source_validation_index.overlap"
  local entry identity
  : > "$identities"
  while IFS= read -r -d '' entry; do
    if [ -f "$entry" ]; then
      identity="$(node_id "$entry")" \
        || fail "$label contains a regular file whose identity is unavailable"
      printf '%s\n' "$identity" >> "$identities" \
        || fail "$label file identity inventory could not be written"
    fi
  done < "$inventory"
  LC_ALL=C sort -u "$identities" > "$sorted" \
    || fail "$label file identity inventory could not be sorted"
  LC_ALL=C comm -12 "$protected_file_ids" "$sorted" > "$overlap" \
    || fail "$label could not be compared with protected user-state files"
  [ ! -s "$overlap" ] \
    || fail "$label contains a regular-file hard-link alias of protected user state"
}

validate_source_tree() {
  local source="$1" label="$2" inventory entry
  [ -e "$source" ] || [ -L "$source" ] \
    || fail "$label is unavailable"
  outside_protected_state "$source" \
    || fail "$label aliases the protected user state directory"
  inventory="$isolated_root/source-$source_validation_index.entries"
  source_validation_index=$((source_validation_index + 1))
  find -P "$source" -print0 > "$inventory" \
    || fail "$label could not be inventoried before use"
  while IFS= read -r -d '' entry; do
    [ ! -L "$entry" ] \
      || fail "$label contains a symlink and cannot become isolated owned input"
    outside_protected_state "$entry" \
      || fail "$label contains a protected-state descendant"
    [ -f "$entry" ] || [ -d "$entry" ] \
      || fail "$label contains a special filesystem entry"
  done < "$inventory"
  refuse_protected_file_aliases "$inventory" "$label"
}

generated_target_allowed() {
  local target
  target="$(resolve_physical "$1")"
  [ -n "$target" ] || return 1
  case "${target%/}/" in
    "${isolated_root%/}/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Mix may intentionally create `priv` or source links in its owned build. Walk
# the complete resolved directory closure without `find -L`: every link target
# must remain inside the invocation-owned task root, cycles are broken by
# physical directory identity, and every reachable regular file is compared
# with the protected-state identity set.
validate_generated_tree() {
  local source="$1" label="$2" root queue visited inventory regulars
  local scan_root directory_id entry target
  [ -e "$source" ] || [ -L "$source" ] \
    || fail "$label is unavailable"
  outside_protected_state "$source" \
    || fail "$label aliases the protected user state directory"
  root="$(resolve_physical "$source")"
  [ -n "$root" ] && [ -d "$root" ] \
    || fail "$label has no ordinary resolved directory root"
  generated_target_allowed "$root" \
    || fail "$label leaves the isolated task root"

  queue="$isolated_root/generated-$source_validation_index.queue"
  visited="$isolated_root/generated-$source_validation_index.visited"
  inventory="$isolated_root/generated-$source_validation_index.entries"
  regulars="$isolated_root/generated-$source_validation_index.regulars"
  source_validation_index=$((source_validation_index + 1))
  : > "$visited"
  : > "$regulars"
  builtin printf '%s\0' "$root" > "$queue" \
    || fail "$label traversal queue could not be created"

  exec 7< "$queue" || fail "$label traversal queue could not be opened"
  while IFS= read -r -d '' scan_root <&7; do
    directory_id="$(node_id "$scan_root")" \
      || fail "$label contains a directory whose identity is unavailable"
    if grep -Fqx "$directory_id" "$visited"; then
      continue
    fi
    builtin printf '%s\n' "$directory_id" >> "$visited" \
      || fail "$label visited-directory inventory could not be written"
    find -P "$scan_root" -print0 > "$inventory" \
      || fail "$label could not be inventoried after generation"
    while IFS= read -r -d '' entry; do
      outside_protected_state "$entry" \
        || fail "$label contains a protected-state link or descendant"
      if [ -L "$entry" ]; then
        target="$(resolve_physical "$entry")"
        [ -n "$target" ] && { [ -f "$target" ] || [ -d "$target" ]; } \
          || fail "$label contains a dangling or special link"
        generated_target_allowed "$target" \
          || fail "$label contains a link outside the isolated task root"
        outside_protected_state "$target" \
          || fail "$label contains a link to protected user state"
        if [ -f "$target" ]; then
          builtin printf '%s\0' "$target" >> "$regulars" \
            || fail "$label regular-target inventory could not be written"
        else
          builtin printf '%s\0' "$target" >> "$queue" \
            || fail "$label traversal queue could not be extended"
        fi
      elif [ -f "$entry" ]; then
        builtin printf '%s\0' "$entry" >> "$regulars" \
          || fail "$label regular-file inventory could not be written"
      elif [ ! -d "$entry" ]; then
        fail "$label contains a special filesystem entry"
      fi
    done < "$inventory"
  done
  exec 7<&-
  refuse_protected_file_aliases "$regulars" "$label"
}

source_validation_index=0

# Execute candidate code only from an owned checkout of the exact clean source
# commit. A local clone is deliberately non-hardlinked and checks out no ambient
# ignored path, repository metadata helper, or dependency source tree.
candidate_checkout="$isolated_root/repository"
git clone --quiet --no-hardlinks --no-checkout -- \
  "$source_repository_root" "$candidate_checkout" \
  || fail "the owned candidate repository could not be created"
git -C "$candidate_checkout" checkout --quiet --detach "$source_candidate" \
  || fail "the exact source candidate could not be checked out"
repository_root="$(resolve_physical "$candidate_checkout")"
[ -n "$repository_root" ] && [ -d "$repository_root" ] \
  || fail "the owned candidate checkout is unavailable"
cd -- "$repository_root" || fail "the owned candidate checkout could not be entered"
[ "$(git rev-parse --verify 'HEAD^{commit}')" = "$source_candidate" ] \
  || fail "the owned candidate checkout resolved to another commit"
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] \
  || fail "the owned candidate checkout is not clean"

elixir -r "$repository_root/$deps_budget_source" \
  -e 'Loopex.Checks.DepsBudget.main(System.argv())' -- "${project_configs[@]}" \
  || fail "the umbrella project inventory violates its role or dependency contract"

elixir -r "$repository_root/$deps_budget_source" \
  -e 'Loopex.Checks.DepsBudget.main(System.argv())' -- \
  --materialize "$source_hex_packages" "$MIX_DEPS_PATH" "$protected_file_ids" \
  || fail "lock-bound dependency source could not be materialized offline"
validate_source_tree "$MIX_DEPS_PATH" "the lock-bound dependency source tree"

# A clean Git tree can still carry an intentional tracked symlink. Reject one in
# executable build/test inputs; documentation/client-adapter symlinks that Mix
# never traverses are outside this copy boundary. The separately ignored
# dependency tree is validated immediately before it is copied below.
tracked_sources="$isolated_root/tracked-sources.entries"
git ls-files -z > "$tracked_sources" \
  || fail "tracked build inputs could not be inventoried"
while IFS= read -r -d '' tracked_source; do
  case "$tracked_source" in
    apps/* | config/* | mix.exs | mix.lock | .formatter.exs | VERSION)
      [ ! -L "$tracked_source" ] \
        || fail "the tracked build input $tracked_source is a symlink"
      ;;
  esac
done < "$tracked_sources"

# Hex and Rebar are accepted external build-tool prerequisites, but their ambient
# homes are mutable shared state. Snapshot only installed Hex tooling and the
# per-Elixir Rebar subtree. Package source has already been reconstructed from
# the exact checksum-bound cache archives; no ambient `deps/` tree is consulted.
mkdir -p "$MIX_HOME/archives" "$MIX_HOME/elixir"
validate_source_tree "$source_mix_home/archives" "the installed Mix archives directory"
hex_archive_count=0
for hex_archive in "$source_mix_home"/archives/hex-*; do
  [ -e "$hex_archive" ] || continue
  validate_source_tree "$hex_archive" "the installed Hex archive $hex_archive"
  cp -RL "$hex_archive" "$MIX_HOME/archives/" \
    || fail "could not snapshot the installed Hex archive"
  validate_source_tree "$MIX_HOME/archives/${hex_archive##*/}" \
    "the isolated Hex archive ${hex_archive##*/}"
  hex_archive_count=$((hex_archive_count + 1))
done
[ "$hex_archive_count" -ge 1 ] \
  || fail "no installed Hex archive is available for the isolated task root"
[ -d "$source_mix_home/elixir" ] \
  || fail "no installed per-Elixir Rebar subtree is available"
validate_source_tree "$source_mix_home/elixir" "the installed per-Elixir Rebar subtree"
cp -RL "$source_mix_home/elixir/." "$MIX_HOME/elixir/" \
  || fail "could not snapshot the installed per-Elixir Rebar subtree"
validate_source_tree "$MIX_HOME/elixir" "the isolated per-Elixir Rebar subtree"

# One seed covers every direct ExUnit run made by this gate. The final verdict
# prints it together with the authoritative protected-outcome count so retained
# matrix rows can be cross-checked against this invocation rather than guessed
# from human-readable test output.
gate_seed="${loopex_m1_gate_seed_input:-$RANDOM}"
export -n gate_seed 2>/dev/null \
  || fail "the gate seed holding variables could not be made private"
valid_gate_seed() { [[ "$1" =~ ^(0|[1-9][0-9]{0,5})$ ]]; }
valid_gate_seed "$gate_seed" \
  || fail "LOOPEX_GATE_SEED must be an integer from 0 through 999999"
protected_executed=0
last_gate_executed=0
last_gate_real_profile=""
last_gate_provider=""
last_gate_model=""
last_gate_endpoint=""
last_gate_adapter_build=""
last_gate_executor_build=""
last_gate_executor_identity=""
last_gate_tool_identity=""
last_gate_recorded=""

# The bound standalone script, not Mix task/alias dispatch or arbitrary stdout,
# owns selector truth. It reads its one-use nonce and optional provider key before
# candidate application startup, derives only the owning compiled dependency
# closure, collects official ExUnit stats plus exact events, emits one nonce-bound
# marker, and hard-halts before System.at_exit callbacks.
run_gate_test() {
  local role="$1" file="$2" minimum="$3" exclusion_policy="$4" accumulate="$5"
  local nonce output output_rest gate_test_status report_count=0 marker=""
  local line prefix rest executed suffix context_output context_owner context_internal
  local context_allowed terminal_prefix terminal_status terminal_suffix
  shift 5

  validate_generated_tree "$test_build_path" \
    "the compiled test application tree before selector consumption"

  context_output="$(
    elixir -r "$repository_root/$deps_budget_source" \
      -e 'Loopex.Checks.DepsBudget.main(System.argv())' -- \
      --context "$file" "${project_configs[@]}"
  )" || fail "$file has no authoritative application dependency context"
  if [[ "$context_output" =~ ^LOOPEX_DEPENDENCY_CONTEXT\ owner=([a-z][a-z0-9_]*)\ internal=([a-z][a-z0-9_]*(,[a-z][a-z0-9_]*)*)\ allowed=([a-z][a-z0-9_]*(,[a-z][a-z0-9_]*)*)$ ]]; then
    context_owner="${BASH_REMATCH[1]}"
    context_internal="${BASH_REMATCH[2]}"
    context_allowed="${BASH_REMATCH[4]}"
  else
    fail "$file produced a malformed application dependency context"
  fi

  nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" \
    || fail "could not create an authoritative test-result nonce"
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] \
    || fail "the authoritative test-result nonce is malformed"

  set +e
  case "$role" in
    default)
      output="$(
        builtin printf 'LOOPEX_M1_SELECTOR_V1\0%s\0\0' "$nonce" \
          | elixir "$repository_root/$selector_runner_source" \
              --loopex-m1-selector "$repository_root" "$test_build_path" \
              "$file" "$context_owner" "$context_internal" "$context_allowed" \
              "$gate_seed" "$minimum" "$exclusion_policy" "$@" 2>&1
        loopex_m1_pipeline_status="${PIPESTATUS[1]}"
        builtin printf '\036LOOPEX_M1_SELECTOR_STATUS_V1:%s:%s' \
          "$nonce" "$loopex_m1_pipeline_status"
      )"
      ;;
    real-model)
      output="$(
        builtin printf 'LOOPEX_M1_SELECTOR_V1\0%s\0%s\0' "$nonce" "$provider_key_value" \
          | elixir "$repository_root/$selector_runner_source" \
              --loopex-m1-selector --only-real-provider --real-path model \
              "$repository_root" "$test_build_path" "$file" \
              "$context_owner" "$context_internal" "$context_allowed" \
              "$gate_seed" "$minimum" "$exclusion_policy" "$@" 2>&1
        loopex_m1_pipeline_status="${PIPESTATUS[1]}"
        builtin printf '\036LOOPEX_M1_SELECTOR_STATUS_V1:%s:%s' \
          "$nonce" "$loopex_m1_pipeline_status"
      )"
      ;;
    real-combined)
      output="$(
        builtin printf 'LOOPEX_M1_SELECTOR_V1\0%s\0%s\0' "$nonce" "$provider_key_value" \
          | elixir "$repository_root/$selector_runner_source" \
              --loopex-m1-selector --only-real-provider --real-path combined \
              "$repository_root" "$test_build_path" "$file" \
              "$context_owner" "$context_internal" "$context_allowed" \
              "$gate_seed" "$minimum" "$exclusion_policy" "$@" 2>&1
        loopex_m1_pipeline_status="${PIPESTATUS[1]}"
        builtin printf '\036LOOPEX_M1_SELECTOR_STATUS_V1:%s:%s' \
          "$nonce" "$loopex_m1_pipeline_status"
      )"
      ;;
    *)
      set -e
      fail "the authoritative test-result role is unknown"
      ;;
  esac
  set -e

  terminal_prefix=$'\036'"LOOPEX_M1_SELECTOR_STATUS_V1:$nonce:"
  case "$output" in
    *"$terminal_prefix"*) terminal_status="${output##*"$terminal_prefix"}" ;;
    *) fail "$file produced a malformed terminal selector status" ;;
  esac
  [[ "$terminal_status" =~ ^(0|[1-9][0-9]{0,2})$ ]] &&
    [ "$terminal_status" -le 255 ] \
    || fail "$file produced a malformed terminal selector status"
  terminal_suffix="$terminal_prefix$terminal_status"
  case "$output" in
    *"$terminal_suffix") output="${output%"$terminal_suffix"}" ;;
    *) fail "$file produced a malformed terminal selector status" ;;
  esac
  gate_test_status="$terminal_status"

  if [ "$role" != default ] && [ -n "$provider_key_value" ]; then
    case "$output" in
      *"$provider_key_value"*)
        fail "$file emitted provider credential bytes instead of contained evidence"
        ;;
    esac
  fi

  output_rest="$output"
  while [ -n "$output_rest" ]; do
    case "$output_rest" in
      *$'\n'*)
        line="${output_rest%%$'\n'*}"
        output_rest="${output_rest#*$'\n'}"
        ;;
      *)
        line="$output_rest"
        output_rest=""
        ;;
    esac
    case "$line" in
      LOOPEX_EXUNIT_REPORT\ *)
        report_count=$((report_count + 1))
        marker="$line"
        ;;
    esac
  done

  if [ "$gate_test_status" -ne 0 ] || [ "$report_count" -ne 1 ]; then
    if [ "$role" != default ]; then
      redacted "$output" >&2 \
        || fail "$file diagnostic collides with provider credential bytes"
    else
      emit_gate_output stderr "$output"$'\n' \
        || fail "$file diagnostic collides with provider credential bytes"
    fi
    fail "$file did not produce exactly one successful authoritative ExUnit report"
  fi

  prefix="LOOPEX_EXUNIT_REPORT nonce=$nonce selector=$file seed=$gate_seed executed="
  case "$marker" in
    "$prefix"*) rest="${marker#"$prefix"}" ;;
    *) fail "$file produced an authoritative report for another invocation" ;;
  esac
  executed="${rest%% *}"
  suffix="${rest#"$executed"}"
  [[ "$executed" =~ ^[1-9][0-9]*$ ]] \
    || fail "$file produced a malformed authoritative executed count"
  last_gate_real_profile=""
  last_gate_provider=""
  last_gate_model=""
  last_gate_endpoint=""
  last_gate_adapter_build=""
  last_gate_executor_build=""
  last_gate_executor_identity=""
  last_gate_tool_identity=""
  last_gate_recorded=""
  case "$role" in
    default)
      [[ "$suffix" =~ ^\ digest=sha256:[0-9a-f]{64}$ ]] \
        || fail "$file produced a malformed authoritative report digest"
      ;;
    real-model)
      if [[ "$suffix" =~ ^\ digest=sha256:[0-9a-f]{64}\ provider=([^[:space:]]+)\ model=([^[:space:]]+)\ endpoint=([^[:space:]]+)\ adapter_build=(loopex_llm_reqllm@0\.0\.0)\ recorded=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$ ]]; then
        last_gate_real_profile=model
        last_gate_provider="${BASH_REMATCH[1]}"
        last_gate_model="${BASH_REMATCH[2]}"
        last_gate_endpoint="${BASH_REMATCH[3]}"
        last_gate_adapter_build="${BASH_REMATCH[4]}"
        last_gate_recorded="${BASH_REMATCH[5]}"
      else
        fail "$file produced a malformed model-path identity report"
      fi
      ;;
    real-combined)
      if [[ "$suffix" =~ ^\ digest=sha256:[0-9a-f]{64}\ provider=([^[:space:]]+)\ model=([^[:space:]]+)\ endpoint=([^[:space:]]+)\ adapter_build=(loopex_llm_reqllm@0\.0\.0)\ executor_build=(loopex_executor_local@0\.0\.0)\ executor_identity=([^[:space:]]+)\ tool_identity=([^[:space:]]+)\ recorded=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$ ]]; then
        last_gate_real_profile=combined
        last_gate_provider="${BASH_REMATCH[1]}"
        last_gate_model="${BASH_REMATCH[2]}"
        last_gate_endpoint="${BASH_REMATCH[3]}"
        last_gate_adapter_build="${BASH_REMATCH[4]}"
        last_gate_executor_build="${BASH_REMATCH[5]}"
        last_gate_executor_identity="${BASH_REMATCH[6]}"
        last_gate_tool_identity="${BASH_REMATCH[7]}"
        last_gate_recorded="${BASH_REMATCH[8]}"
      else
        fail "$file produced a malformed combined-path identity report"
      fi
      ;;
  esac

  last_gate_executed="$executed"
  if [ "$accumulate" = yes ]; then
    protected_executed=$((protected_executed + executed))
  elif [ "$accumulate" != no ]; then
    fail "the authoritative test-result accumulation policy is unknown"
  fi
}

# Locked repository commands.
[ -f .formatter.exs ] || fail "no .formatter.exs; formatting scope is unbound"
mix loopex.format_scope || fail "effective formatter configuration misses application sources"
mix format --check-formatted || fail "formatting is not clean"
mix compile --warnings-as-errors || fail "compilation is not warning-free"
validate_generated_tree "$MIX_BUILD_PATH" "the isolated compiled development application tree"
MIX_ENV=test MIX_BUILD_PATH="$test_build_path" mix compile --warnings-as-errors \
  || fail "the isolated test-environment compilation is not warning-free"
validate_generated_tree "$test_build_path" "the isolated compiled test application tree"
mix loopex.version_train || fail "applications do not carry one version"
matrix_pair_output="$(
  elixir "$repository_root/$evidence_verifier_source" \
    --pair --root "$repository_root"
)" \
  || fail "the running pair could not be captured"
if [[ "$matrix_pair_output" =~ ^LOOPEX_M1_PAIR\ lane=(floor|current)\ elixir=([^[:space:]]+)\ otp=([^[:space:]]+)\ erts=([^[:space:]]+)$ ]]; then
  matrix_lane="${BASH_REMATCH[1]}"
  matrix_elixir="${BASH_REMATCH[2]}"
  matrix_otp="${BASH_REMATCH[3]}"
  matrix_erts="${BASH_REMATCH[4]}"
else
  fail "the running pair capture is malformed"
fi
if [ "$gate_role" = capture ]; then
  case "$capture_lane:$matrix_lane" in
    floor:floor | current:current | linux-current:current) ;;
    *)
      fail "capture lane $capture_lane does not match the running locked pair $matrix_lane"
      ;;
  esac
fi
if [ "$gate_role" = ordinary ]; then
  elixir "$repository_root/$evidence_verifier_source" \
    --root "$repository_root" \
    --matrix docs/evidence/M1-toolchain-matrix.md \
    --negative docs/evidence/M1-negative-demonstrations.md \
    || fail "retained M1 toolchain or mutation evidence is invalid"
else
  elixir "$repository_root/$evidence_verifier_source" \
    --root "$repository_root" \
    --negative docs/evidence/M1-negative-demonstrations.md \
    || fail "retained M1 mutation evidence is invalid"
fi
mix loopex.matrix || fail "the inherited M0 toolchain evidence is invalid for this pair"
mix loopex.core_only || fail "core-only, fakes-only lane failed"
mix loopex.docs_check || fail "compiled dual-depth documentation check failed"
mix loopex.hook_registration || fail "a client hook is not registered under its required event and matcher"
mix loopex.status || fail "repository status or bound-artifact validation failed"
bash scripts/check-bootstrap.sh || fail "bootstrap aggregate failed"
run_gate_test default apps/loopex/test/m1_gate_evidence_test.exs 10 zero no \
  "passed=M1 pair verifier derives only the exact running locked pair" \
  "passed=M1 evidence verifier requires one exact capture and inherited M0 proof per locked lane" \
  "passed=M1 evidence verifier binds source evidence and closure transition ancestry" \
  "passed=M1 evidence verifier binds each negative mechanism to committed and restored bytes" \
  "passed=the environment preflight removes credential aliases and unrelated ambient state" \
  "passed=the read-only prefix disables optional Git locks before repository inspection" \
  "passed=the user-state fingerprint includes every entry identity and a command-line symlink target root" \
  "passed=prerequisite copies refuse protected-state hard links and symlinks" \
  "passed=platform filesystem identity and SHA-256 select validated dialects" \
  "passed=owned candidate and generated closures exclude ambient aliases"
run_gate_test default apps/loopex/test/m1_exunit_runner_test.exs 5 zero no \
  "passed=the standalone selector grammar admits every planned owner and rejects foreign paths" \
  "passed=the standalone runner requires one tracked ordinary selector owned by its compiled app" \
  "passed=official counts and exact events refuse failures skips exclusions and missing names" \
  "passed=fake stdout at_exit and early halt cannot manufacture one authoritative result" \
  "passed=only the declared internal dependency closure is reachable and startup never receives the provider key"
run_gate_test default apps/loopex/test/deps_budget_test.exs 25 zero no \
  "passed=the repository satisfies the dependency budget and direction" \
  "passed=a forbidden core dependency is rejected" \
  "passed=an extension may carry external dependencies but not the runtime" \
  "passed=dependency identity and role come only from the canonical project declaration" \
  "passed=internal dependencies cannot redirect canonical umbrella source ownership" \
  "passed=compiled source roots remain inside their owning application" \
  "passed=duplicate dependency names are rejected" \
  "passed=the tracked inventory is dynamic and includes its ordinary root" \
  "passed=the dynamic inventory cannot omit the fixed contract or core" \
  "passed=unrelated project metadata helpers application data and ordinary aliases are permitted" \
  "passed=root and child aliases may not interpose on locked commands" \
  "passed=M1 planned applications accept only their declared dependency shapes" \
  "passed=dependency context separates discovered apps from the selector's declared closure" \
  "passed=each role rejects an adjacent outward or wrong-environment edge" \
  "passed=child identity must match its directory and decoys cannot supply it" \
  "passed=an extra guarded project clause cannot hide behind one literal clause" \
  "passed=the bound dependency verdict bypasses evaluated Mix tasks" \
  "passed=offline materializer proves the exact floor-compatible lock closure" \
  "passed=the contract protocol namespace is not a runtime reverse edge" \
  "passed=static runtime references outside the protocol namespace are rejected" \
  "passed=a reverse edge from contract to runtime is rejected" \
  "passed=dynamic module dispatch is rejected independent of formatting" \
  "passed=a dynamic module reference across the boundary is rejected" \
  "passed=plain module-like data is not treated as an executable reference" \
  "passed=all declared contract compile roots receive reverse-edge checks"

# Protected outcome selectors.
run_gate_test default apps/loopex/test/runtime_test.exs 3 zero yes \
  "passed=two runtimes coexist without a global name" \
  "passed=a runtime reference is required rather than inferred" \
  "passed=a supervised runtime starts and stops with explicit configuration"
run_gate_test default apps/loopex/test/session_lifecycle_test.exs 6 zero yes \
  "passed=session creation atomically records its runtime command mapping and genesis re-presents identical bytes idempotently and conflicts on changed bytes" \
  "passed=initial and resumed coordinators commit advance_owner before admitting commands" \
  "passed=a superseded owner cannot newly commit or use a delayed result to update cache publish dispatch or authorize" \
  "passed=declared injected and observed transition and fault point pairs are equal" \
  "passed=a prompt cannot start a second active run" \
  "passed=only one coordinator owns a session at a time after durable succession"
run_gate_test default apps/loopex_store_local/test/store_conformance_test.exs 5 zero yes \
  "passed=every implementation atomically refuses a stale owner epoch incarnation and version" \
  "passed=a killed writer loses no acknowledged fact" \
  "passed=replay audits durable truth but grants no write authority" \
  "passed=known transactions return their retained resolution without a second mutation" \
  "passed=the durable local store survives process death with consecutive store-stamped history"
run_gate_test default apps/loopex/test/embedded_api_test.exs 4 zero yes \
  "passed=progress and diagnostics never carry durable truth" \
  "passed=committed events survive delivery with stable identity" \
  "passed=attachment snapshots at N and streams events after N without a gap" \
  "passed=a full attachment queue disconnects with a durable-history cursor and resumes gap-free after runtime restart without persisted attachment state"
run_gate_test default apps/loopex_executor_local/test/executor_test.exs 6 zero yes \
  "passed=required grant bindings equal the independent contract oracle" \
  "passed=each missing and wrong grant binding is refused before process start" \
  "passed=only an explicit host-policy allow decision can issue or widen a grant" \
  "passed=the executor recomputes the canonical JobRequest digest and the receipt retains verified origin identity" \
  "passed=the workspace lease is held for the job lifetime and loss kills owned work with retained evidence" \
  "passed=the executor starts one credential-free OS tool that writes the expected workspace bytes and retains its receipt"
run_gate_test default apps/loopex_reference_client/test/reference_client_test.exs 2 zero yes \
  "passed=the client drives the loop through the embedded API only" \
  "passed=the reference client owns no policy durable state or alternate loop"

adapter_model_file="apps/loopex_llm_reqllm/test/real_model_lane_test.exs"
run_gate_test default "$adapter_model_file" 1 zero no \
  "passed=deterministic and ReqLLM adapters satisfy one model conformance suite"
adapter_model_executed="$last_gate_executed"

provider_file="apps/loopex_reference_client/test/real_model_session_test.exs"
run_gate_test default "$provider_file" 1 positive no \
  "passed=model dispatch receives only the committed canonical request bytes and digest" \
  "excluded=one real non-streaming model call receives the committed canonical request bytes and digest and completes inside a session"
provider_default_executed="$last_gate_executed"
run_gate_test real-model "$provider_file" 1 positive no \
  "excluded=model dispatch receives only the committed canonical request bytes and digest" \
  "passed=one real non-streaming model call receives the committed canonical request bytes and digest and completes inside a session"
provider_real_executed="$last_gate_executed"
model_provider="$last_gate_provider"
model_name="$last_gate_model"
model_endpoint="$last_gate_endpoint"
model_adapter_build="$last_gate_adapter_build"
provider_executed=$((adapter_model_executed + provider_default_executed + provider_real_executed))
[ "$provider_executed" -ge 3 ] \
  || fail "$provider_file executed fewer than its aggregate minimum of three tests"
protected_executed=$((protected_executed + provider_executed))

vertical_file="apps/loopex_reference_client/test/end_to_end_recovery_test.exs"
run_gate_test default "$vertical_file" 5 positive no \
  "excluded=one real-provider trace forces a credential-free tool survives an untrappable runtime-tree kill after receipt before fact reconciles one effect without redispatch preserves its fact and completes a second real call" \
  "passed=reconciliation schema covers the independent recovery contract oracle" \
  "passed=exactly one dispatch ever carried each effect across the restart" \
  "passed=an effect without a durable receipt becomes outcome_unknown and is not blindly retried" \
  "passed=every acknowledged fact survives the restart" \
  "passed=each wrong reconciliation and receipt identity is refused"
vertical_default_executed="$last_gate_executed"
run_gate_test real-combined "$vertical_file" 1 positive no \
  "passed=one real-provider trace forces a credential-free tool survives an untrappable runtime-tree kill after receipt before fact reconciles one effect without redispatch preserves its fact and completes a second real call" \
  "excluded=reconciliation schema covers the independent recovery contract oracle" \
  "excluded=exactly one dispatch ever carried each effect across the restart" \
  "excluded=an effect without a durable receipt becomes outcome_unknown and is not blindly retried" \
  "excluded=every acknowledged fact survives the restart" \
  "excluded=each wrong reconciliation and receipt identity is refused"
vertical_real_executed="$last_gate_executed"
[ "$last_gate_provider" = "$model_provider" ] \
  || fail "the two real paths reported different provider identities"
[ "$last_gate_model" = "$model_name" ] \
  || fail "the two real paths reported different model identities"
[ "$last_gate_endpoint" = "$model_endpoint" ] \
  || fail "the two real paths reported different endpoint identities"
[ "$last_gate_adapter_build" = "$model_adapter_build" ] \
  || fail "the two real paths reported different adapter builds"
capture_provider="$last_gate_provider"
capture_model="$last_gate_model"
capture_endpoint="$last_gate_endpoint"
capture_adapter_build="$last_gate_adapter_build"
capture_executor_build="$last_gate_executor_build"
capture_executor_identity="$last_gate_executor_identity"
capture_tool_identity="$last_gate_tool_identity"
capture_recorded="$last_gate_recorded"
vertical_executed=$((vertical_default_executed + vertical_real_executed))
[ "$vertical_executed" -ge 6 ] \
  || fail "$vertical_file executed fewer than its aggregate minimum of six tests"
protected_executed=$((protected_executed + vertical_executed))

# Presence is mechanical; freshness and completeness remain closure review.
for closure_document in \
  CHANGELOG.md \
  README.md \
  DEVELOPMENT.md \
  docs/plans/README.md \
  docs/plans/M1.md \
  docs/evidence/M1-toolchain-matrix.md \
  docs/evidence/M1-negative-demonstrations.md \
  docs/evidence/README.md \
  docs/developer/agent-context-map.md
do
  if [ "$gate_role" = capture ] && \
    [ "$closure_document" = docs/evidence/M1-toolchain-matrix.md ]; then
    continue
  fi
  require_tracked_regular "$closure_document" "closure document"
done

# Credential-free ordinary suite. This direct ExUnit invocation uses the same
# runner-wide seed; its broad total is not substituted for protected identities.
validate_generated_tree "$test_build_path" \
  "the compiled test application tree before the full suite"
MIX_ENV=test MIX_BUILD_PATH="$test_build_path" mix test --exclude real_provider --seed "$gate_seed" \
  || fail "full credential-free suite failed"
validate_generated_tree "$MIX_BUILD_PATH" \
  "the final compiled development application tree"
validate_generated_tree "$test_build_path" \
  "the final compiled test application tree"

tree_state_after="$(git status --porcelain=v1 --untracked-files=all)" \
  || fail "working-tree state is unavailable after the run"
[ -z "$tree_state_after" ] \
  || fail "the gate or its tests changed the whole tree"
[ -z "$(git -C "$source_repository_root" status --porcelain=v1 --untracked-files=all)" ] \
  || fail "the gate or its tests changed the source working tree"

user_state_after="$(real_user_state)" \
  || fail "real user state could not be fingerprinted after the run"
[ "$user_state_after" = "$user_state_before" ] \
  || fail "the run changed the content, type, mode, or topology of real user state"

if [ "$gate_role" = capture ]; then
  capture_record="capture lane=$capture_lane candidate=$source_candidate gate_sha256=$gate_sha256 command=bash-p:scripts/check-m1-gate.sh elixir=$matrix_elixir otp=$matrix_otp erts=$matrix_erts seed=$gate_seed executed=$protected_executed verdict=CAPTURE exit=0 wall=${SECONDS}s os=$runtime_os arch=$runtime_arch limits=$runtime_limits provider=$capture_provider model=$capture_model endpoint=$capture_endpoint adapter_build=$capture_adapter_build executor_build=$capture_executor_build executor_identity=$capture_executor_identity tool_identity=$capture_tool_identity recorded=$capture_recorded"
  if [ -n "$provider_key_value" ]; then
    case "$capture_record" in
      *"$provider_key_value"*) fail "the final capture contains provider credential bytes" ;;
    esac
  fi
  final_gate_output="$capture_record"$'\n'
else
  final_gate_output="M1 gate GREEN seed=$gate_seed protected_executed=$protected_executed"$'\n'
fi
emit_gate_output stdout "$final_gate_output" \
  || fail "final gate output collides with provider credential bytes"
