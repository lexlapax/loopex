#!/usr/bin/env bash
# Executable acceptance gate for milestone M1.
#
# CONCEPT
#
# This runner judges mechanics: locked commands passed, protected selectors ran
# without skips or exclusions, retained evidence has the required structure, and
# real user state was contained. Review still judges whether a test asserts what
# it names and whether retained evidence tells the truth.
#
# TECHNICAL DEPTH
#
# Every protected selector and exact locked name is checked before allocation or
# Mix. At the accepted opening checkpoint the runner therefore reaches the
# declared product red while it is still read-only. The later writable lane owns
# its HOME, build, dependency copy, workspace, and Rebar cache.
set -euo pipefail
set +x

fail() {
  echo "M1 gate RED: $1" >&2
  exit 1
}

# Contain the provider credential before the first child process. An inherited
# `set -a` must not export the holding variable, and no ordinary command receives
# either name. Only the two explicit real-provider commands below receive the
# value through their environment.
set +a
provider_key_value="${LOOPEX_PROVIDER_API_KEY:-}"
export -n provider_key_value 2>/dev/null || true
unset LOOPEX_PROVIDER_API_KEY
export GIT_OPTIONAL_LOCKS=0
env_output="$(env)" || fail "the child environment could not be inspected"
for leaked in LOOPEX_PROVIDER_API_KEY provider_key_value; do
  leak_status=0
  printf '%s\n' "$env_output" | grep -qE "^${leaked}=" || leak_status=$?
  case "$leak_status" in
    0) fail "$leaked is exported; the credential would reach every child process" ;;
    1) ;;
    *) fail "the child environment could not be checked for $leaked (grep exit $leak_status)" ;;
  esac
done
git_locks_status=0
printf '%s\n' "$env_output" | grep -qxF 'GIT_OPTIONAL_LOCKS=0' || git_locks_status=$?
case "$git_locks_status" in
  0) ;;
  1) fail "Git inspection was not made non-locking before the first child" ;;
  *) fail "the child environment could not be checked for non-locking Git (grep exit $git_locks_status)" ;;
esac

# Provider diagnostics are captured and redacted in this shell before printing.
# The value is neither an argv element nor input to a redaction subprocess.
redacted() {
  if [ -n "$provider_key_value" ]; then
    printf '%s\n' "${1//"$provider_key_value"/[redacted credential]}"
  else
    printf '%s\n' "$1"
  fi
}

repository_output="$(git rev-parse --show-toplevel 2>&1)" \
  || fail "the repository root could not be resolved: $repository_output"
repository_root="$(printf '%s\n' "$repository_output" | grep -v 'DARWIN_USER_TEMP_DIR')" \
  || fail "the repository root lookup returned no usable path"
case "$repository_root" in
  "" | *$'\n'*) fail "the repository root lookup returned an ambiguous path" ;;
esac
cd -- "$repository_root" || fail "the repository root could not be entered"

plan="docs/plans/M1.md"
gate="docs/plans/M1-gate.md"
[ -f "$plan" ] || fail "no $plan; the gate has no plan to enforce"
[ -f "$gate" ] || fail "no $gate; the gate has no locked text"
[ -f mix.exs ] || fail "no umbrella project at mix.exs"

require_named_test() {
  local file="$1" name="$2"
  [ -f "$file" ] || fail "no $file; the outcome it proves does not exist yet"
  grep -qF "test \"${name}\"" "$file" \
    || fail "$file does not define the locked test \"$name\""
}

require_real_provider_test() {
  local file="$1" name="$2"
  awk -v name="$name" '
    /^[[:space:]]*@tag[[:space:]]+:real_provider[[:space:]]*$/ { tagged = 1; next }
    /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (tagged && index(line, "test \"" name "\"") == 1) found = 1
      tagged = 0
    }
    END { exit(found ? 0 : 1) }
  ' "$file" || fail "$file does not tag the locked test \"$name\" as real_provider"
}

# READ-ONLY PREFLIGHT. Do not move allocation or a Mix command above this block.
# The first absent selector is the declared opening red condition.
require_named_test apps/loopex/test/runtime_test.exs \
  "two runtimes coexist without a global name"
require_named_test apps/loopex/test/runtime_test.exs \
  "a runtime reference is required rather than inferred"

require_named_test apps/loopex/test/session_lifecycle_test.exs \
  "a session resumes with the durable truth it committed"
require_named_test apps/loopex/test/session_lifecycle_test.exs \
  "a superseded owner cannot newly commit or use a delayed result to update cache publish dispatch or authorize"
require_named_test apps/loopex/test/session_lifecycle_test.exs \
  "the durable transition catalogue is completely fault injected"
require_named_test apps/loopex/test/session_lifecycle_test.exs \
  "a prompt cannot start a second active run"

require_named_test apps/loopex/test/store_conformance_test.exs \
  "every implementation atomically refuses a stale owner epoch incarnation and version"
require_named_test apps/loopex/test/store_conformance_test.exs \
  "a killed writer loses no acknowledged fact"
require_named_test apps/loopex/test/store_conformance_test.exs \
  "replay audits durable truth but grants no write authority"

require_named_test apps/loopex/test/embedded_api_test.exs \
  "progress and diagnostics never carry durable truth"
require_named_test apps/loopex/test/embedded_api_test.exs \
  "committed events survive delivery with stable identity"
require_named_test apps/loopex/test/embedded_api_test.exs \
  "attachment snapshots at N and streams events after N without a gap"
require_named_test apps/loopex/test/embedded_api_test.exs \
  "a slow subscriber cannot block session commits or grow coordinator memory without bound"

require_named_test apps/loopex/test/real_model_lane_test.exs \
  "deterministic and ReqLLM adapters satisfy one model conformance suite"
require_named_test apps/loopex/test/real_model_lane_test.exs \
  "model dispatch receives only the committed canonical request bytes and digest"
require_named_test apps/loopex/test/real_model_lane_test.exs \
  "one real non-streaming model call completes inside a session"
require_real_provider_test apps/loopex/test/real_model_lane_test.exs \
  "one real non-streaming model call completes inside a session"

require_named_test apps/loopex/test/executor_test.exs \
  "required grant bindings equal the independent contract oracle"
require_named_test apps/loopex/test/executor_test.exs \
  "each missing and wrong grant binding is refused before process start"
require_named_test apps/loopex/test/executor_test.exs \
  "only an explicit host-policy allow decision can issue or widen a grant"
require_named_test apps/loopex/test/executor_test.exs \
  "the executor recomputes the canonical JobRequest digest and the receipt retains verified origin identity"
require_named_test apps/loopex/test/executor_test.exs \
  "the workspace lease is held for the job lifetime and loss kills owned work with retained evidence"
require_named_test apps/loopex/test/executor_test.exs \
  "one controlled tool executes and commits its effect"

require_named_test apps/loopex/test/reference_client_test.exs \
  "the client drives the loop through the embedded API only"

require_named_test apps/loopex/test/end_to_end_recovery_test.exs \
  "one vertical loop survives an OS-process kill and continues through a second real model call"
require_real_provider_test apps/loopex/test/end_to_end_recovery_test.exs \
  "one vertical loop survives an OS-process kill and continues through a second real model call"
require_named_test apps/loopex/test/end_to_end_recovery_test.exs \
  "exactly one dispatch ever carried each effect across the restart"
require_named_test apps/loopex/test/end_to_end_recovery_test.exs \
  "an effect without a durable receipt becomes outcome_unknown and is not blindly retried"
require_named_test apps/loopex/test/end_to_end_recovery_test.exs \
  "every acknowledged fact survives the restart"
require_named_test apps/loopex/test/end_to_end_recovery_test.exs \
  "each wrong reconciliation and receipt identity is refused"

require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "the no-argument M0 record remains the default and M1 never falls back to it"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "matrix command refuses partial unknown and ambiguous explicit arguments"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "M1 matrix requires the five-run walk covering all four adjacencies"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "M1 matrix metadata binds the reachable candidate current gate command platform and limits"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "negative evidence binds one visible JSON record per constitutional outcome"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "negative evidence requires both the committed and current blob to equal the digest"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "the read-only prefix disables optional Git locks before repository inspection"
require_named_test apps/loopex/test/m1_gate_evidence_test.exs \
  "the user-state fingerprint includes a command-line symlink target root"

grep -qF 'ExUnit.start(exclude: [:real_provider])' apps/loopex/test/test_helper.exs \
  || fail "apps/loopex/test/test_helper.exs does not exclude real_provider by default"

tree_state="$(git status --porcelain=v1 --untracked-files=all)" \
  || fail "working-tree state is unavailable"
[ -z "$tree_state" ] \
  || fail "the gate requires a clean whole tree; retained evidence cannot bind a dirty run"

# Physical containment is the safety property. Lexical path checks miss relative
# paths, `..`, dangling links, link chains, case folding, and the macOS Data-volume
# alias. Resolve links left-to-right and then compare every existing prefix by
# device and inode. An unresolvable path is refused, never assumed outside.
user_state_dirname=".loopex"
real_home="${HOME%/}"
real_user_state_path="$real_home/$user_state_dirname"

resolve_physical() {
  local remaining="$1" resolved="" comp link guard=0
  case "$remaining" in
    /*) ;;
    *) remaining="$PWD/$remaining" ;;
  esac
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
    if [ -L "$resolved/$comp" ]; then
      guard=$((guard + 1))
      [ "$guard" -le 64 ] || { printf '%s' ""; return 0; }
      link="$(readlink "$resolved/$comp")"
      case "$link" in
        /*)
          resolved=""
          remaining="$link$remaining"
          ;;
        *) remaining="/$link$remaining" ;;
      esac
    else
      resolved="$resolved/$comp"
    fi
  done
  printf '%s' "${resolved:-/}"
}

node_id() {
  [ -e "$1" ] || return 1
  stat -f '%d:%i' "$1" 2>/dev/null && return 0
  stat -c '%d:%i' "$1" 2>/dev/null && return 0
  return 2
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

protected_resolved="$(resolve_physical "$real_user_state_path")"
[ -n "$protected_resolved" ] \
  || fail "the protected state path could not be resolved; refusing to run"
protected_parent="${protected_resolved%/*}"
[ -n "$protected_parent" ] || protected_parent=/
protected_name="${protected_resolved##*/}"
protected_parent_id="$(node_id "$protected_parent")" || {
  [ "$?" -eq 1 ] \
    || fail "the identity of $protected_parent could not be read; containment evidence is unavailable"
  protected_parent_id=""
}
protected_id="$(node_id "$protected_resolved")" || {
  [ "$?" -eq 1 ] \
    || fail "the identity of $protected_resolved could not be read; containment evidence is unavailable"
  protected_id=""
}
protected_lc="$(lower "${protected_resolved%/}")"
protected_name_lc="$(lower "$protected_name")"

outside_protected_state() {
  local candidate cand_lc prefix rest base parent id
  candidate="$(resolve_physical "$1")"
  [ -n "$candidate" ] || return 1
  cand_lc="$(lower "${candidate%/}")"
  case "$cand_lc/" in
    "$protected_lc"/* | "$protected_lc"/) return 1 ;;
  esac
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
        [ "$?" -eq 1 ] || return 1
        id=""
      }
      [ -z "$id" ] || [ "$id" != "$protected_id" ] || return 1
    fi
    if [ -n "$protected_parent_id" ] && [ "$(lower "$base")" = "$protected_name_lc" ]; then
      id="$(node_id "$parent")" || {
        [ "$?" -eq 1 ] || return 1
        id=""
      }
      [ -z "$id" ] || [ "$id" != "$protected_parent_id" ] || return 1
    fi
  done
  return 0
}

for inherited in "${TMPDIR:-/tmp}" "${MIX_HOME:-$real_home/.mix}" "${HEX_HOME:-$real_home/.hex}"; do
  outside_protected_state "$inherited" \
    || fail "$inherited is inside the protected user state directory; refusing to run"
done

command -v mix >/dev/null 2>&1 \
  || fail "mix is not installed; the accepted toolchain is required"

# The writable lane starts here. Each invocation owns all mutable Mix/dependency
# state that can differ by toolchain. Existing dependency source is copied rather
# than shared; an unavailable dependency still fails through the ordinary Mix
# command and never triggers a network fetch here.
isolated_root="$(mktemp -d "${TMPDIR:-/tmp}/loopex-m1-task.XXXXXX")" \
  || fail "could not create an isolated task root"
trap 'rm -rf "$isolated_root"' EXIT

export MIX_HOME="${MIX_HOME:-$real_home/.mix}"
export HEX_HOME="${HEX_HOME:-$real_home/.hex}"
export MIX_BUILD_PATH="$isolated_root/build"
export MIX_DEPS_PATH="$isolated_root/deps"
export REBAR_CACHE_DIR="$isolated_root/rebar-cache"
export TMPDIR="$isolated_root/tmp"
export HOME="$isolated_root/home"
export LOOPEX_HOME="$isolated_root/home/$user_state_dirname"
export LOOPEX_WORKSPACE="$isolated_root/workspace"
mkdir -p \
  "$HOME" \
  "$LOOPEX_HOME" \
  "$LOOPEX_WORKSPACE" \
  "$MIX_DEPS_PATH" \
  "$REBAR_CACHE_DIR" \
  "$TMPDIR"
if [ -d deps ]; then
  cp -R deps/. "$MIX_DEPS_PATH/" \
    || fail "could not copy dependency source into the isolated task root"
fi

entry_mode() {
  stat -f '%Lp' "$1" 2>/dev/null && return 0
  stat -c '%a' "$1" 2>/dev/null && return 0
  return 1
}

# `find -H` traverses a command-line symlink, but the root entry it emits is
# still the link path. Record the fully resolved root separately so a target
# directory mode/identity change or a target-file content change cannot hide
# behind unchanged link metadata.
root_target_record() {
  local source="$1" target mode identity type
  [ -L "$source" ] || return 0
  target="$(resolve_physical "$source")"
  [ -n "$target" ] || return 1
  mode="$(entry_mode "$target")" || return 1
  identity="$(node_id "$target")" || return 1
  if [ -f "$target" ]; then
    type=root-target-file
    { printf 'path=%s\0type=%s\0mode=%s\0identity=%s\0content=' \
        "$target" "$type" "$mode" "$identity"; cat "$target"; } | shasum -a 256
  elif [ -d "$target" ]; then
    type=root-target-directory
    printf 'path=%s\0type=%s\0mode=%s\0identity=%s\0' \
      "$target" "$type" "$mode" "$identity" | shasum -a 256
  else
    type=root-target-other
    printf 'path=%s\0type=%s\0mode=%s\0identity=%s\0' \
      "$target" "$type" "$mode" "$identity" | shasum -a 256
  fi
}

# Defense in depth records paths, types, permission modes, symlink targets, and
# regular-file contents. A pathname-only fingerprint misses edits in place; a
# file-content-only fingerprint misses mode and type changes.
real_user_state() {
  local entries="$isolated_root/user-state.entries"
  local manifest="$isolated_root/user-state.manifest"
  local entry relative mode type
  if [ ! -e "$real_user_state_path" ] && [ ! -L "$real_user_state_path" ]; then
    printf '%s' absent
    return 0
  fi
  # -H follows a command-line symlink while shell `-L` still records that root
  # link's own target and mode. Both the alias and the target tree are therefore
  # fingerprinted.
  find -H "$real_user_state_path" -print0 > "$entries" || return 1
  : > "$manifest"
  root_target_record "$real_user_state_path" >> "$manifest" || return 1
  while IFS= read -r -d '' entry; do
    relative="${entry#"$real_user_state_path"}"
    mode="$(entry_mode "$entry")" || return 1
    if [ -L "$entry" ]; then
      type=symlink
      { printf 'path=%s\0type=%s\0mode=%s\0target=' "$relative" "$type" "$mode"; readlink "$entry"; } \
        | shasum -a 256 >> "$manifest" || return 1
    elif [ -f "$entry" ]; then
      type=file
      { printf 'path=%s\0type=%s\0mode=%s\0content=' "$relative" "$type" "$mode"; cat "$entry"; } \
        | shasum -a 256 >> "$manifest" || return 1
    elif [ -d "$entry" ]; then
      type=directory
      printf 'path=%s\0type=%s\0mode=%s\0' "$relative" "$type" "$mode" \
        | shasum -a 256 >> "$manifest" || return 1
    else
      type=other
      printf 'path=%s\0type=%s\0mode=%s\0' "$relative" "$type" "$mode" \
        | shasum -a 256 >> "$manifest" || return 1
    fi
  done < "$entries"
  LC_ALL=C sort "$manifest" | shasum -a 256
}

user_state_before="$(real_user_state)" \
  || fail "real user state could not be fingerprinted; containment evidence is unavailable"

# Cross-version ExUnit summary parsing. Executed means passed or failed, never
# skipped or excluded. Both locked output shapes fail closed on an unreadable
# count or a grep error.
summary_field() {
  local matched status
  matched="$(printf '%s' "$1" | grep -oE "[0-9]+ $2")" || status=$?
  case "${status:-0}" in
    0) printf '%s' "$matched" | tail -1 | grep -oE '[0-9]+' ;;
    1) : ;;
    *) fail "could not read the \"$2\" field of a test summary (grep exit ${status}); evidence is unavailable" ;;
  esac
}

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
      total="$(printf '%s' "$line" | grep -oE '[0-9]+ (test|tests),' | grep -oE '[0-9]+')"
      [ -n "$total" ] || return 1
      skipped="$(summary_field "$line" skipped)"
      excluded="$(summary_field "$line" excluded)"
      echo $((total - ${skipped:-0} - ${excluded:-0}))
      ;;
  esac
}

assert_test_result() {
  local label="$1" minimum="$2" output="$3" executed skipped excluded
  skipped="$(summary_field "$output" skipped)"
  excluded="$(summary_field "$output" excluded)"
  [ "${skipped:-0}" -eq 0 ] \
    || fail "$label skipped ${skipped} tests; a protected selector may not skip"
  [ "${excluded:-0}" -eq 0 ] \
    || fail "$label excluded ${excluded} tests; a protected selector may not exclude"
  executed="$(executed_tests "$output")" \
    || fail "$label produced no parsable test count"
  [ "$executed" -ge "$minimum" ] \
    || fail "$label executed ${executed} tests, fewer than the locked minimum ${minimum}"
}

run_selector() {
  local file="$1" minimum="$2" output
  if ! output="$(mix test "$file" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "$file failed"
  fi
  assert_test_result "$file" "$minimum" "$output"
}

require_populated() {
  local file="$1" label="$2" total filled
  total="$(grep -ciE "^- ${label}:" "$file" || true)"
  filled="$(grep -ciE "^- ${label}:[[:space:]]*[^[:alnum:]]*[[:alnum:]]" "$file" || true)"
  [ "${total:-0}" -eq 1 ] \
    || fail "$file has ${total:-0} \"${label}\" entries; exactly one is required"
  [ "${filled:-0}" -eq 1 ] || fail "$file does not record ${label}"
}

# Locked repository commands.
[ -f .formatter.exs ] || fail "no .formatter.exs; formatting scope is unbound"
mix loopex.format_scope || fail "effective formatter configuration misses application sources"
mix format --check-formatted || fail "formatting is not clean"
mix compile --warnings-as-errors || fail "compilation is not warning-free"
mix loopex.deps_budget || fail "dependency budget or direction is violated"
mix loopex.version_train || fail "applications do not carry one version"
mix loopex.matrix --evidence docs/evidence/M1-toolchain-matrix.md --profile m1 \
  || fail "the running pair or retained M1 five-run matrix is invalid"
mix loopex.core_only || fail "core-only, fakes-only lane failed"
mix loopex.docs_check || fail "compiled dual-depth documentation check failed"
mix loopex.hook_registration || fail "a client hook is not registered under its required event and matcher"
mix loopex.status || fail "repository status or bound-artifact validation failed"
bash scripts/check-bootstrap.sh || fail "bootstrap aggregate failed"
run_selector apps/loopex/test/m1_gate_evidence_test.exs 8

# Protected outcome selectors.
run_selector apps/loopex/test/runtime_test.exs 3
run_selector apps/loopex/test/session_lifecycle_test.exs 5
run_selector apps/loopex/test/store_conformance_test.exs 5
run_selector apps/loopex/test/embedded_api_test.exs 4
run_selector apps/loopex/test/executor_test.exs 6
run_selector apps/loopex/test/reference_client_test.exs 2

provider_file="apps/loopex/test/real_model_lane_test.exs"
if [ -n "$provider_key_value" ]; then
  provider_output="$(LOOPEX_PROVIDER_API_KEY="$provider_key_value" \
    mix test "$provider_file" --include real_provider 2>&1)" \
    || { redacted "$provider_output" >&2; fail "the real-model provider lane failed or its evidence is unavailable"; }
else
  provider_output="$(mix test "$provider_file" --include real_provider 2>&1)" \
    || { redacted "$provider_output" >&2; fail "the real-model provider lane failed or its evidence is unavailable"; }
fi
assert_test_result "$provider_file --include real_provider" 3 "$provider_output"

vertical_file="apps/loopex/test/end_to_end_recovery_test.exs"
if [ -n "$provider_key_value" ]; then
  vertical_output="$(LOOPEX_PROVIDER_API_KEY="$provider_key_value" \
    mix test "$vertical_file" --include real_provider 2>&1)" \
    || { redacted "$vertical_output" >&2; fail "the real vertical recovery lane failed or its evidence is unavailable"; }
else
  vertical_output="$(mix test "$vertical_file" --include real_provider 2>&1)" \
    || { redacted "$vertical_output" >&2; fail "the real vertical recovery lane failed or its evidence is unavailable"; }
fi
assert_test_result "$vertical_file --include real_provider" 5 "$vertical_output"

# Prove the real case is excluded while the deterministic model cases still run
# by default.
default_output="$(mix test "$provider_file" 2>&1)" \
  || { printf '%s\n' "$default_output" >&2; fail "the provider file fails in the default suite"; }
default_skipped="$(summary_field "$default_output" skipped)"
default_excluded="$(summary_field "$default_output" excluded)"
default_executed="$(executed_tests "$default_output")" \
  || fail "the provider file produced no parsable count in the default suite"
[ "${default_skipped:-0}" -eq 0 ] || fail "the default provider-file run skipped tests"
[ "$default_executed" -ge 2 ] \
  || fail "the provider file executed fewer than its two deterministic conformance cases"
[ "${default_excluded:-0}" -ge 1 ] \
  || fail "the provider file has no explicitly excluded real-provider test"

vertical_default="$(mix test "$vertical_file" 2>&1)" \
  || { printf '%s\n' "$vertical_default" >&2; fail "the vertical file fails without provider inclusion"; }
vertical_default_skipped="$(summary_field "$vertical_default" skipped)"
vertical_default_excluded="$(summary_field "$vertical_default" excluded)"
vertical_default_executed="$(executed_tests "$vertical_default")" \
  || fail "the vertical file produced no parsable count without provider inclusion"
[ "${vertical_default_skipped:-0}" -eq 0 ] \
  || fail "the default vertical-file run skipped tests"
[ "$vertical_default_executed" -ge 4 ] \
  || fail "the default vertical-file run executed fewer than its four deterministic cases"
[ "${vertical_default_excluded:-0}" -ge 1 ] \
  || fail "the vertical file did not exclude its real-provider case by default"

mix loopex.m1_evidence || fail "M1 negative-demonstration evidence is invalid"

provider_evidence="docs/evidence/M1-provider.md"
[ -f "$provider_evidence" ] \
  || fail "no $provider_evidence; the real provider path has no retained identity"
for field in provider model endpoint recorded; do
  require_populated "$provider_evidence" "$field"
done

# Presence is mechanical; freshness and completeness remain closure review.
for closure_document in \
  CHANGELOG.md \
  README.md \
  DEVELOPMENT.md \
  docs/plans/README.md \
  docs/plans/M1.md \
  docs/evidence/M1-toolchain-matrix.md \
  docs/evidence/M1-provider.md \
  docs/evidence/M1-negative-demonstrations.md \
  docs/evidence/README.md \
  docs/developer/agent-context-map.md
do
  [ -f "$closure_document" ] || fail "closure document $closure_document is missing"
done

# Credential-free ordinary suite.
mix test || fail "full credential-free suite failed"

tree_state_after="$(git status --porcelain=v1 --untracked-files=all)" \
  || fail "working-tree state is unavailable after the run"
[ -z "$tree_state_after" ] \
  || fail "the gate or its tests changed the whole tree"

user_state_after="$(real_user_state)" \
  || fail "real user state could not be fingerprinted after the run"
[ "$user_state_after" = "$user_state_before" ] \
  || fail "the run changed the content, type, mode, or topology of real user state"

echo "M1 gate GREEN"
