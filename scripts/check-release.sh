#!/usr/bin/env bash
# The slow check, run once from the exact candidate before closure. It stages
# the candidate as a fresh source archive, builds it there as an operator
# would, and runs every lane inside that extraction: the real-provider
# workflows, the independent Node client, the long-duration bound proofs and,
# on Linux, the cross-UID witness. An
# unchanged-source release reuses that evidence and does not run this command
# again. It needs a provider credential in LOOPEX_PROVIDER_API_KEY, which
# reaches only the eight manifest test processes and is never printed. It also
# needs the Node version pinned in scripts/fixtures/m4/client-toolchain.txt
# and, on Linux, a second unprivileged user named in LOOPEX_CROSS_UID_USER that
# the current user may run a command as with `sudo -n`. Output streams as it
# happens.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

[ -n "${LOOPEX_PROVIDER_API_KEY:-}" ] ||
  { echo 'check-release: LOOPEX_PROVIDER_API_KEY is required' >&2; exit 2; }
export LOOPEX_PROVIDER_API_KEY
pinned_node=$(awk -F= '$1 == "node" { print $2 }' scripts/fixtures/m4/client-toolchain.txt)
observed_node=$(node --version 2>/dev/null </dev/null || true)
[ "$observed_node" = "v$pinned_node" ] ||
  { echo "check-release: Node v$pinned_node is required, found ${observed_node:-none}" >&2; exit 2; }
[ -z "$(git status --porcelain)" ] ||
  { echo 'check-release: the tree must be the committed candidate' >&2; exit 2; }

started=$SECONDS
platform=$(uname -s)
commit=$(git rev-parse HEAD)
release_version=0.2.0
printf 'check-release: candidate %s on %s %s\n' "$commit" "$platform" "$(uname -m)"
logs=$(mktemp -d "${TMPDIR:-/tmp}/loopex-release.XXXXXX")
fresh=$(mktemp -d "${TMPDIR:-/tmp}/loopex-fresh.XXXXXX")
trap 'rm -rf "$logs" "$fresh"' EXIT
# A caller's build-path overrides would move the extraction's builds outside
# it; every build here belongs to the extraction.
unset MIX_BUILD_PATH MIX_BUILD_ROOT

# Reference composition consumes and deletes the credential, so each
# credential-consuming case runs in its own operating-system process that
# inherits it once; every other lane runs with the name removed.
with_credential() { "$@"; }
without_credential() { env -u LOOPEX_PROVIDER_API_KEY "$@"; }
# The wrapper self-check plants a synthetic value and reports only whether each
# wrapper's child sees the name, never a value.
(
  LOOPEX_PROVIDER_API_KEY=release-self-check-synthetic
  probe='if [ -n "${LOOPEX_PROVIDER_API_KEY+set}" ]; then echo present; else echo absent; fi'
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
tree="$fresh/src"
printf 'check-release: fresh-source extraction of %s\n' "$commit"
(umask 0777; (umask 022; mkdir "$tree" && git archive "$commit" | tar -x -C "$tree"))
bash "$tree/scripts/source-archive-manifest.sh" "$tree" >"$retain/source-archive-manifest"
git ls-files -z >"$retain/source-inventory"
elixir scripts/source-archive-check.exs verify \
  "$retain/source-archive-manifest" "$retain/source-inventory" "$commit" "$tree"
(cd "$tree" && without_credential mix deps.get &&
  MIX_ENV=prod without_credential mix cmd --app loopex_cli mix escript.build) 2>&1 |
  tee "$logs/fresh-source-build.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo 'check-release: fresh-source build RED' >&2; exit 1; }
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
if command -v sha256sum >/dev/null 2>&1; then digest() { sha256sum "$1" | awk '{print $1}'; }
else digest() { shasum -a 256 "$1" | awk '{print $1}'; }; fi
for retained in source-archive-manifest source-inventory; do
  printf 'check-release: retained %s sha256=%s\n' "$retain/$retained" "$(digest "$retain/$retained")"
done
printf 'check-release: fresh-source elapsed=%ss\n' "$((SECONDS - fresh_started))"

# One lane: run its command in one application, stream to its own named log,
# print its elapsed time, and require its executed count to be exactly the
# expected number, or at least one when that is `nonzero`. The count is read by
# the suite judge from either supported toolchain's result line.
lane() {
  local label=$1 app=$2 expected=$3 wrap=$4 lane_started=$SECONDS status executed
  shift 4
  printf 'check-release: %s\n' "$label"
  set +e
  (cd "$tree/apps/$app" && "$wrap" "$@") 2>&1 | tee "$logs/$label.log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" -eq 0 ] ||
    { printf 'check-release: %s RED status=%s elapsed=%ss\n' "$label" "$status" "$((SECONDS - lane_started))" >&2; exit 1; }
  executed=$(bash "$tree/scripts/suite-summary.sh" "$logs/$label.log" --count) ||
    { printf 'check-release: %s executed no test\n' "$label" >&2; exit 1; }
  if [ "$expected" != nonzero ] && [ "$executed" != "$expected" ]; then
    printf 'check-release: %s executed %s tests, expected exactly %s\n' "$label" "$executed" "$expected" >&2
    exit 1
  fi
  printf 'check-release: %s executed=%s elapsed=%ss\n' "$label" "$executed" "$((SECONDS - lane_started))"
}

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
EOF
rows=0
# The manifest is read on descriptor 3: the lanes keep the terminal as their
# standard input, where the two attended cases read the operator's answers.
while IFS='|' read -r -u 3 app file name; do
  rows=$((rows + 1))
  definitions=$(grep -nF "test \"$name\"" "$tree/apps/$app/$file" || true)
  [ -n "$definitions" ] && [ "$(printf '%s\n' "$definitions" | wc -l | tr -d ' ')" = 1 ] ||
    { printf 'check-release: manifest row %s is not defined exactly once in %s\n' "$rows" "$app/$file" >&2; exit 1; }
  line=${definitions%%:*}
  lane "real-provider-$rows" "$app" 1 with_credential mix test "$file:$line" --only real_provider
done 3<"$manifest"
[ "$rows" -eq 8 ] || { printf 'check-release: the manifest ran %s rows, expected 8\n' "$rows" >&2; exit 1; }

# The independent Node client, each application in its own VM. The CLI's case
# is the operator takeover: a killed CLI controller, a Node observer that takes
# over and aborts, each its own operating-system process.
node_client_apps="loopex_app_server loopex_protocol loopex_daemon loopex_cli"
for app in $node_client_apps; do
  lane "node-client-$app" "$app" nonzero without_credential mix test --only node_client
done


# The long-duration bound proofs: cases whose claim is a real wait, tagged
# long_bound and excluded from the fast check.
long_bound_apps="loopex loopex_executor_local loopex_daemon"
for app in $long_bound_apps; do
  lane "long-bound-$app" "$app" nonzero without_credential mix test --only long_bound
done

# The cross-UID witness needs Linux's peer credential and a second user. Its
# two cases must both execute; elsewhere the run is visibly incomplete.
if [ "$platform" = Linux ]; then
  lane cross-uid loopex_daemon 2 without_credential mix test --only cross_uid
  printf 'check-release: total=%ss\n' "$((SECONDS - started))"
  printf 'PASS\n'
else
  printf 'cross_uid: not run (%s)\n' "$platform"
  printf 'check-release: total=%ss\n' "$((SECONDS - started))"
  printf 'PASS (closure-incomplete: cross_uid not run)\n'
fi
