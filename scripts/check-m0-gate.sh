#!/usr/bin/env bash
# Executable acceptance gate for milestone M0.
#
# The locked contract is docs/plans/M0-gate.md; this runner executes it. It is
# deliberately NOT part of scripts/check-bootstrap.sh: the bootstrap aggregate
# must stay green for the whole milestone while this gate stays red until the
# declared outcomes exist.
#
# WHAT THIS RUNNER IS FOR
#
# It defends against accident and drift: a command that stops passing, a
# protected test renamed or skipped, a dependency creeping back, an evidence
# record never filled in. Those failures happen without anyone intending them,
# and a script catches them reliably.
#
# It does not defend against a dishonest implementer. Earlier versions tried,
# and every mechanical control had a bypass, because a script cannot tell
# whether a test asserts anything, whether a fixture is real, or whether a
# report is truthful. Those judgments belong to independent review of the
# implementation at the closure candidate, which the plan names explicitly.
#
# Every command form here was executed against a disposable umbrella scaffold
# before the gate was proposed. An umbrella root runs no tests of its own, so
# selectors are application-relative.
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>&1 | grep -v 'DARWIN_USER_TEMP_DIR')"

fail() {
  echo "M0 gate RED: $1" >&2
  exit 1
}

# Drift protection. A protected test that disappears or is renamed is caught.
# This does not prove the test asserts anything; review owns that.
require_named_test() {
  local file="$1" name="$2"
  [ -f "$file" ] || fail "protected selector $file is missing"
  grep -qF "test \"${name}\"" "$file" \
    || fail "$file no longer contains the locked test \"${name}\""
}

# ExUnit counts skipped tests inside its total but reports excluded ones
# separately: "1 test, 0 failures (1 excluded)". Executed is total minus
# skipped only; subtracting excluded as well would reject a valid file that
# holds both tagged and ordinary tests.
summary_field() {
  printf '%s' "$1" | grep -oE "[0-9]+ $2" | tail -1 | grep -oE '[0-9]+' || true
}

executed_tests() {
  local output="$1" total skipped
  total="$(printf '%s' "$output" | grep -oE '[0-9]+ (test|tests),' | tail -1 | grep -oE '[0-9]+' || true)"
  [ -n "$total" ] || return 1
  skipped="$(summary_field "$output" skipped)"
  echo $((total - ${skipped:-0}))
}

run_selector() {
  local file="$1" minimum="$2" output executed skipped
  if ! output="$(mix test "$file" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "$file failed"
  fi
  skipped="$(summary_field "$output" skipped)"
  if [ "${skipped:-0}" -ne 0 ]; then
    fail "$file skipped ${skipped} tests; a protected selector may not skip"
  fi
  executed="$(executed_tests "$output")" \
    || fail "$file produced no parsable test count"
  [ "$executed" -ge "$minimum" ] \
    || fail "$file executed ${executed} tests, fewer than the locked minimum ${minimum}"
}

# An evidence record must exist and be filled in. An unpopulated field is the
# accident this catches; whether the content is truthful is a review judgment.
require_populated() {
  local file="$1" label="$2"
  grep -qiE "^- ${label}: *[^ ]" "$file" \
    && ! grep -qiE "^- ${label}: *—" "$file" \
    || fail "$file does not record ${label}"
}

command -v mix >/dev/null 2>&1 || fail "mix is not installed; the accepted toolchain is required"

[ -f mix.exs ] || fail "no umbrella project at mix.exs (outcome 1)"
[ -f apps/loopex_protocol/mix.exs ] || fail "no contract application at apps/loopex_protocol (outcome 1)"
[ -f apps/loopex/mix.exs ] || fail "no runtime application at apps/loopex (outcome 1)"
[ -f .tool-versions ] || fail "no locked toolchain matrix at .tool-versions (outcome 3)"

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
mix loopex.matrix || fail "the running toolchain is not a locked pair, or a lane is unrecorded (outcome 3)"
mix loopex.core_only || fail "core-only, fakes-only lane failed (outcome 9)"
mix loopex.docs_check || fail "compiled dual-depth documentation check failed (outcome 10)"

run_selector apps/loopex/test/deps_budget_test.exs 3
run_selector apps/loopex/test/core_only_test.exs 2
run_selector apps/loopex/test/journal_replay_test.exs 2
run_selector apps/loopex/test/fencing_test.exs 2
run_selector apps/loopex/test/vm_code_spike_test.exs 1

# A named hook that simply disappears is behaviour loss, which ADR 0002 allows
# only through an explicit disposition. Absence therefore fails here rather than
# skipping the check.
hook=".claude/hooks/deps-budget.sh"
[ -f "$hook" ] || fail "$hook is missing; removing a tested hook needs a recorded disposition (outcome 2)"
grep -qE 'mix +loopex\.deps_budget' "$hook" \
  || fail "$hook does not call the repository dependency-budget command (outcome 2)"
if grep -qE 'apps/loopex/mix\.exs|defp? deps' "$hook"; then
  fail "$hook still carries inline budget logic instead of calling the command (outcome 2)"
fi

provider_output="$(mix test apps/loopex_llm_reqllm/test/provider_test.exs --only real_provider 2>&1)" \
  || { printf '%s\n' "$provider_output" >&2; fail "real-provider lane failed (outcome 7)"; }
provider_skipped="$(summary_field "$provider_output" skipped)"
if [ "${provider_skipped:-0}" -ne 0 ]; then
  fail "real-provider lane skipped ${provider_skipped} tests; a protected selector may not skip (outcome 7)"
fi
provider_executed="$(executed_tests "$provider_output")" \
  || fail "real-provider lane produced no parsable test count (outcome 7)"
[ "$provider_executed" -ge 1 ] \
  || fail "real-provider lane executed ${provider_executed} tests; a skipped or empty lane is not a pass (outcome 7)"

provider_evidence="docs/evidence/M0-provider.md"
[ -f "$provider_evidence" ] || fail "the real-provider lane retained no evidence at $provider_evidence (outcome 7)"
for field in provider model endpoint recorded; do
  require_populated "$provider_evidence" "$field"
done

negatives="docs/evidence/M0-negative-demonstrations.md"
[ -f "$negatives" ] || fail "no negative demonstrations recorded at $negatives"
for outcome in 4 5 6; do
  grep -qE "^## Outcome ${outcome} " "$negatives" \
    || fail "$negatives records no negative demonstration for outcome ${outcome}"
done
# Fields are validated inside each outcome section. A global count would let
# three entries under one outcome satisfy all three, and concatenating duplicate
# sections would let a populated one cover a placeholder one, so exactly one
# section per outcome is required.
for outcome in 4 5 6; do
  sections="$(grep -cE "^## Outcome ${outcome} " "$negatives" || true)"
  [ "${sections:-0}" -eq 1 ] \
    || fail "$negatives has ${sections:-0} sections for outcome ${outcome}; exactly one is required"
  section="$(awk -v n="$outcome" '
    $0 ~ "^## Outcome " n " " { capture = 1; next }
    /^## / { capture = 0 }
    capture { print }
  ' "$negatives")"
  for field in "mechanism disabled" "observed failure" "demonstrated at"; do
    printf '%s\n' "$section" | grep -qiE "^- ${field}: *[^ —]" \
      || fail "$negatives outcome ${outcome} does not record \"${field}\""
  done
done

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
PATH="$absence_root:$PATH" bash scripts/check-bootstrap.sh >/dev/null \
  || fail "the aggregate still depends on python3 or jq (outcome 8)"

for retired in \
  scripts/check_status.py \
  scripts/test_check_status.py \
  scripts/check-agent-bootstrap.py
do
  if [ -e "$retired" ]; then
    fail "$retired is still present (outcome 8)"
  fi
done

# The scan covers apps/** too, because the replacement lives there and an
# absolute invocation would bypass both the stubs and a scripts-only scan.
bypass='(/usr/bin/|/usr/local/bin/|/opt/homebrew/bin/|env +|command +-p +|(^|[[:space:]])PATH=[^[:space:]]+ +)(python3|jq)([^[:alnum:]_]|$)'
if git grep -nE "$bypass" -- scripts apps .claude .codex .github >/dev/null 2>&1; then
  git grep -nE "$bypass" -- scripts apps .claude .codex .github >&2
  fail "a shadow-bypassing python3/jq invocation survives (outcome 8)"
fi
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

# Each named hook is executed against its own fixture. Whether a fixture is
# meaningful is a review judgment; that the hook still rejects it is not.
fixture_root="scripts/fixtures/hook-cases"
[ -d "$fixture_root" ] || fail "no hook-behavior fixtures at $fixture_root (outcome 8)"
for hook_name in guard-bash guard-filesystem after-edit; do
  hook_path=".claude/hooks/${hook_name}.sh"
  [ -f "$hook_path" ] \
    || fail "$hook_path is missing; removing a tested hook needs a recorded disposition (outcome 8)"
  fixture="$fixture_root/${hook_name}.stdin"
  [ -f "$fixture" ] || fail "no fixture at $fixture for $hook_path (outcome 8)"
  if bash "$hook_path" < "$fixture" >/dev/null 2>&1; then
    fail "$hook_path accepted $fixture; a tested blocking behavior was lost (outcome 8)"
  fi
done

# The replacement must preserve the history guarantees the retired checker had.
# Whether a case is meaningful is a review judgment; whether it ran is not, so
# these are executed tests with locked names rather than files that merely exist.
require_named_test apps/loopex/test/history_anchoring_test.exs "a mutated then restored artifact is rejected"
require_named_test apps/loopex/test/history_anchoring_test.exs "a merge parent carrying a mutated artifact is rejected"
require_named_test apps/loopex/test/history_anchoring_test.exs "an artifact missing from history is rejected"
run_selector apps/loopex/test/history_anchoring_test.exs 3

mix loopex.self_hosting || fail "self-hosting measurement or report failed (outcome 8)"

self_hosting_report="docs/evidence/M0-self-hosting.md"
[ -f "$self_hosting_report" ] || fail "no self-hosting report at $self_hosting_report (outcome 8)"
require_populated "$self_hosting_report" "measured size"
require_populated "$self_hosting_report" "dropped behaviors"
require_populated "$self_hosting_report" "recorded"

mix test || fail "full suite failed"

echo "M0 gate GREEN"
