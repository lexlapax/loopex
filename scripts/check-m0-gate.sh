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

fail() {
  echo "M0 gate RED: $1" >&2
  exit 1
}

# The provider credential is contained before this script starts its FIRST child
# process. Scrubbing later would be a notice-afterwards check: every git, grep,
# and Mix process spawned before the scrub would already have inherited the
# value, and an assertion made after them cannot detect that. The credential is
# removed for the entire run and handed only to the explicit real-provider
# command; unsetting it just before the final suite would leave every earlier
# selector, task, and compile step holding it.
set +a  # an inherited allexport would export the holding variable too
provider_key_value="${LOOPEX_PROVIDER_API_KEY:-}"
export -n provider_key_value 2>/dev/null || true
unset LOOPEX_PROVIDER_API_KEY
# Prove neither name reaches a child process, rather than assuming it. This is
# itself the first child, and it runs only after both are contained.
for leaked in LOOPEX_PROVIDER_API_KEY provider_key_value; do
  if env | grep -qE "^${leaked}="; then
    fail "$leaked is exported; the credential would reach every child process"
  fi
done

# Diagnostic output from the provider lane is redacted before it is printed. The
# lane captures stdout and stderr together, so a provider or test that echoes the
# key into an error message would otherwise put it straight into operator and CI
# output -- a log is exactly one of the planes the credential may never reach.
# Substitution is done in-process with parameter expansion rather than by piping
# through sed, because passing the value as an argument would expose it in the
# process table.
# AMENDMENT 4. The pattern is quoted, so the credential is matched literally.
# Unquoted, ${var//$pattern/...} treats the credential as a glob: a key containing
# [, ? or * matched something other than itself and was printed unredacted. The
# gate places no alphabet restriction on a credential, so it cannot assume one.
redacted() {
  if [ -n "$provider_key_value" ]; then
    printf '%s\n' "${1//"$provider_key_value"/[redacted credential]}"
  else
    printf '%s\n' "$1"
  fi
}

cd "$(git rev-parse --show-toplevel 2>&1 | grep -v 'DARWIN_USER_TEMP_DIR')"

# Drift protection. A protected test that disappears or is renamed is caught.
# This does not prove the test asserts anything; review owns that.
require_named_test() {
  local file="$1" name="$2"
  [ -f "$file" ] || fail "protected selector $file is missing"
  grep -qF "test \"${name}\"" "$file" \
    || fail "$file no longer contains the locked test \"${name}\""
}

# AMENDMENTS 1 AND 2. ExUnit's summary format differs between the two locked pairs,
# so both are parsed. Elixir 1.17 (the floor lane) prints a counted total with
# BOTH skipped and excluded inside it. Amendment 1 asserted excluded sat outside
# the total; the floor lane disproved that, and Amendment 2 corrected the
# arithmetic. The shapes are:
#
#   2 tests, 0 failures                          <- executed 2
#   1 test, 0 failures, 1 excluded                <- executed 0
#   4 tests, 0 failures, 1 excluded, 1 skipped    <- executed 2
#   3 tests, 1 failure, 1 excluded                <- executed 2
#
# Elixir 1.20 (the current lane) prints named counts and no total at all:
#
#   Result: 2 passed
#   Result: 2 passed, 1 skipped, 1 excluded
#   Result: 1/2 passed                        <- executed 2, one of them failed
#   Result: 0 tests, 4 excluded               <- nothing ran
#
# The original runner parsed only the 1.17 shape, so on the current pair every
# protected selector reported "no parsable test count" and the gate could never
# go green on its own locked toolchain. It failed closed, which was safe, but it
# was unsatisfiable. Supporting one shape and not the other would move that
# defect to the floor lane rather than remove it.
# AMENDMENT 4. grep exits 1 for no match and above 1 for an error; `|| true`
# treated both as "zero of them". A broken extraction then read as "no skipped
# tests" and a protected selector could pass on unavailable evidence.
summary_field() {
  local matched status
  matched="$(printf '%s' "$1" | grep -oE "[0-9]+ $2")" || status=$?
  case "${status:-0}" in
    0) printf '%s' "$matched" | tail -1 | grep -oE '[0-9]+' ;;
    1) : ;;
    *) fail "could not read the \"$2\" field of a test summary (grep exit ${status}); evidence is unavailable" ;;
  esac
}

# Executed means ran to a verdict: passed or failed, never skipped or excluded.
# On 1.17 that is the total minus skipped AND excluded, because both sit inside it.
# On 1.20 the counts are already separate, so passed is read directly and the
# "X/N passed" failure form reports N, since all N ran.
executed_tests() {
  local output="$1" line total skipped excluded
  line="$(printf '%s' "$output" \
    | grep -E '^Result:|[0-9]+ (test|tests), [0-9]+ (failure|failures)' \
    | tail -1)"
  [ -n "$line" ] || return 1
  case "$line" in
    Result:*[0-9]/[0-9]*passed*)
      printf '%s\n' "$line" | sed -E 's|^Result: [0-9]+/([0-9]+) passed.*|\1|'
      ;;
    Result:*passed*)
      printf '%s\n' "$line" | sed -E 's|^Result: ([0-9]+) passed.*|\1|'
      ;;
    Result:*test*)
      printf '%s\n' "$line" | sed -E 's|^Result: ([0-9]+) tests?.*|\1|'
      ;;
    *)
      # AMENDMENT 2. Excluded is subtracted as well. Amendment 1 subtracted only
      # skipped, on the belief that 1.17 reports excluded outside its total. The
      # floor lane disproved that: on Elixir 1.17.0 a file with two passing, one
      # skipped and one excluded test reports "4 tests, 0 failures, 1 excluded,
      # 1 skipped", so both sit inside the total and executed is total minus both.
      total="$(printf '%s' "$line" | grep -oE '[0-9]+ (test|tests),' | grep -oE '[0-9]+')"
      [ -n "$total" ] || return 1
      skipped="$(summary_field "$line" skipped)"
      excluded="$(summary_field "$line" excluded)"
      echo $((total - ${skipped:-0} - ${excluded:-0}))
      ;;
  esac
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
# A populated value must contain an alphanumeric character. Rejecting only the
# template's em dash left every other placeholder passing: "- provider: -",
# "?", and "TBD"-by-punctuation all read as filled while recording nothing.
require_populated() {
  local file="$1" label="$2" total filled
  total="$(grep -ciE "^- ${label}:" "$file" || true)"
  filled="$(grep -ciE "^- ${label}:[[:space:]]*[^[:alnum:]]*[[:alnum:]]" "$file" || true)"
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
  local remaining="$1" resolved="" comp link guard=0
  case "$remaining" in
    /*) ;;
    *) remaining="$PWD/$remaining" ;;
  esac
  # Components are resolved left to right against an already-physical prefix.
  # Resolving the whole string at the end cannot work: `cd` without -P collapses
  # ".." lexically, so ~/link/../.. is reduced by text before the kernel ever
  # sees it, and an intermediate symlink is discarded along with the alias it
  # carried. Following each link as it is reached, and taking ".." from the
  # resolved prefix, gives the path the kernel would actually open.
  # The guard counts symlink expansions only, which is the sole way this loop
  # fails to make progress. Counting components instead let a path padded with
  # "./" exhaust the budget: the loop returned the prefix it had resolved so far,
  # and a partially resolved path silently compared as outside. Component
  # consumption always terminates, so it needs no budget.
  while [ -n "$remaining" ]; do
    remaining="${remaining#/}"
    case "$remaining" in
      */*)
        comp="${remaining%%/*}"
        remaining="/${remaining#*/}"
        ;;
      *)
        comp="$remaining"
        remaining=""
        ;;
    esac
    case "$comp" in
      "" | .) continue ;;
      ..)
        resolved="${resolved%/*}"
        continue
        ;;
    esac
    # -L is true for a dangling link too, so a link aimed at a directory that
    # does not exist yet is still followed rather than walked past.
    if [ -L "$resolved/$comp" ]; then
      guard=$((guard + 1))
      # Exhaustion returns nothing rather than a partial prefix. A truncated
      # path is not a safe answer to "is this inside protected state"; the
      # caller treats an empty result as unresolvable and refuses.
      [ "$guard" -le 64 ] || { printf '%s' ""; return 0; }
      link="$(readlink "$resolved/$comp")"
      case "$link" in
        /*)
          resolved=""
          remaining="$link$remaining"
          ;;
        *)
          remaining="/$link$remaining"
          ;;
      esac
    else
      resolved="$resolved/$comp"
    fi
  done
  printf '%s' "${resolved:-/}"
}
protected_resolved="$(resolve_physical "$real_user_state_path")"
[ -n "$protected_resolved" ] || fail "the protected state path could not be resolved; refusing to run"

# Textual comparison of resolved paths is necessary but not sufficient on a real
# macOS host. Two ordinary aliases defeat it: /System/Volumes/Data/Users/<user>
# is a firmlink to /Users/<user> and shares its device and inode, and the default
# filesystem folds case, so an uppercase spelling of the state directory names
# the same directory. Identity is therefore compared by device and inode as well,
# and the textual comparison is done case-insensitively.
# Exit 1 means the path does not exist, which legitimately has no identity.
# Exit 2 means it exists but its identity could not be read: that is unavailable
# evidence, and the caller refuses rather than silently skipping the comparison
# and falling back to text.
node_id() {
  [ -e "$1" ] || return 1
  stat -f '%d:%i' "$1" 2>/dev/null && return 0
  stat -c '%d:%i' "$1" 2>/dev/null && return 0
  return 2
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

protected_parent="${protected_resolved%/*}"
[ -n "$protected_parent" ] || protected_parent=/
protected_name="${protected_resolved##*/}"
protected_parent_id="$(node_id "$protected_parent")" || {
  [ "$?" -eq 1 ] || fail "the identity of $protected_parent could not be read; containment evidence is unavailable"
  protected_parent_id=""
}
protected_id="$(node_id "$protected_resolved")" || {
  [ "$?" -eq 1 ] || fail "the identity of $protected_resolved could not be read; containment evidence is unavailable"
  protected_id=""
}
protected_lc="$(lower "${protected_resolved%/}")"
protected_name_lc="$(lower "$protected_name")"

outside_protected_state() {
  local candidate cand_lc prefix rest base parent id
  candidate="$(resolve_physical "$1")"
  # An unresolvable path is not a safe answer; refuse rather than assume outside.
  [ -n "$candidate" ] || return 1
  cand_lc="$(lower "${candidate%/}")"
  case "$cand_lc/" in
    "$protected_lc"/* | "$protected_lc"/) return 1 ;;
  esac
  # Every prefix of the candidate is compared by identity, so an alias anywhere
  # along the path is caught, not only one at the end. When the protected
  # directory does not exist yet it has no inode of its own, so the comparison
  # falls back to its parent's inode plus a case-folded name match -- which is
  # what catches an aliased spelling of a directory that has not been created.
  prefix=""
  rest="${candidate#/}"
  while [ -n "$rest" ]; do
    case "$rest" in
      */*)
        base="${rest%%/*}"
        rest="${rest#*/}"
        ;;
      *)
        base="$rest"
        rest=""
        ;;
    esac
    [ -n "$base" ] || continue
    parent="${prefix:-/}"
    prefix="$prefix/$base"
    if [ -n "$protected_id" ]; then
      id="$(node_id "$prefix")" || {
        # Exists but unreadable: refuse. Only a nonexistent prefix is skipped.
        [ "$?" -eq 1 ] || return 1
        id=""
      }
      if [ -n "$id" ] && [ "$id" = "$protected_id" ]; then
        return 1
      fi
    fi
    if [ -n "$protected_parent_id" ] && [ "$(lower "$base")" = "$protected_name_lc" ]; then
      id="$(node_id "$parent")" || {
        [ "$?" -eq 1 ] || return 1
        id=""
      }
      if [ -n "$id" ] && [ "$id" = "$protected_parent_id" ]; then
        return 1
      fi
    fi
  done
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
# A review suspected this could be a cached no-op, because project tasks above
# already compiled the same code without the flag. It is not: Mix persists
# diagnostics and replays them, so this fails on a stored warning even when nothing
# is stale to recompile. Verified on both locked pairs -- compile without the flag
# exits 0 with the warning, and this command then exits non-zero having compiled
# nothing. No --force is needed, and adding one would cost a full rebuild per lane
# for no additional guarantee.
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

# A shell assignment prefix places the value in the child's environment directly.
# The previous form passed it to `env` as an ARGUMENT, so the credential was
# visible in that process's argv until env replaced itself with Mix -- exactly
# the process-table exposure the redaction helper exists to avoid.
if [ -n "$provider_key_value" ]; then
  provider_output="$(LOOPEX_PROVIDER_API_KEY="$provider_key_value" \
    mix test apps/loopex_llm_reqllm/test/provider_test.exs --only real_provider 2>&1)" \
    || { redacted "$provider_output" >&2; fail "real-provider lane failed (outcome 7)"; }
else
  provider_output="$(mix test apps/loopex_llm_reqllm/test/provider_test.exs --only real_provider 2>&1)" \
    || { redacted "$provider_output" >&2; fail "real-provider lane failed (outcome 7)"; }
fi
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
    filled="$(printf '%s\n' "$section" | grep -ciE "^- ${field}:[[:space:]]*[^[:alnum:]]*[[:alnum:]]" || true)"
    [ "${total:-0}" -eq 1 ] \
      || fail "$negatives outcome ${outcome} has ${total:-0} \"${field}\" entries; exactly one is required"
    [ "${filled:-0}" -eq 1 ] \
      || fail "$negatives outcome ${outcome} does not record \"${field}\""
  done
done

absence_root="$(mktemp -d "${TMPDIR:-/tmp}/loopex-m0-absence.XXXXXX")" \
  || fail "could not create an isolated task root for the absence proof (outcome 8)"
# Shadowing only python3 and jq left every alternate entrypoint usable: python,
# python3.12, and xcrun all resolve to a working interpreter on an ordinary
# macOS host, and xcrun reaches Xcode's Python independently of PATH order. The
# stub set is therefore a fixed core plus every python-like name actually
# reachable on this PATH, so a version the list never anticipated is still
# covered on the host where it exists.
# The fixed core covers direct interpreters and the launchers that reach one
# without a python-shaped name of their own: xcrun resolves Xcode's Python, and
# uv, pyenv, pipx, poetry, and conda each run an interpreter they manage.
# AMENDMENT 4. One list drives both the stubs and the scan. They were written
# separately: the launchers were stubbed but the scan matched only python names,
# jq and xcrun, so /opt/homebrew/bin/uv run script.py evaded both PATH shadowing
# and the textual scan. A stubbed name that is not scanned is a hole by
# construction, so the alternation below is built from this list rather than
# repeated by hand.
shadow_names="python python2 python3 jq xcrun uv pyenv pipx poetry conda"
# Splitting on whitespace corrupted any PATH entry containing a space and
# discarded empty entries, which mean the current directory. Reading the raw
# value with ":" as the only separator preserves both.
while IFS= read -r path_dir; do
  [ -n "$path_dir" ] || path_dir="."
  [ -d "$path_dir" ] || continue
  for found in "$path_dir"/python*; do
    [ -x "$found" ] || continue
    found="${found##*/}"
    case "$found" in
      python | python[0-9] | python[0-9].[0-9] | python[0-9].[0-9][0-9]) ;;
      *) continue ;;
    esac
    case " $shadow_names " in
      *" $found "*) ;;
      *) shadow_names="$shadow_names $found" ;;
    esac
  done
done <<PATH_ENTRIES
$(printf '%s\n' "$PATH" | tr ':' '\n')
PATH_ENTRIES
for shadowed in $shadow_names; do
  printf '#!/bin/sh\necho "%s is retired; outcome 8 requires its absence" >&2\nexit 127\n' \
    "$shadowed" > "$absence_root/$shadowed"
  chmod +x "$absence_root/$shadowed"
done
# Every stub is proved effective. Asserting only python3 left the rest unproven.
for shadowed in $shadow_names; do
  command -v "$shadowed" >/dev/null 2>&1 || continue
  if PATH="$absence_root:$PATH" "$shadowed" --version >/dev/null 2>&1; then
    fail "could not shadow $shadowed for the absence proof (outcome 8)"
  fi
done
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

# The scan covers the whole tracked tree, not a list of top-level directories.
# An allowlist is defeated by a directory nobody thought to add: an absolute
# invocation in a new tools/helper.sh, called by the aggregate, would evade both
# the stub and a scripts-only scan. The only exclusion is this runner, which
# necessarily names both interpreters in order to shadow and report them; drift
# in it is caught instead by the bound-artifact digest the status check verifies
# at every revision.
#
# Matched: any path segment ending in the interpreter however it is quoted --
# absolute paths including /usr/bin/"python3", exec, env with flags or
# assignments, command -p and -pv, and assignment-prefixed runs. A bare
# `python3 x.py` is deliberately not matched here; the stubs above already
# intercept it, and matching it would flag the aggregate's own legitimate calls.
# The alternation is generated from shadow_names plus the versioned python form,
# so adding a launcher to the stub list scans it too.
interpreter_alternation="python[0-9.]*"
for shadowed in $shadow_names; do
  case "$shadowed" in
    python*) ;;
    *) interpreter_alternation="$interpreter_alternation|$shadowed" ;;
  esac
done
bypass="(/["'"'"']*|(^|[[:space:]])(command|exec)([[:space:]]+-[^[:space:]]*)*[[:space:]]+["'"'"']?|env([[:space:]]+[^[:space:]]+)*[[:space:]]+["'"'"']?|(^|[[:space:]])([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+["'"'"']?)($interpreter_alternation)([^[:alnum:]_/]|$)"
# The scan covers every tracked file with one exclusion: this runner, which must
# name the interpreters in order to shadow and report them, and whose drift the
# bound-artifact digest catches instead. Markdown is NOT excluded. Excluding it
# by file type was unsafe, because a mode-0644 file is still executable as
# `bash docs/payload.md` or by being sourced, and the execute-bit assertion that
# guarded the exclusion could not see that. The prose that has to describe these
# forms avoids spelling them literally instead.
scan_tree=". :(exclude)scripts/check-m0-gate.sh"

scan_status=0
git grep -nE "$bypass" -- $scan_tree >/dev/null 2>&1 || scan_status=$?
case "$scan_status" in
  0)
    git grep -nE "$bypass" -- $scan_tree >&2
    fail "a shadow-bypassing interpreter invocation survives (outcome 8)"
    ;;
  1) ;;
  *) fail "the bypass scan could not run (git grep exit $scan_status); evidence is unavailable (outcome 8)" ;;
esac

# Every textual way to mutate the search-path variable is rejected: plain and
# exported assignment, `unset`, `printf -v`, an array-element write, and a
# declaration that names it. No repository script has a legitimate reason to
# touch it, and none does, so the rule needs no judgment about the value --
# requiring the old value to be carried forward failed both by prepending a real
# interpreter directory ahead of the stub and by deleting the stub root.
#
# THIS IS NOT AIRTIGHT, and the gate says so rather than claiming otherwise.
# Indirection -- a nameref, `eval`, or a computed variable name -- mutates the
# same variable with no PATH token to match, and no text scan can see it. The
# containment that would close it is not available in the development baseline:
# an allowlist search path cannot exclude the interpreter directories, because
# /usr/bin holds python3 and also git, sed, and awk, so removing it would break
# the aggregate this check exists to run. Prepending the stub root is the
# strongest portable containment; indirection is the residual, and it belongs to
# closure review because no mechanism here can reach it.
# AMENDMENT 4. The name may be quoted, and a builtin may bind it with no equals
# sign on the line at all. `export "PATH"=/usr/bin`, `read PATH` and `mapfile -t
# PATH` all evaded a rule the gate described as covering every direct mutation.
# Rather than keep adding forms, the rule is now the token PATH, quoted or not,
# wherever a shell can bind it: an assignment, an array element write, or any of
# the builtins that assign.
# AMENDMENT 5. `for` and `select` bind the loop variable with no operator on the
# line at all, so an ordinary loop over the variable set it while matching
# neither scan -- and the body then reached a real interpreter. They join the
# binding constructs rather than being added as two more syntaxes: what makes a
# line a binding is the construct, not the punctuation.
path_mutation='(^|[[:space:]]|;|\(|\{)(export|declare|typeset|local|readonly|unset|read|mapfile|readarray|for|select)([[:space:]]+-[^[:space:]]*)*([[:space:]]+[^[:space:]]+)*[[:space:]]+["'"'"'"]?PATH["'"'"'"]?([^[:alnum:]_]|$)|(^|[[:space:]]|;|\(|\{)["'"'"'"]?PATH["'"'"'"]?([[:space:]]*=|\[)|printf[[:space:]]+([^[:space:]]+[[:space:]]+)*-v[[:space:]]+["'"'"'"]?PATH["'"'"'"]?'
mutation_status=0
git grep -nE "$path_mutation" -- $scan_tree >/dev/null 2>&1 || mutation_status=$?
case "$mutation_status" in
  0)
    git grep -nE "$path_mutation" -- $scan_tree >&2
    fail "a search-path mutation outside the runner would displace the shadow root (outcome 8)"
    ;;
  1) ;;
  *) fail "the search-path scan could not run (git grep exit $mutation_status); evidence is unavailable (outcome 8)" ;;
esac
for residue in \
  scripts/check-status.sh \
  scripts/check-agent-bootstrap.sh \
  .claude/hooks/guard-bash.sh \
  .claude/hooks/after-edit.sh \
  .claude/hooks/guard-filesystem.sh
do
  [ -f "$residue" ] || continue
  if grep -qE '(^|[^[:alnum:]_])(python[0-9.]*|jq|xcrun)([^[:alnum:]_/]|$)' "$residue"; then
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
