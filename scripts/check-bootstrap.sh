#!/usr/bin/env bash
# Provider-neutral seed-bootstrap entrypoint. Hosted CI may mirror this exact
# repository-owned command, but local execution requires no hosted service.
set -euo pipefail


# Under a restricted sandbox, macOS git emits one benign line per invocation:
#   git: warning: confstr() failed with code 5: couldn't get path of
#   DARWIN_USER_TEMP_DIR; using /tmp instead
# It cannot be suppressed by TMPDIR, and a review that must read this output
# should not have to find it among hundreds of copies. Drop exactly that line
# and nothing else, and preserve each check's own exit status.
exec 3>&1
run_check() {
  local rc
  set +e
  "$@" 2>&1 1>&3 | grep -v 'DARWIN_USER_TEMP_DIR' >&2
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# The first git call happens before the helper exists, so filter it inline.
# With pipefail a rev-parse failure still aborts, and its message is not the
# filtered pattern so it survives.
cd "$(git rev-parse --show-toplevel 2>&1 | grep -v 'DARWIN_USER_TEMP_DIR')"

run_check bash scripts/check-agent-bootstrap.sh
run_check bash scripts/check-gitignore.sh
run_check bash scripts/check-commit-messages.sh
run_check bash scripts/check-repo-hygiene.sh
run_check bash scripts/check-status.sh
