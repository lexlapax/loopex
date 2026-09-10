#!/usr/bin/env bash
# Concept: execute each required Closed predecessor once, in register order.
# Technical depth: M3 calls --before M3, so even a Closed M3 never calls itself.
set -euo pipefail
set +x
set +a
export LC_ALL=C
fail() { printf 'Closed gates UNAVAILABLE: %s\n' "$*" >&2; exit 2; }
[ "${LOOPEX_M3_BOOTSTRAP_ACTIVE:-}" != 1 ] || fail 'bootstrap must not invoke the closed-gate aggregate'
[ "${LOOPEX_PROVIDER_API_KEY+x}" != x ] || fail 'provider input must use the bounded stdin frame'
unset OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY AZURE_OPENAI_API_KEY
caller=all
list=0
case "$#:$*" in
  0:) ;;
  1:--list) list=1 ;;
  2:--before\ *) [ "$1" = --before ] || fail 'invalid arguments'; caller=$2 ;;
  3:--list\ --before\ *) list=1; caller=$3 ;;
  *) fail 'usage: check-closed-gates.sh [--list] [--before <milestone>]' ;;
esac
key=""
export -n key
if [ "$list" = 0 ] && ! [ -t 0 ]; then
  header=""
  if IFS= read -r -d '' -n 22 header; then
    [ "$header" = LOOPEX_M3_PROVIDER_V1 ] || fail 'malformed provider frame header'
    IFS= read -r -d '' -n 16385 key || fail 'unterminated or oversized provider frame'
    [ -n "$key" ] && [ "${#key}" -le 16384 ] || fail 'empty or oversized provider frame'
    trailing=""
    if IFS= read -r -d '' -n 1 trailing || [ -n "$trailing" ]; then fail 'trailing provider input'; fi
  elif [ -n "$header" ]; then
    fail 'unterminated provider frame header'
  fi
fi
root=$(git rev-parse --show-toplevel) || fail 'not a checkout'
cd "$root"
if [ "$list" = 1 ]; then
  exec env LANG=C.UTF-8 LC_ALL=C.UTF-8 elixir scripts/m3-gate-support.exs --m3-gate-support closed "$root" "$caller"
fi
task_root=$(mktemp -d "${TMPDIR:-/tmp}/loopex-closed-gates.XXXXXXXX") || fail 'cannot allocate invocation ledger'
trap 'rm -rf "$task_root"' EXIT
trap 'exit 2' INT TERM
env LANG=C.UTF-8 LC_ALL=C.UTF-8 elixir scripts/m3-gate-support.exs --m3-gate-support closed "$root" "$caller" > "$task_root/plan" || exit $?
# Only these existing gates have a declared credential protocol. A successor
# can run without a key; forwarding a key requires its own explicit contract.
if [ -n "$key" ]; then
  while IFS=$'\t' read -r name rest; do
    case "$name" in M0|M1|M2|M3|'') ;; *) fail "credential protocol is undeclared for $name" ;; esac
  done < "$task_root/plan"
fi
: > "$task_root/ledger"
while IFS=$'\t' read -r name interpreter first second; do
  [ -n "$name" ] || continue
  printf 'Closed gate invoking: %s\n' "$name"
  args=("$interpreter" "$first")
  [ -z "$second" ] || args+=("$second")
  result=0
  case "$name" in
    M0) LOOPEX_PROVIDER_API_KEY="$key" "${args[@]}" </dev/null || result=$? ;;
    M1|M2)
      if [ -n "$key" ]; then
        builtin printf 'LOOPEX_%s_PROVIDER_V1\0%s\0' "$name" "$key" | "${args[@]}" || result=$?
      else
        "${args[@]}" </dev/null || result=$?
      fi ;;
    M3)
      if [ -n "$key" ]; then
        builtin printf 'LOOPEX_M3_PROVIDER_V1\0%s\0' "$key" | "${args[@]}" || result=$?
      else
        "${args[@]}" </dev/null || result=$?
      fi ;;
    *) "${args[@]}" </dev/null || result=$? ;;
  esac
  printf '%s\t%s\n' "$name" "$result" >> "$task_root/ledger"
  [ "$result" = 0 ] || { printf 'Closed gate failed: %s exit=%s\n' "$name" "$result" >&2; exit "$result"; }
done < "$task_root/plan"
env LANG=C.UTF-8 LC_ALL=C.UTF-8 elixir scripts/m3-gate-support.exs --m3-gate-support account "$task_root/plan" "$task_root/ledger"
printf 'LOOPEX_CLOSED_GATES_REPORT caller=%s complete=true\n' "$caller"
