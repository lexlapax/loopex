#!/usr/bin/env bash
# The slow check, run once from the exact candidate before closure. It stages
# the candidate as a fresh source archive, builds it there as an operator
# would, and runs every lane inside that extraction: the real-provider
# workflows, the independent Node client, the long-duration bound proofs and,
# on Linux, the cross-UID witness. An
# unchanged-source release reuses that evidence and does not run this command
# again. It needs a provider credential in LOOPEX_PROVIDER_API_KEY, which
# is held by this runner and passed only to selected provider-test children or
# the lane redactor; unrelated helpers do not inherit it. Exact supported values
# in lane output are redacted before terminal or retained-log publication. It also
# needs the Node version pinned in scripts/fixtures/m4/client-toolchain.txt
# and, on Linux, a second unprivileged user named in LOOPEX_CROSS_UID_USER that
# the current user may run a command as with `sudo -n`. Output streams as it
# happens. Repeated --only selectors run unattended pre-merge lanes, not the
# full closure matrix. Invalid selections refuse before staging or builds. The
# full matrix and the paid m7-provider lane take --attempts-index FILE, an
# absolute retained M7 attempts index; the M7 evidence validator refuses those
# lanes before staging while their evidence is unavailable.
set -euo pipefail
# A caller's xtrace or Bash startup hook is not an evidence channel. Startup
# code that ran before this script remains host-owned, but child Bash shells do
# not re-run that hook through this runner.
set +x
unset BASH_ENV ENV
# Keep caller-supplied values for selected rows and redaction, but ensure the
# very first subprocess (including Git and preflight tools) inherits none.
export -n LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
release_contains_key() {
  local content=$1 name key
  for name in LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY; do
    key=${!name:-}
    if [ -n "$key" ]; then
      case "$content" in *"$key"*) return 0 ;; esac
    fi
  done
  return 1
}
for release_arg in "$@"; do
  if release_contains_key "$release_arg"; then
    echo 'check-release: a provider credential appears in a selector; pass only a documented selector name' >&2
    exit 2
  fi
done
unset release_arg
script_dir=$(cd "$(dirname "$0")" && pwd)
source "$script_dir/lib/release-lane.sh"
release_select "$@"
for name in LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY; do
  value=${!name:-}
  case "$value" in
    *$'\n'*|*$'\r'*) echo 'check-release: a provider credential contains a newline and cannot be redacted' >&2; exit 2 ;;
  esac
done
unset value
cd "$(git rev-parse --show-toplevel)"
for release_path in "$script_dir" "$(pwd -P)" "${TMPDIR:-/tmp}" "${LOOPEX_RELEASE_RETAIN:-}"; do
  if release_contains_key "$release_path"; then
    echo 'check-release: a provider credential appears in a release path; use a path without that value' >&2
    exit 2
  fi
done
unset release_path

if release_needs_provider; then
  [ -n "${LOOPEX_PROVIDER_API_KEY:-}" ] ||
    { echo 'check-release: LOOPEX_PROVIDER_API_KEY is required for the selected provider rows' >&2; exit 2; }
fi
if release_needs_ollama; then
  [ -n "${LOOPEX_RELEASE_OLLAMA_MODEL:-}" ] ||
    { echo 'check-release: LOOPEX_RELEASE_OLLAMA_MODEL is required for the local Ollama row' >&2; exit 2; }
  case "$LOOPEX_RELEASE_OLLAMA_MODEL" in
    ollama:?*) ;;
    *) echo 'check-release: LOOPEX_RELEASE_OLLAMA_MODEL must name an ollama: model' >&2; exit 2 ;;
  esac
  export LOOPEX_RELEASE_OLLAMA_MODEL
fi
if release_needs_node; then
  pinned_node=$(awk -F= '$1 == "node" { print $2 }' scripts/fixtures/m4/client-toolchain.txt)
  observed_node=$(node --version 2>/dev/null </dev/null || true)
  [ "$observed_node" = "v$pinned_node" ] ||
    { echo "check-release: Node v$pinned_node is required, found ${observed_node:-none}" >&2; exit 2; }
fi
platform=$(uname -s)
if [ "$release_mode" = selection-only ] && release_selected cross_uid && [ "$platform" != Linux ]; then
  printf 'check-release: cross_uid unavailable on %s; selection cannot pass\n' "$platform" >&2
  exit 2
fi
[ -z "$(git status --porcelain)" ] ||
  { echo 'check-release: the tree must be the committed candidate' >&2; exit 2; }

# The M7 evidence validator: the committed index heads, the pinned fixture
# catalog and the indexed lanes' prerequisites, run from the clean candidate
# checkout. Unavailable evidence refuses before staging; it is never a pass.
if release_needs_m7; then
  m7_args=(--release)
  [ -z "$release_attempts_index" ] || m7_args+=(--attempts-index "$release_attempts_index")
  [ -z "$release_resume_matrix" ] || m7_args+=(--resume-matrix "$release_resume_matrix")
  for m7_lane in m7-operator m7-provider m7-rollback; do
    if release_selected "$m7_lane"; then m7_args+=(--lane "$m7_lane"); fi
  done
  (
    unset LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
    mix loopex.m7_evidence "${m7_args[@]}" </dev/null
  ) || { echo 'check-release: M7 evidence unavailable; the indexed lanes cannot run' >&2; exit 2; }
fi

started=$SECONDS
commit=$(git rev-parse HEAD)
release_version=0.3.0
printf 'check-release: candidate %s on %s %s mode=%s selectors=%s\n' "$commit" "$platform" "$(uname -m)" "$release_mode" "${release_selectors:-all}"
logs=$(mktemp -d "${TMPDIR:-/tmp}/loopex-release.XXXXXX")
fresh=$(mktemp -d "${TMPDIR:-/tmp}/loopex-fresh.XXXXXX")
trap 'rm -rf "$logs" "$fresh"' EXIT
# A caller's build-path overrides would move the extraction's builds outside
# it; every build here belongs to the extraction.
unset MIX_BUILD_PATH MIX_BUILD_ROOT

# The maximum-population case holds both ends of 512 daemon connections in one
# VM, beyond a stock Linux soft limit of 1,024 descriptors, so the soft limit is
# raised toward the hard limit and a host that cannot reach 4,096 refuses.
hard_files=$(ulimit -Hn)
if [ "$hard_files" = unlimited ] || [ "$hard_files" -ge 65536 ]; then
  ulimit -Sn 65536
else
  ulimit -Sn "$hard_files"
fi
[ "$(ulimit -Sn)" -ge 4096 ] ||
  { echo "check-release: at least 4096 open files are required, found $(ulimit -Sn)" >&2; exit 2; }
printf 'check-release: open-file limit %s\n' "$(ulimit -Sn)"

# Reference composition consumes and deletes the credential, so each
# credential-consuming case runs in its own operating-system process. A
# subshell exports the selected name without putting its value in command argv;
# unrelated lane commands and release helpers inherit no provider key.
with_credential() (
  unset OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
  export LOOPEX_PROVIDER_API_KEY
  "$@"
)
with_ephemeral_credential() (
  selected_credential=$LOOPEX_PROVIDER_API_KEY
  unset LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY
  ANTHROPIC_API_KEY=$selected_credential
  unset selected_credential
  export ANTHROPIC_API_KEY
  "$@"
)
without_credential() (
  unset LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
  "$@"
)
# The wrapper self-check plants a synthetic value and reports only whether each
# wrapper's child sees the name, never a value.
(
  LOOPEX_PROVIDER_API_KEY=release-self-check-synthetic
  OPENAI_API_KEY=release-self-check-synthetic
  ANTHROPIC_API_KEY=release-self-check-synthetic
  OPENROUTER_API_KEY=release-self-check-synthetic
  export -n LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
  probe='if [ -n "${LOOPEX_PROVIDER_API_KEY+set}${OPENAI_API_KEY+set}${ANTHROPIC_API_KEY+set}${OPENROUTER_API_KEY+set}" ]; then echo present; else echo absent; fi'
  unwrapped=$(sh -c "$probe")
  seen=$(with_credential sh -c '
    if [ "$LOOPEX_PROVIDER_API_KEY" = release-self-check-synthetic ] &&
       [ -z "${OPENAI_API_KEY+set}${ANTHROPIC_API_KEY+set}${OPENROUTER_API_KEY+set}" ]; then
      echo selected
    else
      echo invalid
    fi')
  hosted=$(with_ephemeral_credential sh -c '
    if [ "$ANTHROPIC_API_KEY" = release-self-check-synthetic ] &&
       [ -z "${LOOPEX_PROVIDER_API_KEY+set}${OPENAI_API_KEY+set}${OPENROUTER_API_KEY+set}" ]; then
      echo selected
    else
      echo invalid
    fi')
  unseen=$(without_credential sh -c "$probe")
  printf 'check-release: credential self-check: helper=%s durable=%s ephemeral=%s other=%s\n' \
    "$unwrapped" "$seen" "$hosted" "$unseen"
  [ "$unwrapped" = absent ] && [ "$seen" = selected ] &&
    [ "$hosted" = selected ] && [ "$unseen" = absent ]
) || { echo 'check-release: credential wrapper self-check RED' >&2; exit 1; }

# The fresh-source lane: stage the exact candidate with `git archive` into a
# fresh extraction under the canonical scoped `umask 022`, launched from a
# hostile caller `umask 0777`; retain its pre-build manifest and the source
# inventory outside the extraction; prove the extraction is exactly the
# commit; run the documented build inside it; and prove the build changed
# nothing but its declared outputs. The retained files stay after the run;
# every later lane runs inside this extraction.
fresh_started=$SECONDS
auto_retain=0
if [ -n "${LOOPEX_RELEASE_RETAIN:-}" ]; then
  retain=$LOOPEX_RELEASE_RETAIN
else
  retain=$(mktemp -d "${TMPDIR:-/tmp}/loopex-retained.XXXXXX")
  auto_retain=1
fi
[ -d "$retain" ] || { echo 'check-release: retained output directory must exist' >&2; exit 2; }
retain=$(cd "$retain" && pwd -P)
if release_contains_key "$retain"; then
  if [ "$auto_retain" -eq 1 ]; then rmdir "$retain" || true; fi
  echo 'check-release: a provider credential appears in a release path; use a path without that value' >&2
  exit 2
fi
checkout=$(pwd -P)
case "$retain/" in
  "$checkout/"*) echo 'check-release: retained output must be outside the checkout' >&2; exit 2 ;;
esac
# Refuse reused evidence paths before an extraction can overwrite any retained
# byte. The scoped umask makes newly created evidence private to this user.
for retained in source-archive-manifest source-archive-manifest.source-identity source-inventory source-archive-manifest.after fresh-source-build.log; do
  (umask 077; set -C; : >"$retain/$retained") 2>/dev/null ||
    { printf 'check-release: retained path unavailable or already exists: %s\n' "$retain/$retained" >&2; exit 2; }
done

# The logical closure matrix and indexed rollback lanes record every release
# lane in the attempts index before it runs. A resumed matrix skips the lanes
# it already completed; fresh-source is rebuilt and must reproduce its retained
# manifest digest. One recorder holds the writer until the conversation lanes.
release_matrix_lanes=()
if [ -n "$release_attempts_index" ] && { [ "$release_mode" = full ] || release_selected m7-rollback; }; then
  if [ "$release_mode" = full ]; then
    release_matrix_lanes=(fresh-source)
    for row in 1 2 3 4 5 6 7 8 9 10 11; do release_matrix_lanes+=("real-provider-$row"); done
    for app in loopex_app_server loopex_protocol loopex_daemon loopex_cli; do release_matrix_lanes+=("node-client-$app"); done
    for app in loopex loopex_executor_local loopex_daemon loopex_composition loopex_llm_reqllm; do
      release_matrix_lanes+=("long-bound-$app")
    done
    [ "$platform" != Linux ] || release_matrix_lanes+=(cross-uid)
    release_matrix_id=${release_resume_matrix:-matrix-${commit:0:12}-$(date +%s)}
  else
    release_matrix_id=""
  fi
  release_matrix_lanes+=(m7-rollback-restore m7-rollback-nonredispatch)
  script_digest=$(release_digest "$script_dir/check-release.sh")
  m7_matrix_args=(--attempts-index "$release_attempts_index" --writer "$release_writer"
    --host "$release_host" --markers "$release_markers" --candidate "$commit"
    --concept "$checkout/docs/plans/M7.md" --run-root "$retain/m7-runs"
    --manifest-digest "$(release_digest "$checkout/test/fixtures/m7/manifest.json")")
  if [ -n "$release_matrix_id" ]; then
    m7_matrix_args+=(--matrix "$release_matrix_id")
  else
    m7_matrix_args+=(--matrix "m7-rollback-${commit:0:12}")
  fi
  [ -z "$release_resume_matrix" ] || m7_matrix_args+=(--resume)
  for label in "${release_matrix_lanes[@]}"; do
    m7_matrix_args+=(--case "$label=$(release_text_digest "$label $script_digest")")
  done
  release_matrix_keys="${release_matrix_lanes[*]}"
  printf 'check-release: logical matrix %s\n' "${release_matrix_id:-m7-rollback-${commit:0:12}}"
  release_matrix_start without_credential mix loopex.m7_matrix "${m7_matrix_args[@]}" || exit 2
fi
fresh_skipped=0
if release_matrix_skipped fresh-source; then
  fresh_skipped=1
  printf 'check-release: fresh-source completed in this logical matrix; rebuilding as a prerequisite\n'
elif [ "${#release_matrix_lanes[@]}" -gt 0 ] && [ "${release_matrix_lanes[0]}" = fresh-source ]; then
  release_matrix_request start fresh-source || exit 2
fi
tree="$fresh/src"
printf 'check-release: fresh-source extraction of %s\n' "$commit"
(
  umask 0777
  caller_umask=$(umask)
  printf 'check-release: CALLER_UMASK=%s\n' "$caller_umask"
  [ "$caller_umask" = 0777 ] || exit 1
  (
    umask 022
    extraction_umask=$(umask)
    printf 'check-release: EXTRACTION_UMASK=%s\n' "$extraction_umask"
    [ "$extraction_umask" = 0022 ] || exit 1
    mkdir "$tree" && git --no-replace-objects archive "$commit" | tar -x -C "$tree"
  )
)
manifest_producer="$logs/source-archive-manifest.sh"
cp "$tree/scripts/source-archive-manifest.sh" "$manifest_producer"
release_retain_source_identity \
  "$tree/SOURCE_IDENTITY" "$retain/source-archive-manifest.source-identity"
bash "$manifest_producer" "$tree" >"$retain/source-archive-manifest"
git ls-files -z >"$retain/source-inventory"
elixir scripts/source-archive-check.exs verify \
  "$retain/source-archive-manifest" "$retain/source-inventory" "$commit" "$tree"
set +e
(cd "$tree" && without_credential mix deps.get &&
  MIX_ENV=prod without_credential mix cmd --app loopex_cli mix escript.build) 2>&1 |
  release_redact | tee "$retain/fresh-source-build.log"
build_statuses=("${PIPESTATUS[@]}")
set -e
printf 'build-evidence: command_status=%s redactor_status=%s tee_status=%s duration_seconds=%s\n' \
  "${build_statuses[0]}" "${build_statuses[1]}" "${build_statuses[2]}" \
  "$((SECONDS - fresh_started))" >>"$retain/fresh-source-build.log"
release_retain_identity "$retain/fresh-source-build.log"
[ "${build_statuses[0]}" -eq 0 ] && [ "${build_statuses[1]}" -eq 0 ] &&
  [ "${build_statuses[2]}" -eq 0 ] ||
  { echo 'check-release: fresh-source build RED' >&2; exit 1; }
elixir "$tree/scripts/escript-inventory.exs" \
  "$tree/apps/loopex_cli/loopex" "$tree/_build/prod/loopex_provider" \
  >"$retain/escript-inventory.log"
cat "$retain/escript-inventory.log"
release_retain_identity "$retain/escript-inventory.log"
bash "$manifest_producer" "$tree" >"$retain/source-archive-manifest.after"
elixir scripts/source-archive-check.exs unchanged \
  "$retain/source-archive-manifest" "$retain/source-archive-manifest.after"
grep -q "\"source\" => \"$commit\"\|<<\"source\">> => <<\"$commit\">>" \
  "$tree/_build/prod/loopex_provider.manifest" ||
  { echo 'check-release: the fresh build does not report the staged commit' >&2; exit 1; }
identity=$(cd "$tree/apps/loopex_llm_reqllm" && without_credential mix loopex.source_identity </dev/null)
case "$identity" in
  *"commit $commit "*) ;;
  *) echo 'check-release: the extraction does not resolve the staged commit' >&2; exit 1 ;;
esac
[ "$(cat "$tree/VERSION")" = "$release_version" ] ||
  { echo "check-release: the extraction's VERSION is not $release_version" >&2; exit 1; }
printf 'check-release: extraction identity %s version %s\n' "$commit" "$release_version"
for retained in source-archive-manifest source-inventory; do
  release_retain_identity "$retain/$retained"
done
printf 'check-release: fresh-source elapsed=%ss\n' "$((SECONDS - fresh_started))"
if [ "$fresh_skipped" -eq 1 ]; then
  [ "$(release_digest "$retain/source-archive-manifest")" = "$(release_matrix_digest fresh-source)" ] ||
    { echo 'check-release: the rebuilt archive manifest differs from the matrix first invocation' >&2; exit 1; }
elif [ "${#release_matrix_lanes[@]}" -gt 0 ] && [ "${release_matrix_lanes[0]}" = fresh-source ]; then
  release_matrix_request finish fresh-source pass "$retain/source-archive-manifest" || exit 1
fi
# The same validator runs again inside the built extraction, before any lane.
if release_needs_m7; then
  (cd "$tree" && MIX_ENV=prod without_credential mix loopex.m7_evidence "${m7_args[@]}" </dev/null) ||
    { echo 'check-release: M7 evidence unavailable in the extraction' >&2; exit 2; }
fi

# The real-provider manifest: application, test file and exact case name. Each
# name must be a fully rooted ExUnit test defined exactly once. The source
# module/line and the runtime ExUnit event must identify the same case.
manifest="$logs/real-provider-manifest"
cat >"$manifest" <<'EOF'
loopex_cli|test/foundation_workflow_real_test.exs|public pinned Git import and a real provider complete the admitted skill tool and artifact workflow
loopex_cli|test/coding_task_test.exs|one real provider task streams edits a real repository across several turns and the operator sees the committed result
loopex_cli|test/coding_task_test.exs|one real provider call surfaces the provider's own response identifier and reported usage that the deterministic adapter cannot produce
loopex_app_server|test/external_workflow_real_test.exs|an extracted source archive follows the operator guide to serve the shipped host and complete the chain against a real provider
loopex_llm_reqllm|test/provider_test.exs|one real model call completes through the model boundary
loopex_reference_client|test/end_to_end_recovery_test.exs|one real-provider trace forces a credential-free tool survives an untrappable runtime-tree kill after receipt before fact reconciles one effect without redispatch preserves its fact and completes a second real call
loopex_reference_client|test/real_model_session_test.exs|one real non-streaming model call receives the committed canonical request bytes and digest and completes inside a session
loopex_daemon|test/external_socket_workflow_real_test.exs|a controller and observer complete the documented daemon workflow against a real provider
loopex_cli|test/multi_client_workflow_real_test.exs|a Node observer takes over from a killed CLI controller and a real provider answers it
loopex_cli|test/ask_real_test.exs|ephemeral ask answers from a local Ollama model through a separate process
loopex_composition|test/ephemeral_real_test.exs|the embedded API answers in-process from Anthropic with the release credential
EOF
release_manifest_valid "$manifest" "$tree" 11
rows=0
selected_rows=0
expected_rows=0
for row in 1 2 3 4 5 6 7 8 9 10 11; do
  if release_selected "real-provider-$row"; then expected_rows=$((expected_rows + 1)); fi
done
# The manifest is read on descriptor 3: the lanes keep the terminal as their
# standard input, where the two attended cases read the operator's answers.
while IFS='|' read -r -u 3 app file name; do
  rows=$((rows + 1))
  definitions=$(release_definition_lines "$tree/apps/$app/$file" "$name" || true)
  [ -n "$definitions" ] && [ "$(printf '%s\n' "$definitions" | wc -l | tr -d ' ')" = 1 ] ||
    { printf 'check-release: manifest row %s needs exactly one top-level Elixir.ExUnit.Case.test in %s\n' "$rows" "$app/$file" >&2; exit 1; }
  IFS=$'\t' read -r module line <<<"$definitions"
  [ -n "$module" ] && [[ "$line" =~ ^[1-9][0-9]*$ ]] ||
    { printf 'check-release: manifest row %s has an invalid module or line\n' "$rows" >&2; exit 1; }
  if release_selected "real-provider-$rows"; then
    selected_rows=$((selected_rows + 1))
    case "$rows" in
      10) credential_mode=without_credential ;;
      11) credential_mode=with_ephemeral_credential ;;
      *) credential_mode=with_credential ;;
    esac
    release_case_lane "real-provider-$rows" "$app" "$file" "$name" "$module" "$line" "$credential_mode"
  fi
done 3<"$manifest"
[ "$rows" -eq 11 ] || { printf 'check-release: the manifest contains %s rows, expected 11\n' "$rows" >&2; exit 1; }
[ "$selected_rows" -eq "$expected_rows" ] ||
  { printf 'check-release: the manifest ran %s selected rows, expected %s\n' "$selected_rows" "$expected_rows" >&2; exit 1; }
printf 'check-release: manifest rows=%s selected=%s\n' "$rows" "$selected_rows"

# The independent Node client, each application in its own VM. The CLI's case
# is the operator takeover: a killed CLI controller, a Node observer that takes
# over and aborts, each its own operating-system process.
node_client_apps="loopex_app_server loopex_protocol loopex_daemon loopex_cli"
if release_selected node_client; then
  for app in $node_client_apps; do
    lane "node-client-$app" "$app" nonzero without_credential mix test --only node_client
  done
fi


# The long-duration bound proofs: cases whose claim is a real wait, tagged
# long_bound and excluded from the fast check.
long_bound_apps="loopex loopex_executor_local loopex_daemon loopex_composition"
if release_selected long_bound; then
  for app in $long_bound_apps; do
    lane "long-bound-$app" "$app" nonzero without_credential mix test --only long_bound
  done
  lane long-bound-loopex_llm_reqllm loopex_llm_reqllm 1 without_credential \
    mix test test/in_process_transport_drain_test.exs --only long_bound
fi

# The cross-UID witness needs Linux's peer credential and a second user. Its
# two cases must both execute; elsewhere the run is visibly incomplete.
if release_selected cross_uid && [ "$platform" = Linux ]; then
  lane cross-uid loopex_daemon 2 without_credential mix test --only cross_uid
elif release_selected cross_uid; then
  printf 'cross_uid: not run (%s)\n' "$platform"
fi

# M7's credential-free rollback lane: current-format backup/restore with its
# complete manifests, and unknown-effect nonredispatch after recovery.
if release_selected m7-rollback; then
  lane m7-rollback-restore loopex_composition nonzero without_credential \
    mix test test/restore_workflow_test.exs
  lane m7-rollback-nonredispatch loopex_reference_client 1 without_credential \
    mix test test/end_to_end_recovery_test.exs \
    --only "test:test an effect without a durable receipt becomes outcome_unknown and is not blindly retried"
fi
release_matrix_close || { echo 'check-release: attempts index recorder failed' >&2; exit 1; }

# M7 conversation lanes run through the trusted fixture wrapper inside the
# extraction; each case is recorded before dispatch under the same matrix.
for m7_lane in m7-operator m7-provider; do
  release_selected "$m7_lane" || continue
  m7_wrapper=(--lane "$m7_lane" --attempts-index "$release_attempts_index" --writer "$release_writer"
    --host "$release_host" --markers "$release_markers" --run-root "$retain/m7-runs"
    --operator "$release_operator" --candidate "$commit")
  [ -z "${release_matrix_id:-}" ] || m7_wrapper+=(--matrix "$release_matrix_id")
  [ "$m7_lane" != m7-operator ] || m7_wrapper+=(--terminal)
  [ -z "${LOOPEX_M7_EXTERNAL_REPOSITORY:-}" ] ||
    m7_wrapper+=(--external-repository "$LOOPEX_M7_EXTERNAL_REPOSITORY")
  printf 'check-release: %s\n' "$m7_lane"
  (cd "$tree" && with_credential mix run --no-start scripts/m7-fixture-chat.exs -- \
    "${m7_wrapper[@]}" chat --config "$release_m7_config") ||
    { printf 'check-release: %s RED\n' "$m7_lane" >&2; exit 1; }
done
printf 'check-release: total=%ss\n' "$((SECONDS - started))"
if [ "$release_mode" = selection-only ]; then
  printf 'PASS (selection-only: not full closure evidence)\n'
elif [ "$platform" != Linux ]; then
  printf 'PASS (closure-incomplete: cross_uid not run)\n'
else
  printf 'PASS\n'
fi
