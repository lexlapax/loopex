#!/usr/bin/env bash
# Executable acceptance gate for milestone M0.
#
# The locked contract is docs/plans/M0-gate.md; this runner executes it. It is
# deliberately NOT part of scripts/check-bootstrap.sh: the bootstrap aggregate
# must stay green for the whole milestone while this gate stays red until the
# declared outcomes exist.
#
# This runner does not trust exit codes alone. An exit code proves a command
# ran, not that it did anything, so every outcome that could be satisfied by a
# no-op is checked against something an implementation cannot fake by returning
# zero: locked test names, minimum executed test counts, an independently
# constructed environment, and direct inventory inspection.
#
# Every command form below was executed against a disposable umbrella scaffold
# before this gate was proposed. An umbrella root runs no tests of its own, so
# selectors are app-relative paths; `mix test --only <tag>` at the root also
# recurses into applications with no tagged tests and exits zero having run
# nothing, so the tagged lane is both path-scoped and count-checked.
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>&1 | grep -v 'DARWIN_USER_TEMP_DIR')"

fail() {
  echo "M0 gate RED: $1" >&2
  exit 1
}

require_named_test() {
  local file="$1" name="$2"
  [ -f "$file" ] || fail "protected selector $file is missing"
  grep -qF "test \"${name}\"" "$file" \
    || fail "$file is missing the locked test \"${name}\""
}

# ExUnit reports skipped tests inside the total: "1 test, 0 failures, 1 skipped".
# A tagged-skip test therefore satisfies a naive minimum without executing, so
# the executed count is the total minus skipped, and any skip is itself a
# failure for a protected selector.
test_count() {
  printf '%s' "$1" | grep -oE '[0-9]+ (test|tests),' | tail -1 | grep -oE '[0-9]+' || true
}

skipped_count() {
  printf '%s' "$1" | grep -oE '[0-9]+ skipped' | tail -1 | grep -oE '[0-9]+' || true
}

run_selector() {
  local file="$1" minimum="$2" output count skipped executed
  if ! output="$(mix test "$file" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "$file failed"
  fi
  count="$(test_count "$output")"
  [ -n "$count" ] || fail "$file produced no parsable test count"
  skipped="$(skipped_count "$output")"
  skipped="${skipped:-0}"
  if [ "$skipped" -ne 0 ]; then
    fail "$file skipped ${skipped} tests; a protected selector may not skip"
  fi
  executed=$((count - skipped))
  [ "$executed" -ge "$minimum" ] \
    || fail "$file executed ${executed} tests, fewer than the locked minimum ${minimum}"
}

command -v mix >/dev/null 2>&1 || fail "mix is not installed; the accepted toolchain is required"

# The scaffold ADR 0001 accepts. Until it exists there is no project to check,
# which is the declared missing behavior at the gate commit.
[ -f mix.exs ] || fail "no umbrella project at mix.exs (outcome 1)"
[ -f apps/loopex_protocol/mix.exs ] || fail "no contract application at apps/loopex_protocol (outcome 1)"
[ -f apps/loopex/mix.exs ] || fail "no runtime application at apps/loopex (outcome 1)"
[ -f .tool-versions ] || fail "no locked toolchain matrix at .tool-versions (outcome 3)"

# Locked test names. These are the specific claims the milestone exists to
# prove; a file that runs tests but not these proves something else.
require_named_test apps/loopex/test/deps_budget_test.exs "a forbidden core dependency is rejected"
require_named_test apps/loopex/test/deps_budget_test.exs "a reverse edge from contract to runtime is rejected"
require_named_test apps/loopex/test/deps_budget_test.exs "a dynamic module reference across the boundary is rejected"
require_named_test apps/loopex/test/core_only_test.exs "core starts with no adapter application resolved or started"
require_named_test apps/loopex/test/core_only_test.exs "per-runtime state is not read from application environment"
require_named_test apps/loopex/test/journal_replay_test.exs "replay after an induced restart reconstructs the same durable state"
require_named_test apps/loopex/test/fencing_test.exs "commit_unknown is fenced and never dispatched a second time"
require_named_test apps/loopex/test/fencing_test.exs "a stale completion is rejected after a coordinator restart"
require_named_test apps/loopex/test/vm_code_spike_test.exs "a trusted generation loads and rolls back in an isolated VM"

mix format --check-formatted || fail "formatting is not clean"
mix compile --warnings-as-errors || fail "compilation is not warning-free"
mix loopex.deps_budget || fail "dependency budget or direction violated (outcome 1)"
mix loopex.version_train || fail "applications do not carry one version (outcome 1)"

run_selector apps/loopex/test/deps_budget_test.exs 3
mix loopex.core_only || fail "core-only, fakes-only lane failed (outcome 9)"
run_selector apps/loopex/test/core_only_test.exs 2

# ADR 0001 requires the client hook to call repository enforcement rather than
# duplicate it. A hook that still carries its own budget logic is not a caller.
hook=".claude/hooks/deps-budget.sh"
if [ -f "$hook" ]; then
  grep -qE 'mix +loopex\.deps_budget' "$hook" \
    || fail "$hook does not call the repository dependency-budget command (outcome 2)"
  grep -qE 'apps/loopex/mix\.exs' "$hook" \
    && fail "$hook still duplicates budget logic instead of calling it (outcome 2)"
fi
mix loopex.matrix || fail "a locked toolchain pair did not pass (outcome 3)"
run_selector apps/loopex/test/journal_replay_test.exs 2
run_selector apps/loopex/test/fencing_test.exs 2
run_selector apps/loopex/test/vm_code_spike_test.exs 1

# Outcome 7. A tagged run exits zero having executed nothing, so the count is
# the evidence, not the exit code.
provider_output="$(mix test apps/loopex_llm_reqllm/test/provider_test.exs --only real_provider 2>&1)" \
  || { printf '%s\n' "$provider_output" >&2; fail "real-provider lane failed (outcome 7)"; }
provider_count="$(test_count "$provider_output")"
[ "${provider_count:-0}" -ge 1 ] \
  || fail "real-provider lane ran ${provider_count:-0} tests; a skipped lane is not a pass (outcome 7)"

# Outcome 8. Proved here rather than delegated to the task under test.
#
# Dropping directories that contain python3 or jq would also drop /usr/bin and
# with it git, making the aggregate fail for the wrong reason. Instead both
# interpreters are shadowed by stubs that refuse to run, so any check that still
# reaches for either fails loudly and everything else is untouched.
absence_root="$(mktemp -d "${TMPDIR:-/tmp}/loopex-m0-absence.XXXXXX")" \
  || fail "could not create an isolated task root for the absence proof (outcome 8)"
trap 'rm -rf "$absence_root"' EXIT
for shadowed in python3 jq; do
  printf '#!/bin/sh\necho "%s is retired; outcome 8 requires its absence" >&2\nexit 127\n' \
    "$shadowed" > "$absence_root/$shadowed"
  chmod +x "$absence_root/$shadowed"
done
if PATH="$absence_root:$PATH" python3 --version >/dev/null 2>&1; then
  fail "could not shadow python3 for the absence proof (outcome 8)"
fi
# Shadowing is defeated by `command -p`, which uses a default PATH, and by an
# inline PATH assignment on the invocation itself. Neither is a PATH lookup the
# shim can intercept, so both are scanned for directly.
if git grep -nE 'command +-p +(python3|jq)|(^|[[:space:]])PATH=[^[:space:]]+ +(python3|jq)' -- \
  scripts .claude .codex .github >/dev/null 2>&1; then
  git grep -nE 'command +-p +(python3|jq)|(^|[[:space:]])PATH=[^[:space:]]+ +(python3|jq)' -- \
    scripts .claude .codex .github >&2
  fail "a shadow-bypassing python3/jq invocation survives (outcome 8)"
fi

# Hook behavior is proved by executing locked fixtures, not by accepting a
# task's exit status. Each fixture is a stdin payload the hook must reject; a
# hook that stops rejecting it has lost a tested behavior, which ADR 0002
# forbids without an explicit disposition.
fixture_root="scripts/fixtures/hook-cases"
[ -d "$fixture_root" ] \
  || fail "no locked hook-behavior fixtures at $fixture_root (outcome 8)"
fixture_count=0
for fixture in "$fixture_root"/*.stdin; do
  [ -f "$fixture" ] || continue
  hook_name="$(basename "$fixture" .stdin)"
  hook_name="${hook_name%%.*}"
  hook_path=".claude/hooks/${hook_name}.sh"
  [ -f "$hook_path" ] || fail "fixture $fixture names no hook at $hook_path (outcome 8)"
  if bash "$hook_path" < "$fixture" >/dev/null 2>&1; then
    fail "$hook_path accepted $fixture; a tested blocking behavior was lost (outcome 8)"
  fi
  fixture_count=$((fixture_count + 1))
done
[ "$fixture_count" -ge 3 ] \
  || fail "only ${fixture_count} hook fixtures executed; each migrated hook needs one (outcome 8)"
PATH="$absence_root:$PATH" bash scripts/check-bootstrap.sh >/dev/null \
  || fail "the aggregate still depends on python3 or jq (outcome 8)"

# Outcome 8 inventory, inspected directly rather than reported by the task.
for retired in \
  scripts/check_status.py \
  scripts/test_check_status.py \
  scripts/check-agent-bootstrap.py
do
  if [ -e "$retired" ]; then
    fail "$retired is still present (outcome 8)"
  fi
done
for residue in \
  scripts/check-status.sh \
  scripts/check-agent-bootstrap.sh \
  .claude/hooks/guard-bash.sh \
  .claude/hooks/after-edit.sh \
  .claude/hooks/guard-filesystem.sh
do
  [ -f "$residue" ] || continue
  if grep -qE '(^|[^[:alnum:]_])(python3|jq)([^[:alnum:]_]|$)' "$residue"; then
    fail "$residue still invokes python3 or jq (outcome 8)"
  fi
done

# Shadowing only intercepts PATH lookups. An absolute or relocated invocation
# would bypass it entirely, so the tracked tree is scanned directly.
if git grep -nE '(/usr/bin/|/usr/local/bin/|/opt/homebrew/bin/|env +)(python3|jq)([^[:alnum:]_]|$)' -- \
  scripts .claude .codex .github >/dev/null 2>&1; then
  git grep -nE '(/usr/bin/|/usr/local/bin/|/opt/homebrew/bin/|env +)(python3|jq)([^[:alnum:]_]|$)' -- \
    scripts .claude .codex .github >&2
  fail "an absolute or env-resolved python3/jq invocation survives shadowing (outcome 8)"
fi

# Outcome 7 evidence. A test count proves a test ran, not that a provider was
# reached, so the lane must retain non-secret provider identity for review.
provider_evidence="docs/evidence/M0-provider.md"
[ -f "$provider_evidence" ] \
  || fail "the real-provider lane retained no evidence at $provider_evidence (outcome 7)"
for required in provider model endpoint; do
  grep -qiE "^- ${required}:" "$provider_evidence" \
    || fail "$provider_evidence does not record ${required} identity (outcome 7)"
done

# Outcomes 4, 5, and 6 require a recorded negative demonstration: the protected
# test must fail when its mechanism is disabled. The runner cannot disable a
# mechanism, so it requires the record and a reviewer judges it.
negatives="docs/evidence/M0-negative-demonstrations.md"
[ -f "$negatives" ] || fail "no negative demonstrations recorded at $negatives"
for outcome in 4 5 6; do
  grep -qE "^## Outcome ${outcome} " "$negatives" \
    || fail "$negatives records no negative demonstration for outcome ${outcome}"
done
if grep -qE '^- (mechanism disabled|observed failure|demonstrated at): —$' "$negatives"; then
  fail "$negatives still has unpopulated negative-demonstration fields"
fi

mix loopex.self_hosting || fail "self-hosting measurement or hook-behavior proof failed (outcome 8)"
mix test || fail "full suite failed"

echo "M0 gate GREEN"
