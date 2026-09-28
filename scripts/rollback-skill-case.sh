#!/usr/bin/env bash
# Candidate-admitted external user skill, reloaded by released offline resume.
set -euo pipefail
[ "$#" -eq 1 ] || { echo 'usage: rollback-skill-case.sh SCRATCH' >&2; exit 2; }
scratch=$1
source_dir=$(cd "$(dirname "$0")/.." && pwd -P)
case_root=$(mktemp -d /tmp/loopex-rb-skill.XXXXXX)
trap 'rm -rf "$case_root"' EXIT
workspace="$case_root/workspace"
state_root="$case_root/state"
external="$case_root/external/control"
mkdir -p "$workspace" "$state_root" "$external"
git -C "$workspace" init --quiet
printf '%s\n' '---' 'name: control' 'description: external user control' '---' \
  'Rollback user skill marker.' >"$external/SKILL.md"
printf 'rollback fixture content\n' >"$workspace/notes.md"
(
  cd "$scratch/new/apps/loopex_app_server"
  env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY \
    LOOPEX_PROVIDER_API_KEY=loopex-rollback-inert-not-a-provider-key \
    MIX_ENV=prod mix run --no-start "$source_dir/scripts/rollback-case.exs" \
      writer "$state_root" "$workspace" "$scratch/new.launch" "$case_root" skill
)
session_id=$(<"$case_root/session-id")
cli="$scratch/old/apps/loopex_cli/loopex"
env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY \
  LOOPEX_PROVIDER_API_KEY=loopex-rollback-inert-not-a-provider-key \
  "$cli" resume "$session_id" --policy allow-all \
    --state-root "$state_root" --workspace "$workspace" \
    >"$scratch/old-user-skill-resume.out" 2>&1
if grep -q 'admitted skill snapshot is unavailable' "$scratch/old-user-skill-resume.out"; then
  echo 'rollback: released CLI could not reload retained user snapshot' >&2
  exit 1
fi
grep -q 'loopex: done' "$scratch/old-user-skill-resume.out" || {
  echo 'rollback: released CLI did not resume user-skill session' >&2
  exit 1
}
printf 'rollback: released CLI reloaded candidate-admitted user skill by digest\n'
env -u LOOPEX_PROVIDER_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
  -u OPENROUTER_API_KEY "$cli" daemon prepare-index --state-root "$state_root" \
  >"$scratch/old-prepare-index.out" 2>&1

project="$workspace/.agents/skills/control"
mkdir -p "$project"
printf '%s\n' '---' 'name: control' 'description: project control' '---' \
  'Project skill control.' >"$project/SKILL.md"
socket="$state_root/daemon/d.sock"
env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY \
  LOOPEX_PROVIDER_API_KEY=loopex-rollback-inert-not-a-provider-key \
  "$cli" daemon --state-root "$state_root" --workspace "$workspace" \
    --provider-launch "$scratch/old.launch" --policy allow-all --socket "$socket" \
    >"$scratch/old-daemon.out" 2>"$scratch/old-daemon.err" &
daemon_pid=$!
stop_daemon() {
  if kill -0 "$daemon_pid" 2>/dev/null; then
    kill -TERM "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" || true
  fi
}
trap 'stop_daemon; rm -rf "$case_root"' EXIT
ready=0
for _attempt in $(seq 1 300); do
  if grep -q '"record":"daemon_ready"' "$scratch/old-daemon.out"; then ready=1; break; fi
  if ! kill -0 "$daemon_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
if [ "$ready" -ne 1 ]; then
  set +e
  wait "$daemon_pid"
  daemon_status=$?
  set -e
  printf 'rollback: released daemon did not become ready, status=%s\n' "$daemon_status" >&2
  exit 1
fi
(
  cd "$scratch/old/apps/loopex_cli"
  MIX_ENV=prod mix run --no-start "$source_dir/scripts/rollback-daemon-client.exs" \
    "$socket" "$case_root"
)
stop_daemon
trap 'rm -rf "$case_root"' EXIT
