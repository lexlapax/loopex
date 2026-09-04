#!/usr/bin/env bash
set -eu
set +a
set -m

die() {
  printf '%s\n' "M4 gate unavailable: $*" >&2
  exit 2
}

digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "no SHA-256 command is available"
  fi
}

require_digest() {
  expected="$1"
  path="$2"
  [ -f "$path" ] || die "bound artifact is absent: $path"
  actual="$(digest "$path")"
  [ "$actual" = "$expected" ] || die "bound artifact digest mismatch: $path"
}

role=ordinary
if [ "$#" -gt 0 ]; then
  case "$1" in
    --inspect)
      [ "$#" -eq 1 ] || die "--inspect accepts no other argument"
      role=inspect
      ;;
    --preflight)
      [ "$#" -eq 1 ] || die "--preflight accepts no other argument"
      role=preflight
      ;;
    *)
      die "accepted roles are ordinary, --inspect, and --preflight"
      ;;
  esac
fi

[ "${LOOPEX_PROVIDER_API_KEY+x}" != x ] \
  || die "LOOPEX_PROVIDER_API_KEY is forbidden in the initial M4 gate environment"

unset provider_key_value provider_frame_header provider_frame_trailing
export -n provider_key_value provider_frame_header provider_frame_trailing 2>/dev/null || :
provider_frame_present=0

read_optional_provider_frame() {
  [ ! -t 0 ] || return 0

  provider_frame_header=""
  if IFS= read -r -d '' -n 22 -t 5 provider_frame_header; then
    :
  else
    provider_frame_status=$?
    if [ "$provider_frame_status" -eq 1 ] && [ -z "$provider_frame_header" ]; then
      return 0
    fi
    die "the provider frame header is unterminated or exceeded its time bound"
  fi
  [ "$provider_frame_header" = "LOOPEX_M4_PROVIDER_V1" ] \
    || die "the provider frame header is malformed or exceeds its byte bound"

  provider_key_value=""
  IFS= read -r -d '' -n 16385 -t 5 provider_key_value \
    || die "the provider frame is missing its key terminator or exceeded its time bound"
  [ -n "$provider_key_value" ] || die "the provider frame carries an empty key"
  [ "${#provider_key_value}" -le 16384 ] \
    || die "the provider frame key exceeds its byte bound"

  provider_frame_trailing=""
  if IFS= read -r -d '' -n 1 -t 1 provider_frame_trailing; then
    die "the provider frame carries trailing bytes"
  else
    provider_frame_status=$?
    [ "$provider_frame_status" -eq 1 ] \
      || die "the provider frame did not terminate at EOF within its time bound"
  fi

  provider_frame_present=1
  unset provider_frame_header provider_frame_trailing
  export -n provider_key_value 2>/dev/null || die "the provider holder could not be de-exported"
}

if [ "$role" = ordinary ]; then
  read_optional_provider_frame
fi

# No candidate or toolchain child inherits the caller's input stream. Ordinary
# mode retains an optional bounded provider frame only in the unexported shell
# holder above; an absent frame remains permissible until the primary probe is
# green so the accepted opening red is credential-free.
exec </dev/null

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a Git checkout"
cd "$repo"
repo="$(pwd -P)" || die "the checkout could not be physically resolved"
cd "$repo"

require_digest "e025f5f5d50109dfd181430ef1a8536b71f4d105c64b9af5b1c366d27cd57a7f" "scripts/m4-black-box-client.exs"
require_digest "9cda7a770cd930558b2f0d7733e40ba29314f81eb96a49484330051dc4fe377c" "scripts/fixtures/m4/session-protocol.schema.json"
require_digest "2941a4ff74824a0d84e10dce46a9807ff6ff900e71b8fb2d9c1dc20e5b3b826f" "scripts/fixtures/m4/initialize.jsonl"
require_digest "49cf0f45523ed704ac400d3a971d802fb973f2b8b9c162a65464b727259d9c4c" "scripts/fixtures/m4/probe-requests.jsonl"
require_digest "d30b04d60967ddc480efe258c9f30c384341bad71080bbd286959d79e80e57c9" "scripts/fixtures/m4/defer-once-policy.exs"
require_digest "cc290e60d9f9588c75f1259b25976a58d1c30713e570cd5a88c70cdf3c2159a0" "scripts/m1-exunit-runner.exs"
require_digest "0a8406ca080c70624e776b01e37c7ded210b54659064cf63723a847a54debe2d" "apps/loopex/test/m1_exunit_runner_test.exs"
require_digest "fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999" ".tool-versions"

for path in docs/archive/M4.md docs/archive/M4-technical.md docs/archive/M4-gate.md; do
  [ -f "$path" ] || die "M4 governance artifact is absent: $path"
done

if [ "$role" = inspect ]; then
  printf '%s\n' "M4 inspection OK"
  exit 0
fi

[ -z "$(git status --porcelain --untracked-files=all)" ] || die "checkout is not clean"

[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "writable roles require an existing ambient HOME"
physical_home="$(cd "$HOME" && pwd -P)" || die "ambient home could not be physically resolved"
real_product_state="$physical_home/.loopex"
if [ -L "$real_product_state" ] && [ ! -e "$real_product_state" ]; then
  die "the operator product-state path is a broken symlink"
fi
if [ -e "$real_product_state" ]; then
  [ -d "$real_product_state" ] || die "the operator product-state path is not a directory"
  real_product_state="$(cd "$real_product_state" && pwd -P)" \
    || die "operator product state could not be physically resolved"
fi

task_parent="${TMPDIR:-/tmp}"
[ -d "$task_parent" ] || die "the task-root parent is absent"
task_parent="$(cd "$task_parent" && pwd -P)" \
  || die "the task-root parent could not be physically resolved"
allocated_task_root="$(mktemp -d "$task_parent/loopex-m4-gate.XXXXXX")" \
  || die "cannot allocate task root"
task_root=""
cleanup_done=0
active_probe_pid=""
active_probe_pgid=""

probe_group_alive() {
  [ -n "$active_probe_pgid" ] || return 1
  kill -0 -- "-$active_probe_pgid" 2>/dev/null
}

cleanup_active_probe() {
  [ -n "$active_probe_pid" ] || [ -n "$active_probe_pgid" ] || return 0

  if probe_group_alive; then
    kill -TERM -- "-$active_probe_pgid" 2>/dev/null || :
    for _cleanup_attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      probe_group_alive || break
      sleep 0.05
    done
  fi
  if probe_group_alive; then
    kill -KILL -- "-$active_probe_pgid" 2>/dev/null || :
    for _cleanup_attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      probe_group_alive || break
      sleep 0.05
    done
  fi
  [ -z "$active_probe_pid" ] || wait "$active_probe_pid" 2>/dev/null || :
  probe_group_alive && return 1
  active_probe_pid=""
  active_probe_pgid=""
}

cleanup_task_root() {
  [ "$cleanup_done" -eq 0 ] || return 0
  [ -n "$allocated_task_root" ] && [ "$allocated_task_root" != / ] || return 1

  if [ -e "$allocated_task_root" ] || [ -L "$allocated_task_root" ]; then
    rm -rf -- "$allocated_task_root" || return 1
  fi
  [ ! -e "$allocated_task_root" ] && [ ! -L "$allocated_task_root" ] || return 1
  cleanup_done=1
}

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if ! cleanup_active_probe; then
    printf '%s\n' "M4 gate unavailable: the raw probe client could not be terminated" >&2
    exit 2
  fi
  if ! cleanup_task_root; then
    printf '%s\n' "M4 gate unavailable: the isolated task root could not be removed" >&2
    status=2
  fi
  exit "$status"
}

finish_success() {
  message="$1"
  trap - EXIT HUP INT TERM
  if ! cleanup_active_probe; then
    printf '%s\n' "M4 gate unavailable: the raw probe client could not be terminated" >&2
    exit 2
  fi
  if ! cleanup_task_root; then
    printf '%s\n' "M4 gate unavailable: the isolated task root could not be removed" >&2
    exit 2
  fi
  printf '%s\n' "$message"
  exit 0
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

task_root="$(cd "$allocated_task_root" && pwd -P)" \
  || die "task root could not be physically resolved"
case "$task_root" in
  "$repo"|"$repo"/*) die "task root resolved inside the checkout" ;;
esac
case "$task_root" in
  "$real_product_state"|"$real_product_state"/*) die "task root resolved inside real product state" ;;
esac

source_hex_packages="$physical_home/.hex/packages"
[ -d "$source_hex_packages" ] && [ ! -L "$source_hex_packages" ] \
  || die "the fixed-home Hex package cache is absent or linked"
source_hex_packages="$(cd "$source_hex_packages" && pwd -P)" \
  || die "the fixed-home Hex package cache could not be physically resolved"

source_mix_home="$physical_home/.mix"
[ -d "$source_mix_home" ] && [ ! -L "$source_mix_home" ] \
  || die "the fixed-home Mix tool directory is absent or linked"
source_mix_home="$(cd "$source_mix_home" && pwd -P)" \
  || die "the fixed-home Mix tool directory could not be physically resolved"
[ -d "$source_mix_home/archives" ] && [ -d "$source_mix_home/elixir" ] \
  || die "the installed Hex archive or per-Elixir Rebar tree is absent"

for source_tree in "$source_mix_home/archives" "$source_mix_home/elixir"; do
  [ -z "$(find -P "$source_tree" -type l -print -quit)" ] \
    || die "the installed Mix tool input contains a symlink"
  [ -z "$(find -P "$source_tree" ! -type d ! -type f -print -quit)" ] \
    || die "the installed Mix tool input contains a special entry"
done

mkdir -p \
  "$task_root/home" \
  "$task_root/hex-home" \
  "$task_root/mix-home/archives" \
  "$task_root/mix-home/elixir" \
  "$task_root/rebar-cache" \
  "$task_root/deps" \
  "$task_root/workspace"
printf '%s\n' "gate fixture" >"$task_root/workspace/input.txt"
: >"$task_root/protected-file-ids"

hex_archive_count=0
for hex_archive in "$source_mix_home"/archives/hex-*; do
  [ -e "$hex_archive" ] || continue
  [ -d "$hex_archive" ] && [ ! -L "$hex_archive" ] \
    || die "an installed Hex archive is not an ordinary directory"
  cp -R "$hex_archive" "$task_root/mix-home/archives/" \
    || die "the installed Hex archive could not be snapshotted"
  hex_archive_count=$((hex_archive_count + 1))
done
[ "$hex_archive_count" -ge 1 ] || die "no installed Hex archive is available"
cp -R "$source_mix_home/elixir/." "$task_root/mix-home/elixir/" \
  || die "the per-Elixir Rebar tree could not be snapshotted"

unset MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_HOME HEX_HOME REBAR_CACHE_DIR
if ! elixir -r "$repo/apps/loopex/lib/mix/tasks/loopex.deps_budget.ex" \
  -e 'Loopex.Checks.DepsBudget.main(System.argv())' -- \
  --materialize "$source_hex_packages" "$task_root/deps" "$task_root/protected-file-ids"
then
  die "lock-bound dependency source could not be materialized offline"
fi

export MIX_BUILD_ROOT="$task_root/build"
export MIX_DEPS_PATH="$task_root/deps"
export MIX_HOME="$task_root/mix-home"
export HEX_HOME="$task_root/hex-home"
export REBAR_CACHE_DIR="$task_root/rebar-cache"
export HEX_OFFLINE=1
export LOOPEX_HOME="$task_root/home"
export TMPDIR="$task_root"
export HOME="$task_root/home"
export MIX_ENV=dev
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export ERL_CRASH_DUMP=/dev/null
export ERL_CRASH_DUMP_SECONDS=0

compile_log="$task_root/compile.log"
if ! mix compile >"$compile_log" 2>&1; then
  sed -n '1,200p' "$compile_log" >&2
  die "isolated clean-root compile failed"
fi

schema="sha256:$(digest scripts/fixtures/m4/session-protocol.schema.json)"
policy_revision="sha256:$(digest scripts/fixtures/m4/defer-once-policy.exs)"
observation_file="$task_root/observation.txt"
diagnostic_file="$task_root/diagnostics.txt"

(
  ulimit -f 2048 || die "the child output file-size limit could not be installed"
  exec elixir scripts/m4-black-box-client.exs \
    "$repo" \
    "$repo/scripts/fixtures/m4/initialize.jsonl" \
    "$repo/scripts/fixtures/m4/probe-requests.jsonl" \
    "$task_root/workspace" \
    "$schema" \
    "$policy_revision" \
    >"$observation_file" 2>"$diagnostic_file"
) &
active_probe_pid=$!
active_probe_pgid="$(ps -o pgid= -p "$active_probe_pid" | awk '{print $1}')" \
  || die "the raw probe process group could not be inspected"
[ "$active_probe_pgid" = "$active_probe_pid" ] \
  || die "the raw probe did not start as the leader of its owned process group"
if wait "$active_probe_pid"; then
  active_probe_pid=""
  probe_group_alive \
    && die "the raw probe client exited while its owned process group remained alive"
  active_probe_pgid=""
else
  active_probe_pid=""
  die "black-box client could not complete its bounded observation"
fi

observation="$(tail -n 1 "$observation_file")"
case "$observation" in
  "LOOPEX_M4_PROBE launch=started initialize=accepted protocol=loopex.experimental/1 schema=exact attach=accepted admission=accepted order=admission_then_gap_free progress="*" response_admission=accepted tool=completed terminal=finished settled=accepted interaction=resolved snapshot=settled stdout=protocol_only")
    progress="$(printf '%s\n' "$observation" | sed -n 's/.* progress=\([0-9][0-9]*\) .*/\1/p')"
    [ -n "$progress" ] && [ "$progress" -gt 0 ] || die "probe reported no asynchronous progress"
    ;;
  *)
    printf '%s\n' "M4 gate RED: a separate program cannot initialize the experimental stdio JSONL session protocol or drive one Loopex session through correlated durable admission, asynchronous progress, a durable interaction round trip, terminal settlement, and a later snapshot (observed through the public boundary: $observation)" >&2
    exit 1
    ;;
esac

if [ "$role" = preflight ]; then
  finish_success "M4 preflight OK"
fi

[ "$provider_frame_present" -eq 1 ] && [ -n "${provider_key_value:-}" ] \
  || die "ordinary mode requires one LOOPEX_M4_PROVIDER_V1 provider frame"

mix loopex.status
bash scripts/check-bootstrap.sh
LOOPEX_PROVIDER_API_KEY="$provider_key_value" bash scripts/check-m0-gate.sh
printf 'LOOPEX_M1_PROVIDER_V1\0%s\0' "$provider_key_value" | /bin/bash -p scripts/check-m1-gate.sh
printf 'LOOPEX_M2_PROVIDER_V1\0%s\0' "$provider_key_value" | bash scripts/check-m2-gate.sh
unset provider_key_value

MIX_ENV=test mix test \
  apps/loopex/test/interaction_lifecycle_test.exs \
  apps/loopex_protocol/test/public_schema_conformance_test.exs \
  apps/loopex_app_server/test

finish_success "M4 gate GREEN"
