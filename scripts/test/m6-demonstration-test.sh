#!/usr/bin/env bash
# Exercise the real delegation function with a fake command, without a provider.
set -euo pipefail
source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$source_root"
work=$(mktemp -d "${TMPDIR:-/tmp}/loopex-m6-demo-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { printf 'm6-demonstration-test: %s\n' "$1" >&2; exit 1; }

# The demonstration starts its build at `candidate=`. Source only its function
# definitions so the test drives the exact delegated child path.
eval "$(awk '/^local_run\(\) \{/{copy=1} /^candidate=\$\(git rev-parse HEAD\)/{exit} copy{print}' \
  "$source_root/scripts/m6-demonstration.sh")"
export M6_DEMO_WORKSPACE="$work" M6_DEMO_SKILL="$work/skill"
export M6_DEMO_LOCAL_MODEL=ollama:fixture M6_DEMO_PROMPT=fixture
export M6_DEMO_COMMAND="$work/fake-ask"

cat >"$M6_DEMO_COMMAND" <<'EOF'
#!/usr/bin/env bash
emit_json() {
  if [ "${M6_FAKE_NO_LF:-0}" = 1 ]; then
    printf '%s' "$M6_FAKE_JSON"
  else
    printf '%s\n' "$M6_FAKE_JSON"
  fi
}
case "${M6_FAKE_DEST:-stdout}" in
  stdout) emit_json ;;
  stderr) emit_json >&2 ;;
  none) ;;
esac
if [ -n "${M6_FAKE_STDERR:-}" ]; then printf '%s\n' "$M6_FAKE_STDERR" >&2; fi
exit "$M6_FAKE_EXIT"
EOF
chmod +x "$M6_DEMO_COMMAND"

expect_failure() {
  local label=$1 expected_status=$2 expected_line=$3 status=0
  delegation >"$work/delegation.stdout" || status=$?
  [ "$status" -eq "$expected_status" ] || fail "$label exit status $status"
  [ ! -s "$work/delegation.stdout" ] || fail "$label printed child output"
  [ ! -e "$work/delegated.json" ] || fail "$label persisted failed JSON"
  [ "$(cat "$work/delegated.stderr")" = "$expected_line" ] ||
    fail "$label diagnostic changed (bytes=$(wc -c <"$work/delegated.stderr"))"
  ! grep -Eq 'SECRET|loopex-m6-demo-test' "$work/delegated.stderr" ||
    fail "$label leaked child data"
}

export M6_FAKE_DEST=stdout M6_FAKE_STDERR= M6_FAKE_EXIT=2
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":"run","profile":"ephemeral","outcome":"failed","text":"SECRET_MODEL_TEXT","text_truncated":false,"tools":[{"tool_id":"SECRET_TOOL_VALUE","outcome":"completed"}],"tools_truncated":false,"shadowed_skills":[],"cleanup":{"proved":true},"details":{"reason":"model_call_failed","failure":null,"cleanup_grace_ms":"5000"}}'
expect_failure failed 2 \
  'm6-demonstration: delegated command exit=2 exit_class=failed'

export M6_FAKE_STDERR=SECRET_PROVIDER_DIAGNOSTIC
expect_failure mixed 2 \
  'm6-demonstration: delegated command exit=2 exit_class=failed'

export M6_FAKE_STDERR= M6_FAKE_EXIT=6
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":null,"profile":"ephemeral","outcome":"no_ending","text":"SECRET_PARTIAL_TEXT","text_truncated":false,"tools":[],"tools_truncated":false,"shadowed_skills":[],"cleanup":{"proved":true},"details":{"reason":"timeout","waited_ms":"120000"}}'
expect_failure timeout 6 \
  'm6-demonstration: delegated command exit=6 exit_class=no_ending'

export M6_FAKE_EXIT=2
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":"run","profile":"ephemeral","outcome":"failed","text":"SECRET_MODEL_TEXT","text_truncated":false,"tools":[],"tools_truncated":false,"shadowed_skills":[],"cleanup":{"proved":false,"root":"SECRET_ROOT","root_ownership":"owned","pending":["process_groups"]},"details":{"reason":"model_call_failed","failure":null,"cleanup_grace_ms":"5000"}}'
export M6_FAKE_STDERR=$'loopex: cleanup_unproved root="SECRET_ROOT" ownership=owned pending=process_groups\nloopex: Session cleanup is unconfirmed. Before running ask again, make sure the previous ask process has exited and inspect the root named above; do not remove an unverified path.'
expect_failure unproved 2 \
  'm6-demonstration: delegated command exit=2 exit_class=failed'

export M6_FAKE_STDERR=
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":"run","profile":"ephemeral","outcome":"failed","text":"SECRET_MODEL_TEXT","text_truncated":false,"tools":[],"tools_truncated":false,"shadowed_skills":[],"cleanup":{"proved":true},"details":{"reason":"SECRET_REASON","failure":null,"cleanup_grace_ms":"5000"}}'
expect_failure unknown_code 2 \
  'm6-demonstration: delegated command exit=2 exit_class=failed'

export M6_FAKE_EXIT=1 M6_FAKE_JSON='SECRET_RAW_DIAGNOSTIC'
expect_failure raw 1 \
  'm6-demonstration: delegated command exit=1 exit_class=diagnostic_or_cleanup'

export M6_FAKE_EXIT=3
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":"run","profile":"ephemeral","outcome":"bound_reached","text":"SECRET_PARTIAL_TEXT","text_truncated":false,"tools":[],"tools_truncated":false,"shadowed_skills":[],"cleanup":{"proved":true},"details":{"bound":"deadline","observed":"120000","declared_limit":"120000","accounting_source":null,"cleanup_grace_ms":"5000"}}'
expect_failure bound 3 \
  'm6-demonstration: delegated command exit=3 exit_class=bound_reached'

export M6_FAKE_EXIT=4
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":"run","profile":"ephemeral","outcome":"outcome_unknown","text":"SECRET_PARTIAL_TEXT","text_truncated":false,"tools":[],"tools_truncated":false,"shadowed_skills":[],"cleanup":{"proved":true},"details":{"reconciliation_ref":"SECRET_REFERENCE","cleanup_grace_ms":"5000"}}'
expect_failure unknown 4 \
  'm6-demonstration: delegated command exit=4 exit_class=outcome_unknown'

export M6_FAKE_EXIT=5
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":"run","profile":"ephemeral","outcome":"cancelled","text":"SECRET_PARTIAL_TEXT","text_truncated":false,"tools":[],"tools_truncated":false,"shadowed_skills":[],"cleanup":{"proved":true},"details":{"cleanup_grace_ms":"5000"}}'
expect_failure cancelled 5 \
  'm6-demonstration: delegated command exit=5 exit_class=cancelled'

export M6_FAKE_EXIT=17 M6_FAKE_JSON=SECRET_UNRECOGNIZED_STATUS
expect_failure other_exit 17 \
  'm6-demonstration: delegated command exit=17 exit_class=unrecognized'

M6_DEMO_COMMAND="$work/absent-ask"
expect_failure unavailable 1 \
  'm6-demonstration: delegated command exit=1 exit_class=diagnostic_or_cleanup'
M6_DEMO_COMMAND="$work/fake-ask"

export M6_FAKE_EXIT=0
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":"run","profile":"ephemeral","outcome":"completed","text":"M6_DEMONSTRATION_READ_OK M6_AFTER_EDIT M6_SKILL_LOADED_OK","text_truncated":false,"tools":[{"tool_id":"loopex.read","outcome":"completed"},{"tool_id":"loopex.write","outcome":"completed"},{"tool_id":"loopex.edit","outcome":"completed"},{"tool_id":"loopex.bash","outcome":"completed"}],"tools_truncated":false,"shadowed_skills":[],"cleanup":{"proved":true},"details":{"cleanup_grace_ms":"5000"}}'
export M6_FAKE_DEST=stderr M6_FAKE_STDERR=
expect_failure success_json_only_on_stderr 1 \
  'm6-demonstration: delegated command exit=0 exit_class=unrecognized'
export M6_FAKE_DEST=stdout
export M6_FAKE_STDERR=SECRET_SUCCESS_DIAGNOSTIC
expect_failure success_with_stderr 1 \
  'm6-demonstration: delegated command exit=0 exit_class=unrecognized'
export M6_FAKE_STDERR=
valid_json=$M6_FAKE_JSON
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":"run","profile":"ephemeral","outcome":"completed","text":"M6_DEMONSTRATION_READ_OK M6_AFTER_EDIT M6_SKILL_LOADED_OK","text_truncated":false,"tools":[{"tool_id":"loopex.read","outcome":"completed"},{"tool_id":"loopex.write","outcome":"completed"},{"tool_id":"loopex.edit","outcome":"completed"},{"tool_id":"loopex.bash","outcome":"completed"}],"tools_truncated":false,"shadowed_skills":[],"cleanup":{"proved":1},"details":{"cleanup_grace_ms":"5000"}}'
expect_failure success_numeric_cleanup 1 \
  'm6-demonstration: delegated command exit=0 exit_class=unrecognized'
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":"run","profile":"ephemeral","outcome":"completed","text":"M6_DEMONSTRATION_READ_OK M6_AFTER_EDIT M6_SKILL_LOADED_OK","text_truncated":false,"tools":[{"tool_id":"loopex.read","outcome":"completed","secret":"SECRET_EXTRA_FIELD"},{"tool_id":"loopex.write","outcome":"completed"},{"tool_id":"loopex.edit","outcome":"completed"},{"tool_id":"loopex.bash","outcome":"completed"}],"tools_truncated":false,"shadowed_skills":[],"cleanup":{"proved":true},"details":{"cleanup_grace_ms":"5000"}}'
expect_failure success_extra_tool_member 1 \
  'm6-demonstration: delegated command exit=0 exit_class=unrecognized'
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":"run","profile":"ephemeral","outcome":"completed","text":"M6_DEMONSTRATION_READ_OK M6_AFTER_EDIT M6_SKILL_LOADED_OK","text_truncated":false,"tools":[{"tool_id":"loopex.read","outcome":"completed"},{"tool_id":"loopex.write","outcome":"completed"},{"tool_id":"loopex.edit","outcome":"completed"},{"tool_id":"loopex.bash","outcome":"completed"}],"tools_truncated":false,"shadowed_skills":["not-a-skill"],"cleanup":{"proved":true},"details":{"cleanup_grace_ms":"5000"}}'
expect_failure success_invalid_shadowed_skill 1 \
  'm6-demonstration: delegated command exit=0 exit_class=unrecognized'
export M6_FAKE_JSON='{"schema":"loopex.ask/1","session_id":"session","run_id":"run","profile":"ephemeral","outcome":"completed","text":"M6_DEMONSTRATION_READ_OK M6_AFTER_EDIT M6_SKILL_LOADED_OK","text_truncated":false,"tools":[{"tool_id":"loopex.read","outcome":"completed"},{"tool_id":"loopex.write","outcome":"completed"},{"tool_id":"loopex.edit","outcome":"completed"},{"tool_id":"loopex.bash","outcome":"completed"}],"tools_truncated":false,"shadowed_skills":[],"cleanup":{"proved":true},"details":{"cleanup_grace_ms":"5000"}}'
export M6_FAKE_NO_LF=1
expect_failure success_no_final_lf 1 \
  'm6-demonstration: delegated command exit=0 exit_class=unrecognized'
export M6_FAKE_NO_LF=0 M6_FAKE_JSON=$valid_json
printf M6_AFTER_EDIT >"$work/generated.txt"
delegation >"$work/delegation.stdout" || fail 'completed delegation failed'
[ ! -s "$work/delegation.stdout" ] && [ ! -s "$work/delegated.stderr" ] ||
  fail 'completed delegation emitted output'
[ "$(cat "$work/delegated.json")" = "$M6_FAKE_JSON" ] ||
  fail 'completed delegation changed the retained JSON'
printf 'm6-demonstration-test: PASS\n'
