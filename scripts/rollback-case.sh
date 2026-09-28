#!/usr/bin/env bash
# One bidirectional pending-interaction witness over a retained durable root.
set -euo pipefail
[ "$#" -eq 3 ] || { echo 'usage: rollback-case.sh SCRATCH DIRECTION MODE' >&2; exit 2; }
scratch=$1 direction=$2 mode=$3
source_dir=$(cd "$(dirname "$0")/.." && pwd -P)
case "$direction" in
  old-to-new) writer=old reader=new ;;
  new-to-old) writer=new reader=old ;;
  *) echo 'rollback-case: invalid direction' >&2; exit 2 ;;
esac
case_root="$scratch/$direction-$mode"
workspace="$case_root/workspace"
state_root="$case_root/state"
mkdir -p "$workspace" "$state_root"
git -C "$workspace" init --quiet
printf 'rollback fixture content\n' >"$workspace/notes.md"

run_side() {
  local side=$1 phase=$2
  (
    cd "$scratch/$side/apps/loopex_app_server"
    env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY \
      LOOPEX_PROVIDER_API_KEY=loopex-rollback-inert-not-a-provider-key \
      MIX_ENV=prod mix run --no-start "$source_dir/scripts/rollback-case.exs" \
        "$phase" "$state_root" "$workspace" "$scratch/$side.launch" "$case_root" "$mode"
  )
}

run_side "$writer" writer
run_side "$reader" reader
printf 'rollback-case: %s completed across %s then %s\n' "$direction" "$writer" "$reader"
