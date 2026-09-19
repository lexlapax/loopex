#!/usr/bin/env bash
# Reads one ExUnit log and prints its result line only if the suite executed
# at least one test and none failed. A suite that ran nothing is not green:
# skipped and excluded tests are subtracted before the count is judged, so
# `1 test, 0 failures, 1 skipped` on the floor toolchain is refused, as is a
# `Result:` line with a failure fraction or an invalid module. Exit 1 otherwise.
set -euo pipefail
log=$1
line=$(grep -aE '^Result: |^([0-9]+ [a-z]+, )*[0-9]+ tests?, ' "$log" | tail -n 1 || true)
[ -n "$line" ] || exit 1
case "$line" in
  "Result: "*)
    # Elixir 1.19+: `Result: P passed[, E excluded][, S skipped]` is the only
    # green shape admitted; a failure fraction, an invalid count, or any shape
    # this judge has not seen is red. The passed count is already net of
    # skipped and excluded.
    printf '%s\n' "$line" | grep -qE '^Result: [0-9]+ passed(, [0-9]+ (excluded|skipped))*$' || exit 1
    passed=$(printf '%s\n' "$line" | sed -nE 's/^Result: ([0-9]+) passed.*/\1/p')
    ;;
  *)
    # Older ExUnit: `[D doctests, ][P properties, ]N tests, F failures[, E
    # excluded][, S skipped][, I invalid]`; N counts every test, so the executed
    # count is N minus excluded and skipped. Doctests and properties count as
    # executed work of their own.
    printf '%s\n' "$line" |
      grep -qE '^([0-9]+ [a-z]+, )*[0-9]+ tests?, [0-9]+ failures?(, [0-9]+ (excluded|skipped))*$' || exit 1
    failures=$(printf '%s\n' "$line" | sed -nE 's/.*[0-9]+ tests?, ([0-9]+) failures?.*/\1/p')
    [ "${failures:-1}" = 0 ] || exit 1
    total=$(printf '%s\n' "$line" | sed -nE 's/^(.*[^0-9])?([0-9]+) tests?, .*/\2/p')
    extra=$(printf '%s\n' "$line" | sed -nE 's/^(([0-9]+ [a-z]+, )*)[0-9]+ tests?, .*/\1/p' | { grep -oE '[0-9]+' || true; } | awk '{s += $1} END {print s + 0}')
    excluded=$(printf '%s\n' "$line" | sed -nE 's/.*, ([0-9]+) excluded.*/\1/p')
    skipped=$(printf '%s\n' "$line" | sed -nE 's/.*, ([0-9]+) skipped.*/\1/p')
    passed=$((total + ${extra:-0} - ${excluded:-0} - ${skipped:-0}))
    ;;
esac
[ "${passed:-0}" -ge 1 ] || exit 1
printf '%s\n' "$line"
