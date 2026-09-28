#!/usr/bin/env bash
# Exercise the released CLI escript, not a source-loaded substitute, against a
# candidate-created durable session and two distinct skill source locations.
set -euo pipefail
[ "$#" -eq 1 ] || { echo 'usage: rollback-binary-case.sh SCRATCH' >&2; exit 2; }
scratch=$1
cli="$scratch/old/apps/loopex_cli/loopex"
case_root="$scratch/new-to-old-read"
state_root="$case_root/state"
workspace="$case_root/workspace"
session_id=$(<"$case_root/session-id")
inert=loopex-rollback-inert-not-a-provider-key

without_keys() {
  env -u LOOPEX_PROVIDER_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
    -u OPENROUTER_API_KEY "$@"
}

if without_keys "$cli" resume "$session_id" --policy allow-all \
    --state-root "$state_root" --workspace "$workspace" \
    >"$scratch/old-no-key.out" 2>&1; then
  echo 'rollback: released resume accepted a missing credential' >&2
  exit 1
fi
grep -q ':provider_credential_required' "$scratch/old-no-key.out" || {
  echo 'rollback: missing-credential refusal was not specific' >&2
  exit 1
}
without_keys env LOOPEX_PROVIDER_API_KEY="$inert" "$cli" resume "$session_id" \
  --policy allow-all --state-root "$state_root" --workspace "$workspace" \
  >"$scratch/old-resume.out" 2>&1
grep -q 'loopex: done' "$scratch/old-resume.out" || {
  echo 'rollback: released CLI did not replay candidate history' >&2
  exit 1
}
printf 'rollback: released CLI missing-key refusal and candidate-history replay proved\n'

project="$workspace/.agents/skills/control"
external="$case_root/external/control"
mkdir -p "$project" "$external"
printf '%s\n' '---' 'name: control' 'description: project control' '---' \
  'Project skill control.' >"$project/SKILL.md"
printf '%s\n' '---' 'name: control' 'description: external user control' '---' \
  'External user skill.' >"$external/SKILL.md"
without_keys "$cli" skill show project:control:control --state-root "$state_root" \
  --workspace "$workspace" >"$scratch/old-project-skill.out" 2>&1
grep -q '^project:control:control$' "$scratch/old-project-skill.out" || {
  echo 'rollback: released CLI project skill control failed' >&2
  exit 1
}
if without_keys "$cli" skill show user:control:control --state-root "$state_root" \
    --workspace "$workspace" >"$scratch/old-user-skill.out" 2>&1; then
  echo 'rollback: released CLI unexpectedly discovered external user skill' >&2
  exit 1
fi
grep -q 'no installed skill is named user:control:control' "$scratch/old-user-skill.out" || {
  echo 'rollback: released CLI external user refusal was not specific' >&2
  exit 1
}
printf 'rollback: released CLI project skill and external user discovery controls proved\n'
