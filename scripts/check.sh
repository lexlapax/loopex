#!/usr/bin/env bash
# The fast check: everything a push must pass, credential-free, in minutes.
# Each step prints its name when it starts and its elapsed seconds when it
# ends; output streams as it happens. Stops at the first failing step.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

started=$SECONDS
step() {
  local name=$1 step_started=$SECONDS
  shift
  printf 'check: %s\n' "$name"
  "$@"
  printf 'check: done %s step=%ss total=%ss\n' "$name" "$((SECONDS - step_started))" "$((SECONDS - started))"
}

step "repository structure" bash scripts/check-bootstrap.sh
step "formatting" mix format --check-formatted
step "warning-free compilation" mix compile --warnings-as-errors
step "dependency budget and direction" mix loopex.deps_budget
step "one version across applications" mix loopex.version_train
step "documentation ordering" mix loopex.docs_check
step "credential-free test suite" mix test
printf 'check: PASS total=%ss\n' "$((SECONDS - started))"
