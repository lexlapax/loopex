#!/usr/bin/env bash
# M1 gate runner.
#
# CONCEPT
#
# Executable acceptance for M1, whose bytes and digest are locked at acceptance.
# It judges mechanics only: commands exited zero, protected selectors ran with
# their minimum counts, locked names exist, retained evidence is present and well
# formed. Whether a demonstration was honest and whether the loop a reader would
# call working is the loop this went green on are review readings.
#
# TECHNICAL DEPTH
#
# M0's checks are invoked rather than reimplemented. Everything this runner adds
# is about M1's own outcomes, because a gate that grows a new checker per
# milestone ends up proving the checkers rather than the product.
#
# The declared red condition is the absence of the working loop: no runtime, no
# store port, no embedded API, no executor, no reference client, and none of the
# eight protected selectors. This must not go green by adding a checker.
set -euo pipefail

fail() {
  echo "M1 gate RED: $1" >&2
  exit 1
}

[ -f mix.exs ] || fail "run from the umbrella root"

# Concept: the milestone's own record decides what the gate is for.
# Technical depth: read from the plan rather than restated here, so a runner
# cannot drift from the outcomes it claims to enforce.
plan="docs/plans/M1.md"
gate="docs/plans/M1-gate.md"
[ -f "$plan" ] || fail "no $plan; the gate has no plan to enforce"
[ -f "$gate" ] || fail "no $gate; the gate has no locked text"

# Real user state is never touched. Recorded before and compared after, the same
# discipline M0 proved, because a run that reaches real state fails regardless of
# every other result.
real_user_state_path="${HOME%/}/.loopex"
real_user_state() {
  if [ -e "$real_user_state_path" ]; then
    find "$real_user_state_path" | sort | shasum -a 256
  else
    echo absent
  fi
}
user_state_before="$(real_user_state)"

# MIX_HOME and HEX_HOME are pinned to the real ones BEFORE HOME moves.
# Relocating HOME alone sends Mix looking for Hex inside the empty isolated
# root, and the run then fails for a missing package manager rather than for
# the behaviour under test -- a gate that goes red for the wrong reason proves
# nothing.
real_home="${HOME%/}"
export MIX_HOME="${MIX_HOME:-$real_home/.mix}"
export HEX_HOME="${HEX_HOME:-$real_home/.hex}"

isolated="$(mktemp -d "${TMPDIR:-/tmp}/loopex-m1-home.XXXXXX")"
trap 'rm -rf "$isolated"' EXIT
export HOME="$isolated/home"
export LOOPEX_HOME="$isolated/home/.loopex"
export LOOPEX_WORKSPACE="$isolated/workspace"
mkdir -p "$HOME" "$LOOPEX_HOME" "$LOOPEX_WORKSPACE"

# Locked commands 1-8 are M0's, invoked unchanged.
mix format --check-formatted || fail "checkpoints must be formatting-clean"
mix compile --warnings-as-errors || fail "checkpoints must be warning-free"
mix loopex.deps_budget || fail "dependency budget or direction is violated"
mix loopex.version_train || fail "applications do not carry one version"
mix loopex.matrix || fail "the running toolchain is not a locked pair, or a lane is unrecorded"
mix loopex.core_only || fail "core does not build and pass against fakes alone"
mix loopex.docs_check || fail "covered public code does not document Concept before Technical depth"
mix loopex.hook_registration || fail "a hook is not registered under its required event and matcher"

# Concept: a selector that does not exist is missing behaviour, not a missing file.
#
# Technical depth: each protected selector runs with a minimum executed count, so
# a file emptied of its cases fails rather than passing vacuously, and each locked
# name must exist exactly. The counts and names are the gate's, read from the
# locked text so the runner and the record cannot disagree.
require_selector() {
  local file="$1" minimum="$2"
  [ -f "$file" ] || fail "no $file; the outcome it proves does not exist yet"

  local output executed
  output="$(mix test "$file" 2>&1)" || fail "$file failed"

  executed="$(printf '%s' "$output" | grep -oE '[0-9]+ (tests?|passed)' | head -1 | grep -oE '^[0-9]+' || true)"
  [ -n "$executed" ] || fail "$file reported no executed count; the run proved nothing"
  [ "$executed" -ge "$minimum" ] \
    || fail "$file executed ${executed} tests, below its locked minimum of ${minimum}"
}

require_named_test() {
  local file="$1" name="$2"
  grep -qF "test \"$name\"" "$file" \
    || fail "$file does not define the locked test \"$name\""
}

require_selector apps/loopex/test/runtime_test.exs 3
require_named_test apps/loopex/test/runtime_test.exs "two runtimes coexist without a global name"
require_named_test apps/loopex/test/runtime_test.exs "a runtime reference is required rather than inferred"

require_selector apps/loopex/test/session_lifecycle_test.exs 4
require_named_test apps/loopex/test/session_lifecycle_test.exs "a session resumes with the durable truth it committed"
require_named_test apps/loopex/test/session_lifecycle_test.exs "a second coordinator cannot own a live session"

require_selector apps/loopex/test/store_conformance_test.exs 5
require_named_test apps/loopex/test/store_conformance_test.exs "every implementation refuses a stale writer at replay"
require_named_test apps/loopex/test/store_conformance_test.exs "a killed writer loses no acknowledged fact"

require_selector apps/loopex/test/embedded_api_test.exs 4
require_named_test apps/loopex/test/embedded_api_test.exs "progress and diagnostics never carry durable truth"

require_selector apps/loopex/test/executor_test.exs 8
require_named_test apps/loopex/test/executor_test.exs "each missing grant element is refused individually"
require_named_test apps/loopex/test/executor_test.exs "one controlled tool executes and commits its effect"

require_selector apps/loopex/test/reference_client_test.exs 2
require_named_test apps/loopex/test/reference_client_test.exs "the client drives the loop through the embedded API only"

require_selector apps/loopex/test/end_to_end_recovery_test.exs 2
require_named_test apps/loopex/test/end_to_end_recovery_test.exs "exactly one dispatch ever carried each effect across the restart"
require_named_test apps/loopex/test/end_to_end_recovery_test.exs "every acknowledged fact survives the restart"

# Concept: the real path is proved by running it, never by tagging it.
#
# Technical depth: the lane is excluded by default and invoked explicitly. An
# absent credential reports evidence unavailable and fails; a skipped lane is not
# a pass, which is the fail-closed direction M0 established.
provider_file="apps/loopex/test/real_model_lane_test.exs"
[ -f "$provider_file" ] || fail "no $provider_file; the real model path does not exist yet"
require_named_test "$provider_file" "one real model call completes inside a session"
mix test "$provider_file" --only real_provider >/dev/null 2>&1 \
  || fail "the real-provider lane failed or its evidence is unavailable"

# Retained evidence must be present and well formed. Exactly one of each field per
# outcome section: a duplicate field lets a real value sit beside an unfilled dash.
negatives="docs/evidence/M1-negative-demonstrations.md"
[ -f "$negatives" ] || fail "no $negatives; constitutional outcomes need negative demonstrations"

for outcome in 2 3 6 8; do
  sections="$(grep -cE "^## Outcome ${outcome}([[:space:]]|$)" "$negatives" || true)"
  [ "${sections:-0}" -eq 1 ] \
    || fail "$negatives has ${sections:-0} sections for outcome ${outcome}; exactly one is required"

  section="$(awk -v n="$outcome" '
    $0 ~ "^## Outcome " n "([ \t]|$)" { capture = 1; next }
    /^## / { capture = 0 }
    capture { print }
  ' "$negatives")"

  for field in "mechanism disabled" "observed failure" "demonstrated at"; do
    total="$(printf '%s\n' "$section" | grep -ciE "^- ${field}:" || true)"
    filled="$(printf '%s\n' "$section" | grep -ciE "^- ${field}:[[:space:]]*[^[:alnum:]]*[[:alnum:]]" || true)"
    [ "${total:-0}" -eq 1 ] \
      || fail "$negatives outcome ${outcome} has ${total:-0} \"${field}\" entries; exactly one is required"
    [ "${filled:-0}" -eq 1 ] \
      || fail "$negatives outcome ${outcome} does not record \"${field}\""
  done
done

for retained in docs/evidence/M1-toolchain-matrix.md docs/evidence/M1-provider.md; do
  [ -f "$retained" ] || fail "no $retained; the outcome it retains has no evidence"
done

mix test || fail "full suite failed"

[ "$(real_user_state)" = "$user_state_before" ] \
  || fail "the run reached real user state despite the relocated HOME"

echo "M1 gate GREEN"
