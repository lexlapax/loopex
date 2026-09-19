#!/usr/bin/env bash
# The slow check, run before closure and release: the real-provider
# workflows, the independent Node client, and the fresh-source build. Needs a
# provider credential in LOOPEX_PROVIDER_API_KEY, which reaches only the test
# processes and is never printed, and the Node version pinned in
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
release_apps="loopex_app_server loopex_cli loopex_llm_reqllm loopex_protocol loopex_reference_client"
logs=$(mktemp -d "${TMPDIR:-/tmp}/loopex-release.XXXXXX")
trap 'rm -rf "$logs"' EXIT
for app in $release_apps; do
  printf 'check-release: %s\n' "$app"
  set +e
  (cd "apps/$app" && mix test --only real_provider --only node_client --include long_bound) 2>&1 | tee "$logs/$app.log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" -eq 0 ] || { printf 'check-release: %s RED\n' "$app" >&2; exit "$status"; }
  grep -qE '^Result: [1-9][0-9]* passed|^[1-9][0-9]* tests?, 0 failures' "$logs/$app.log" ||
    { printf 'check-release: %s executed no test\n' "$app" >&2; exit 1; }
done

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
  grep -qE '^Result: [1-9][0-9]* passed|^[1-9][0-9]* tests?, 0 failures' "$logs/$app-long.log" ||
    { printf 'check-release: %s executed no long-duration bound test\n' "$app" >&2; exit 1; }
done
printf 'check-release: PASS total=%ss\n' "$((SECONDS - started))"
