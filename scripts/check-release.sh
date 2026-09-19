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
for app in apps/*/; do
  app=${app%/}
  # An application with no tagged test is skipped: `mix test --only` treats
  # running nothing as a failure, and here it is simply nothing to run.
  grep -rqE '@(module)?tag :(real_provider|node_client)' "$app/test" || continue
  printf 'check-release: %s\n' "${app#apps/}"
  (cd "$app" && mix test --only real_provider --only node_client)
done
printf 'check-release: PASS total=%ss\n' "$((SECONDS - started))"
