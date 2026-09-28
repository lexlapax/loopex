#!/usr/bin/env bash
# Cross-version dispatched-effect proof with one real M6 Local receipt and
# separately identified v0.2 Local versus controlled executor-port outcomes.
set -euo pipefail
[ "$#" -eq 1 ] || { echo 'usage: rollback-dispatched-case.sh SCRATCH' >&2; exit 2; }
scratch=$1
source_dir=$(cd "$(dirname "$0")/.." && pwd -P)
base=$(mktemp -d "$scratch/dispatched-base.XXXXXX")
workspace="$base/workspace"
mkdir -p "$workspace" "$base/state"
git -C "$workspace" init --quiet
printf 'rollback fixture content\n' >"$workspace/notes.md"
(
  cd "$scratch/new/apps/loopex_app_server"
  MIX_ENV=prod mix run --no-start "$source_dir/scripts/rollback-dispatched.exs" \
    writer "$base" "$workspace"
)
[ -s "$base/receipt.etf" ] || { echo 'rollback-dispatched: real receipt absent' >&2; exit 1; }
snapshot=$(mktemp -d "$scratch/dispatched-snapshot.XXXXXX")
cp -R "$base/state" "$snapshot/state"
for answer in matching absent effect_unresolved effect_settling effect_in_flight invalid_retained_receipt; do
  # The Local ledger binds its generation to the root's device and inode.
  # Restore bytes in place, without replacing that directory or its receipts.
  cp -R "$snapshot/state/." "$base/state/"
  (
    cd "$scratch/old/apps/loopex_app_server"
    MIX_ENV=prod mix run --no-start "$source_dir/scripts/rollback-dispatched.exs" \
      reader "$base" "$workspace" "$answer"
  )
done
printf 'rollback-dispatched: PASS real candidate receipt and named released recovery dispositions\n'
