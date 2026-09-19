#!/usr/bin/env bash
# Reads one ExUnit log and prints its result line only if the suite executed
# at least one test and none failed. A suite that ran nothing is not green:
# skipped and excluded tests are subtracted before the count is judged, so
# `1 test, 0 failures, 1 skipped` on the floor toolchain is refused, as is a
# `Result:` line with a failure fraction or an invalid module. Exit 1 otherwise.
set -euo pipefail
log=$1
line=$(grep -aE '^Result: |^[0-9]+ tests?, ' "$log" | tail -n 1 || true)
[ -n "$line" ] || exit 1
case "$line" in
  "Result: "*)
    # Elixir 1.19+: `Result: P passed[, E excluded][, S skipped][, I invalid]`;
    # a failure shows as `Result: P/N passed`. The passed count is already net
    # of skipped and excluded.
    case "$line" in */*|*invalid*) exit 1 ;; esac
    passed=$(printf '%s\n' "$line" | sed -nE 's/^Result: ([0-9]+) passed.*/\1/p')
    ;;
  *)
    # Older ExUnit: `N tests, F failures[, E excluded][, S skipped][, I invalid]`;
    # N counts every test, so the executed count is N minus excluded and skipped.
    failures=$(printf '%s\n' "$line" | sed -nE 's/^[0-9]+ tests?, ([0-9]+) failures?.*/\1/p')
    [ "${failures:-1}" = 0 ] || exit 1
    case "$line" in *invalid*) exit 1 ;; esac
    total=$(printf '%s\n' "$line" | sed -nE 's/^([0-9]+) tests?, .*/\1/p')
    excluded=$(printf '%s\n' "$line" | sed -nE 's/.*, ([0-9]+) excluded.*/\1/p')
    skipped=$(printf '%s\n' "$line" | sed -nE 's/.*, ([0-9]+) skipped.*/\1/p')
    passed=$((total - ${excluded:-0} - ${skipped:-0}))
    ;;
esac
[ "${passed:-0}" -ge 1 ] || exit 1
printf '%s\n' "$line"
