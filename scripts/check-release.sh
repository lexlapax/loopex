#!/usr/bin/env bash
# The slow check, run once from the exact candidate before closure. It stages
# the candidate as a fresh source archive, builds it there as an operator
# would, and runs every lane inside that extraction: the real-provider
# workflows, the independent Node client, the long-duration bound proofs and,
# on Linux, the cross-UID witness. An
# unchanged-source release reuses that evidence and does not run this command
# again. It needs a provider credential in LOOPEX_PROVIDER_API_KEY, which
# reaches only the nine manifest test processes and is never printed. It also
# needs the Node version pinned in scripts/fixtures/m4/client-toolchain.txt
# and, on Linux, a second unprivileged user named in LOOPEX_CROSS_UID_USER that
# the current user may run a command as with `sudo -n`. Output streams as it
# happens. Repeated --only selectors run unattended pre-merge lanes, not the
# full closure matrix. Invalid selections refuse before staging or builds.
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
source "$script_dir/lib/release-lane.sh"
release_select "$@"
cd "$(git rev-parse --show-toplevel)"

if release_needs_provider; then
  [ -n "${LOOPEX_PROVIDER_API_KEY:-}" ] ||
    { echo 'check-release: LOOPEX_PROVIDER_API_KEY is required for the selected provider rows' >&2; exit 2; }
  export LOOPEX_PROVIDER_API_KEY
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
# credential-consuming case runs in its own operating-system process that
# inherits it once; every other lane runs with the name removed.
with_credential() { env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY "$@"; }
without_credential() { env -u LOOPEX_PROVIDER_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY "$@"; }
# The wrapper self-check plants a synthetic value and reports only whether each
# wrapper's child sees the name, never a value.
(
  LOOPEX_PROVIDER_API_KEY=release-self-check-synthetic
  OPENAI_API_KEY=release-self-check-synthetic
  ANTHROPIC_API_KEY=release-self-check-synthetic
  OPENROUTER_API_KEY=release-self-check-synthetic
  export LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
  probe='if [ -n "${LOOPEX_PROVIDER_API_KEY+set}${OPENAI_API_KEY+set}${ANTHROPIC_API_KEY+set}${OPENROUTER_API_KEY+set}" ]; then echo present; else echo absent; fi'
  seen=$(with_credential sh -c "$probe")
  unseen=$(without_credential sh -c "$probe")
  printf 'check-release: credential self-check: manifest=%s other=%s\n' "$seen" "$unseen"
  [ "$seen" = present ] && [ "$unseen" = absent ]
) || { echo 'check-release: credential wrapper self-check RED' >&2; exit 1; }

# The fresh-source lane: stage the exact candidate with `git archive` into a
# fresh extraction under the canonical scoped `umask 022`, launched from a
# hostile caller `umask 0777`; retain its pre-build manifest and the source
# inventory outside the extraction; prove the extraction is exactly the
# commit; run the documented build inside it; and prove the build changed
# nothing but its declared outputs. The retained files stay after the run;
# every later lane runs inside this extraction.
fresh_started=$SECONDS
retain=${LOOPEX_RELEASE_RETAIN:-$(mktemp -d "${TMPDIR:-/tmp}/loopex-retained.XXXXXX")}
[ -d "$retain" ] || { echo 'check-release: retained output directory must exist' >&2; exit 2; }
retain=$(cd "$retain" && pwd -P)
checkout=$(pwd -P)
case "$retain/" in
  "$checkout/"*) echo 'check-release: retained output must be outside the checkout' >&2; exit 2 ;;
esac
# Refuse reused evidence paths before an extraction can overwrite any retained
# byte. The scoped umask makes newly created evidence private to this user.
for retained in source-archive-manifest source-inventory source-archive-manifest.after fresh-source-build.log; do
  (umask 077; set -C; : >"$retain/$retained") 2>/dev/null ||
    { printf 'check-release: retained path unavailable or already exists: %s\n' "$retain/$retained" >&2; exit 2; }
done
tree="$fresh/src"
printf 'check-release: fresh-source extraction of %s\n' "$commit"
(umask 0777; (umask 022; mkdir "$tree" && git archive "$commit" | tar -x -C "$tree"))
bash "$tree/scripts/source-archive-manifest.sh" "$tree" >"$retain/source-archive-manifest"
git ls-files -z >"$retain/source-inventory"
elixir scripts/source-archive-check.exs verify \
  "$retain/source-archive-manifest" "$retain/source-inventory" "$commit" "$tree"
set +e
(cd "$tree" && without_credential mix deps.get &&
  MIX_ENV=prod without_credential mix cmd --app loopex_cli mix escript.build) 2>&1 |
  tee "$retain/fresh-source-build.log"
build_statuses=("${PIPESTATUS[@]}")
set -e
printf 'build-evidence: command_status=%s tee_status=%s duration_seconds=%s\n' \
  "${build_statuses[0]}" "${build_statuses[1]}" "$((SECONDS - fresh_started))" >>"$retain/fresh-source-build.log"
release_retain_identity "$retain/fresh-source-build.log"
[ "${build_statuses[0]}" -eq 0 ] && [ "${build_statuses[1]}" -eq 0 ] ||
  { echo 'check-release: fresh-source build RED' >&2; exit 1; }
bash "$tree/scripts/source-archive-manifest.sh" "$tree" >"$retain/source-archive-manifest.after"
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

# The real-provider manifest: application, test file and exact case name. Each
# name must be defined exactly once; its current line selects that case alone.
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
EOF
release_manifest_valid "$manifest" "$tree" 9
rows=0
selected_rows=0
expected_rows=0
for row in 1 2 3 4 5 6 7 8 9; do
  if release_selected "real-provider-$row"; then expected_rows=$((expected_rows + 1)); fi
done
# The manifest is read on descriptor 3: the lanes keep the terminal as their
# standard input, where the two attended cases read the operator's answers.
while IFS='|' read -r -u 3 app file name; do
  rows=$((rows + 1))
  definitions=$(grep -nF "test \"$name\"" "$tree/apps/$app/$file" || true)
  [ -n "$definitions" ] && [ "$(printf '%s\n' "$definitions" | wc -l | tr -d ' ')" = 1 ] ||
    { printf 'check-release: manifest row %s is not defined exactly once in %s\n' "$rows" "$app/$file" >&2; exit 1; }
  line=${definitions%%:*}
  if release_selected "real-provider-$rows"; then
    selected_rows=$((selected_rows + 1))
    lane "real-provider-$rows" "$app" 1 with_credential mix test "$file:$line" --only real_provider
  fi
done 3<"$manifest"
[ "$rows" -eq 9 ] || { printf 'check-release: the manifest contains %s rows, expected 9\n' "$rows" >&2; exit 1; }
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
long_bound_apps="loopex loopex_executor_local loopex_daemon"
if release_selected long_bound; then
  for app in $long_bound_apps; do
    lane "long-bound-$app" "$app" nonzero without_credential mix test --only long_bound
  done
fi

# The cross-UID witness needs Linux's peer credential and a second user. Its
# two cases must both execute; elsewhere the run is visibly incomplete.
if release_selected cross_uid && [ "$platform" = Linux ]; then
  lane cross-uid loopex_daemon 2 without_credential mix test --only cross_uid
elif release_selected cross_uid; then
  printf 'cross_uid: not run (%s)\n' "$platform"
fi
printf 'check-release: total=%ss\n' "$((SECONDS - started))"
if [ "$release_mode" = selection-only ]; then
  printf 'PASS (selection-only: not full closure evidence)\n'
elif [ "$platform" != Linux ]; then
  printf 'PASS (closure-incomplete: cross_uid not run)\n'
else
  printf 'PASS\n'
fi
