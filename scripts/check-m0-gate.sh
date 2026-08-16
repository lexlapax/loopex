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
  local file="$1" label="$2" total filled
  total="$(grep -ciE "^- ${label}:" "$file" || true)"
  filled="$(grep -ciE "^- ${label}:[[:space:]]*[^[:space:]—]" "$file" || true)"
  [ "${total:-0}" -eq 1 ] \
    || fail "$file has ${total:-0} \"${label}\" entries; exactly one is required"
  [ "${filled:-0}" -eq 1 ] \
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
require_named_test apps/loopex/test/format_scope_test.exs "a root-only formatter configuration is rejected"
require_named_test apps/loopex/test/hook_registration_test.exs "a hook registered under the wrong event is rejected"
require_named_test apps/loopex/test/hook_registration_test.exs "a hook registered with the wrong matcher is rejected"
require_named_test apps/loopex/test/journal_replay_test.exs "replay after an induced restart reconstructs the same durable state"
require_named_test apps/loopex/test/fencing_test.exs "commit_unknown is fenced and never dispatched a second time"
require_named_test apps/loopex/test/fencing_test.exs "a stale completion is rejected after a coordinator restart"
require_named_test apps/loopex/test/vm_code_spike_test.exs "a trusted generation loads and rolls back in an isolated VM"

# Everything above this line only reads the checkout, so an enforced read-only
# reviewer reaches the declared red condition instead of failing on temporary
# storage. Everything below runs Mix or writes, and needs isolation first.
# The provider credential is removed from the environment for the entire run and
# handed only to the explicit real-provider command. Unsetting it just before the
# final suite would leave every earlier selector, task, and compile step holding
# it, so an accidentally untagged provider call anywhere earlier would still
# reach a provider.
set +a  # an inherited allexport would export the holding variable too
provider_key_value="${LOOPEX_PROVIDER_API_KEY:-}"
export -n provider_key_value 2>/dev/null || true
unset LOOPEX_PROVIDER_API_KEY
# Prove neither name reaches a child process, rather than assuming it.
for leaked in LOOPEX_PROVIDER_API_KEY provider_key_value; do
  if env | grep -qE "^${leaked}="; then
    fail "$leaked is exported; the credential would reach every Mix process"
  fi
done

# Containment. HOME is relocated into an isolated root so a helper reaching for
# the real user state directory finds nothing; that is fail-before-touch rather
# than notice-afterwards. Package-manager caches are excluded deliberately, so
# isolation costs no refetch.
user_state_dirname=".loopex"
real_home="${HOME%/}"
real_user_state_path="$real_home/$user_state_dirname"

# Every inherited root is validated before anything is allocated or run. A
# TMPDIR, MIX_HOME, or HEX_HOME pointed inside the protected directory would
# otherwise place the isolated root, or Mix's own writes, inside the very state
# the relocation exists to protect.
# Lexical comparison accepts .., relative paths, and symlinks into the protected
# directory, so both sides are resolved physically first. A path that does not
# exist yet resolves through its deepest existing ancestor.
resolve_physical() {
  local target="$1" suffix="" link guard=0
  case "$target" in
    /*) ;;
    *) target="$PWD/$target" ;;
  esac
  # Symlinks are followed before walking up, including dangling ones: a link
  # aimed at a protected directory that does not exist yet would otherwise be
  # walked past and the alias lost.
  while [ "$guard" -lt 64 ]; do
    guard=$((guard + 1))
    if [ -L "$target" ]; then
      link="$(readlink "$target")"
      case "$link" in
        /*) target="$link" ;;
        *) target="$(dirname "$target")/$link" ;;
      esac
      continue
    fi
    [ -d "$target" ] && break
    [ "$target" = "/" ] && break
    suffix="/$(basename "$target")$suffix"
    target="$(dirname "$target")"
  done
  printf '%s%s' "$(cd "$target" 2>/dev/null && pwd -P || printf '%s' "$target")" "$suffix"
}
protected_resolved="$(resolve_physical "$real_user_state_path")"
outside_protected_state() {
  local candidate
  candidate="$(resolve_physical "$1")"
  case "${candidate%/}/" in
    "$protected_resolved"/*|"$protected_resolved"/) return 1 ;;
  esac
  return 0
}
for inherited in "${TMPDIR:-/tmp}" "${MIX_HOME:-$real_home/.mix}" "${HEX_HOME:-$real_home/.hex}"; do
  outside_protected_state "$inherited" \
    || fail "$inherited is inside the protected user state directory; refusing to run"
done

isolated_root="$(mktemp -d "${TMPDIR:-/tmp}/loopex-m0-home.XXXXXX")" \
  || fail "could not create an isolated LOOPEX_HOME for the run"
absence_root=""
trap 'rm -rf "$isolated_root" ${absence_root:+"$absence_root"}' EXIT

export MIX_HOME="${MIX_HOME:-$real_home/.mix}"
export HEX_HOME="${HEX_HOME:-$real_home/.hex}"
export HOME="$isolated_root/home"
export LOOPEX_HOME="$isolated_root/home/$user_state_dirname"
export LOOPEX_WORKSPACE="$isolated_root/workspace"
mkdir -p "$HOME" "$LOOPEX_HOME" "$LOOPEX_WORKSPACE"

# Defense in depth only. Containment above is the safety property; this catches
# a path that escaped it and carries no claim of its own.
real_user_state() {
  if [ -e "$real_user_state_path" ]; then
    find "$real_user_state_path" -type f -exec shasum -a 256 {} + 2>/dev/null | sort | shasum -a 256
  else
    echo absent
  fi
}
user_state_before="$(real_user_state)"

[ -f .formatter.exs ] || fail "no .formatter.exs; formatting scope would be unbound (outcome 1)"
# A text search over .formatter.exs passes on an unrelated binding that merely
# contains an apps glob while the returned configuration is root-only. The task
# evaluates the effective configuration and asserts application sources are in
# its resolved input set.
mix loopex.format_scope \
  || fail "the effective formatter configuration does not cover application sources (outcome 1)"
mix format --check-formatted || fail "formatting is not clean"
mix compile --warnings-as-errors || fail "compilation is not warning-free"
mix loopex.deps_budget || fail "dependency budget or direction violated (outcome 1)"
mix loopex.version_train || fail "applications do not carry one version (outcome 1)"
mix loopex.matrix || fail "the running toolchain is not a locked pair, or a lane is unrecorded (outcome 3)"
mix loopex.core_only || fail "core-only, fakes-only lane failed (outcome 9)"
mix loopex.docs_check || fail "compiled dual-depth documentation check failed (outcome 10)"

run_selector apps/loopex/test/deps_budget_test.exs 3
run_selector apps/loopex/test/core_only_test.exs 2
run_selector apps/loopex/test/format_scope_test.exs 1
run_selector apps/loopex/test/hook_registration_test.exs 2
run_selector apps/loopex/test/journal_replay_test.exs 2
run_selector apps/loopex/test/fencing_test.exs 2
run_selector apps/loopex/test/vm_code_spike_test.exs 1

# A named hook that simply disappears is behaviour loss, which ADR 0002 allows
# only through an explicit disposition. Absence therefore fails here rather than
# skipping the check.
hook=".claude/hooks/deps-budget.sh"
[ -f "$hook" ] || fail "$hook is missing; removing a tested hook needs a recorded disposition (outcome 2)"
# Without this, a non-executable hook exits 126 and after-edit's `|| exit 2`
# turns that into the blocking status the fixture requires, while the budget
# command never ran.
[ -x "$hook" ] || fail "$hook is not executable; after-edit would report a block it never performed (outcome 2)"
grep -qE 'mix +loopex\.deps_budget' "$hook" \
  || fail "$hook does not call the repository dependency-budget command (outcome 2)"
if grep -qE 'apps/loopex/mix\.exs|defp? deps' "$hook"; then
  fail "$hook still carries inline budget logic instead of calling the command (outcome 2)"
fi

provider_output="$(env ${provider_key_value:+LOOPEX_PROVIDER_API_KEY="$provider_key_value"} \
  mix test apps/loopex_llm_reqllm/test/provider_test.exs --only real_provider 2>&1)" \
  || { printf '%s\n' "$provider_output" >&2; fail "real-provider lane failed (outcome 7)"; }
provider_skipped="$(summary_field "$provider_output" skipped)"
if [ "${provider_skipped:-0}" -ne 0 ]; then
  fail "real-provider lane skipped ${provider_skipped} tests; a protected selector may not skip (outcome 7)"
fi
provider_executed="$(executed_tests "$provider_output")" \
  || fail "real-provider lane produced no parsable test count (outcome 7)"
[ "$provider_executed" -ge 1 ] \
  || fail "real-provider lane executed ${provider_executed} tests; a skipped or empty lane is not a pass (outcome 7)"

# The gate claims this lane runs only when invoked explicitly. Prove it: an
# unfiltered run of the same file must execute none of its tagged tests,
# otherwise the full suite below would reach a real provider again.
default_output="$(mix test apps/loopex_llm_reqllm/test/provider_test.exs 2>&1)" \
  || { printf '%s\n' "$default_output" >&2; fail "the provider file fails in the default suite (outcome 7)"; }
default_excluded="$(summary_field "$default_output" excluded)"
default_executed="$(executed_tests "$default_output")" \
  || fail "the provider file produced no parsable test count in the default suite (outcome 7)"
# The file holds only real_provider-tagged tests, so an unfiltered run must
# execute none of them. Requiring "something was excluded" would pass while an
# unrelated tag supplied the exclusion and the provider test still ran.
[ "$default_executed" -eq 0 ] \
  || fail "the provider file executed ${default_executed} tests unfiltered; real_provider is not excluded by default (outcome 7)"
[ "${default_excluded:-0}" -ge 1 ] \
  || fail "the provider file declares no excluded tests; it must hold only real_provider-tagged tests (outcome 7)"

provider_evidence="docs/evidence/M0-provider.md"
[ -f "$provider_evidence" ] || fail "the real-provider lane retained no evidence at $provider_evidence (outcome 7)"
for field in provider model endpoint recorded; do
  require_populated "$provider_evidence" "$field"
done

negatives="docs/evidence/M0-negative-demonstrations.md"
[ -f "$negatives" ] || fail "no negative demonstrations recorded at $negatives"
for outcome in 4 5 6; do
  grep -qE "^## Outcome ${outcome}([[:space:]]|$)" "$negatives" \
    || fail "$negatives records no negative demonstration for outcome ${outcome}"
done
# Fields are validated inside each outcome section. A global count would let
# three entries under one outcome satisfy all three, and concatenating duplicate
# sections would let a populated one cover a placeholder one, so exactly one
# section per outcome is required.
for outcome in 4 5 6; do
  sections="$(grep -cE "^## Outcome ${outcome}([[:space:]]|$)" "$negatives" || true)"
  [ "${sections:-0}" -eq 1 ] \
    || fail "$negatives has ${sections:-0} sections for outcome ${outcome}; exactly one is required"
  section="$(awk -v n="$outcome" '
    $0 ~ "^## Outcome " n "([ \t]|$)" { capture = 1; next }
    /^## / { capture = 0 }
    capture { print }
  ' "$negatives")"
  for field in "mechanism disabled" "observed failure" "demonstrated at"; do
    # Exactly one occurrence, and it must be populated. Requiring "at least one
    # populated" lets a real value sit beside a placeholder and pass.
    total="$(printf '%s\n' "$section" | grep -ciE "^- ${field}:" || true)"
    filled="$(printf '%s\n' "$section" | grep -ciE "^- ${field}:[[:space:]]*[^[:space:]—]" || true)"
    [ "${total:-0}" -eq 1 ] \
      || fail "$negatives outcome ${outcome} has ${total:-0} \"${field}\" entries; exactly one is required"
    [ "${filled:-0}" -eq 1 ] \
      || fail "$negatives outcome ${outcome} does not record \"${field}\""
  done
done

absence_root="$(mktemp -d "${TMPDIR:-/tmp}/loopex-m0-absence.XXXXXX")" \
  || fail "could not create an isolated task root for the absence proof (outcome 8)"
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
# Any absolute path, any env invocation with or without flags, any command -p
# or -pv, and any run prefixed by one or more assignments.
# Any path segment ending in the interpreter, however it is quoted or prefixed:
# absolute paths, exec, env with flags or assignments, command -p/-pv, and
# assignment-prefixed runs. Deliberate obfuscation beyond this is a dishonest
# implementer, which the stated boundary assigns to closure review.
bypass='(/|(^|[[:space:]])(command|exec)([[:space:]]+-[^[:space:]]*)*[[:space:]]+["'"'"']?|env([[:space:]]+[^[:space:]]+)*[[:space:]]+["'"'"']?|(^|[[:space:]])([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+["'"'"']?)(python3|jq)([^[:alnum:]_]|$)'
# This runner is excluded from its own scan: it necessarily names both
# interpreters to shadow and report them. Drift in it is caught instead by the
# bound-artifact digest, which the status check verifies at every revision.
scan_paths="scripts apps config .claude .codex .github mix.exs .formatter.exs
:(exclude)scripts/check-m0-gate.sh"
if git grep -nE "$bypass" -- $scan_paths >/dev/null 2>&1; then
  git grep -nE "$bypass" -- $scan_paths >&2
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
# A hook file that still blocks is worthless if the client no longer invokes it,
# so registration is verified too. Independent greps for each event and script
# name would pass with two hooks swapped between event blocks, and bash cannot
# parse JSON once jq is retired, so this is a Mix obligation: the task asserts
# each hook is registered under its required event and matcher.
[ -f .claude/settings.json ] || fail "no .claude/settings.json; hook registration is unverifiable (outcome 8)"
mix loopex.hook_registration \
  || fail "a hook is not registered under its required event and matcher (outcome 8)"

fixture_root="scripts/fixtures/hook-cases"
[ -d "$fixture_root" ] || fail "no hook-behavior fixtures at $fixture_root (outcome 8)"
for hook_name in guard-bash guard-filesystem after-edit; do
  hook_path=".claude/hooks/${hook_name}.sh"
  [ -f "$hook_path" ] \
    || fail "$hook_path is missing; removing a tested hook needs a recorded disposition (outcome 8)"
  fixture="$fixture_root/${hook_name}.stdin"
  [ -f "$fixture" ] || fail "no fixture at $fixture for $hook_path (outcome 8)"
  # Invoked as the configured executable, not through bash, so a lost execute
  # bit or broken shebang is caught. Claude Code treats exit 2 as blocking and
  # other nonzero statuses as non-blocking errors, so only 2 counts as a block.
  [ -x "$hook_path" ] || fail "$hook_path is not executable; the client would not run it (outcome 8)"
  set +e
  "$hook_path" < "$fixture" >/dev/null 2>&1
  hook_status=$?
  set -e
  [ "$hook_status" -eq 2 ] \
    || fail "$hook_path exited ${hook_status} on $fixture; only 2 blocks in the client (outcome 8)"
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

# The credential was removed from the environment at the top of this run, so the
# full suite cannot reach a provider regardless of how a test is tagged.
mix test || fail "full suite failed"

# Defense in depth: containment should have made this unreachable.
[ "$(real_user_state)" = "$user_state_before" ] \
  || fail "the run reached real user state despite the relocated HOME"

echo "M0 gate GREEN"
