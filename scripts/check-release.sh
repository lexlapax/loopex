#!/usr/bin/env bash
# The slow check, run once from the exact candidate before closure: the
# real-provider workflows, the independent Node client, the fresh-source build,
# and the long-duration bound proofs. An unchanged-source release reuses that
# evidence and does not run this command again. It needs a provider credential in LOOPEX_PROVIDER_API_KEY,
# which reaches only the test processes and is never printed. It also needs
# the Node version pinned in
# scripts/fixtures/m4/client-toolchain.txt. Output streams as it happens.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

[ -n "${LOOPEX_PROVIDER_API_KEY:-}" ] ||
  { echo 'check-release: LOOPEX_PROVIDER_API_KEY is required' >&2; exit 2; }
pinned_node=$(awk -F= '$1 == "node" { print $2 }' scripts/fixtures/m4/client-toolchain.txt)
observed_node=$(node --version 2>/dev/null </dev/null || true)
[ "$observed_node" = "v$pinned_node" ] ||
  { echo "check-release: Node v$pinned_node is required, found ${observed_node:-none}" >&2; exit 2; }
[ -z "$(git status --porcelain)" ] ||
  { echo 'check-release: the tree must be the committed candidate' >&2; exit 2; }

started=$SECONDS
printf 'check-release: candidate %s on %s %s\n' "$(git rev-parse HEAD)" "$(uname -s)" "$(uname -m)"
# Each application runs in its own VM: a test that alters the environment or
# global state then cannot reach the applications that run after it.
# The applications that carry release tests, named rather than discovered so
# that a tag refactor cannot drop one silently; each must execute at least one
# test, because a run that executed nothing is not a pass. Each runs in its own
# VM so no test can reach the applications after it.
release_apps="loopex_app_server loopex_cli loopex_daemon loopex_llm_reqllm loopex_protocol loopex_reference_client"
logs=$(mktemp -d "${TMPDIR:-/tmp}/loopex-release.XXXXXX")
trap 'rm -rf "$logs"' EXIT
for app in $release_apps; do
  printf 'check-release: %s\n' "$app"
  set +e
  (cd "apps/$app" && mix test --only real_provider --only node_client --include long_bound) 2>&1 | tee "$logs/$app.log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" -eq 0 ] || { printf 'check-release: %s RED\n' "$app" >&2; exit "$status"; }
  bash scripts/suite-summary.sh "$logs/$app.log" >/dev/null ||
    { printf 'check-release: %s executed no test\n' "$app" >&2; exit 1; }
done

# The fresh-source lane: stage the exact candidate with `git archive` into a
# fresh extraction under the canonical scoped `umask 022`, launched from a
# hostile caller `umask 0777`; retain its pre-build manifest and the source
# inventory outside the extraction; prove the extraction is exactly the
# commit; run the documented build inside it; and prove the build changed
# nothing but its declared outputs. The retained files stay after the run.
commit=$(git rev-parse HEAD)
retain=${LOOPEX_RELEASE_RETAIN:-$(mktemp -d "${TMPDIR:-/tmp}/loopex-retained.XXXXXX")}
fresh=$(mktemp -d "${TMPDIR:-/tmp}/loopex-fresh.XXXXXX")
tree="$fresh/src"
printf 'check-release: fresh-source extraction of %s\n' "$commit"
(umask 0777; (umask 022; mkdir "$tree" && git archive "$commit" | tar -x -C "$tree"))
bash "$tree/scripts/source-archive-manifest.sh" "$tree" >"$retain/source-archive-manifest"
git ls-files -z >"$retain/source-inventory"
elixir scripts/source-archive-check.exs verify \
  "$retain/source-archive-manifest" "$retain/source-inventory" "$commit" "$tree"
(cd "$tree" && mix deps.get && MIX_ENV=prod mix cmd --app loopex_cli mix escript.build) 2>&1 |
  tee "$logs/fresh-source-build.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo 'check-release: fresh-source build RED' >&2; exit 1; }
bash "$tree/scripts/source-archive-manifest.sh" "$tree" >"$retain/source-archive-manifest.after"
elixir scripts/source-archive-check.exs unchanged \
  "$retain/source-archive-manifest" "$retain/source-archive-manifest.after"
grep -q "\"source\" => \"$commit\"\|<<\"source\">> => <<\"$commit\">>" \
  "$tree/_build/prod/loopex_provider.manifest" ||
  { echo 'check-release: the fresh build does not report the staged commit' >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then digest() { sha256sum "$1" | awk '{print $1}'; }
else digest() { shasum -a 256 "$1" | awk '{print $1}'; }; fi
for retained in source-archive-manifest source-inventory; do
  printf 'check-release: retained %s sha256=%s\n' "$retain/$retained" "$(digest "$retain/$retained")"
done
rm -rf "$fresh"

# The long-duration bound proofs: cases whose claim is a real wait, tagged
# long_bound and excluded from the fast check. They live in applications with
# no other release test, so they get their own pass with the same guard.
long_bound_apps="loopex loopex_executor_local"
for app in $long_bound_apps; do
  printf 'check-release: %s long-duration bounds\n' "$app"
  set +e
  (cd "apps/$app" && mix test --only long_bound) 2>&1 | tee "$logs/$app-long.log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" -eq 0 ] || { printf 'check-release: %s long-duration bounds RED\n' "$app" >&2; exit "$status"; }
  bash scripts/suite-summary.sh "$logs/$app-long.log" >/dev/null ||
    { printf 'check-release: %s executed no long-duration bound test\n' "$app" >&2; exit 1; }
done
printf 'check-release: PASS total=%ss\n' "$((SECONDS - started))"
