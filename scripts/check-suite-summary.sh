#!/usr/bin/env bash
# Proves the suite-summary judge on the result lines both supported
# toolchains print: green only when at least one test executed and none
# failed. Runs in under a second; no silence to bound.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
judge=scripts/suite-summary.sh
status=0
expect() {
  local verdict=$1 line=$2 tmp
  tmp=$(mktemp)
  printf 'noise\n%s\ntrailer\n' "$line" > "$tmp"
  if bash "$judge" "$tmp" >/dev/null 2>&1; then got=green; else got=red; fi
  rm -f "$tmp"
  if [ "$got" != "$verdict" ]; then
    printf 'suite summary check failed: %s judged %s, expected %s\n' "$line" "$got" "$verdict"
    status=1
  fi
}
expect green 'Result: 544 passed, 1 excluded'
expect green 'Result: 26 passed'
expect green 'Result: 3 passed, 2 skipped, 1 excluded'
expect green '544 tests, 0 failures, 1 excluded'
expect green '3 tests, 0 failures'
expect green '4 tests, 0 failures, 1 skipped, 1 excluded'
expect red 'Result: 0/1 passed'
expect red 'Result: 26/27 passed, 1 excluded'
expect red 'Result: 0 passed, 1 excluded'
expect red 'Result: 2 passed, 1 invalid'
expect red '1 test, 0 failures, 1 skipped'
expect red '2 tests, 0 failures, 2 excluded'
expect red '2 tests, 1 failure'
expect red '3 tests, 0 failures, 1 invalid'
expect red 'no result line at all'
[ "$status" -eq 0 ] && printf 'suite summary check passed\n'
exit "$status"
