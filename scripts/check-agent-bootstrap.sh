#!/usr/bin/env bash
# Portable seed check for project instructions, skills, and client adapters.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  echo "agent bootstrap check failed: $*" >&2
  exit 1
}

for command in bash git cat grep jq python3 readlink sed tr; do
  command -v "$command" >/dev/null 2>&1 || fail "missing $command"
done

python3 scripts/check-agent-bootstrap.py

[ "$(tr -d '\r\n' < CLAUDE.md)" = "@AGENTS.md" ] ||
  fail "CLAUDE.md must contain only @AGENTS.md"

[ -s DEVELOPMENT.md ] || fail "missing DEVELOPMENT.md"
grep -Fq '[DEVELOPMENT.md](DEVELOPMENT.md)' README.md ||
  fail "README.md must link DEVELOPMENT.md"
grep -Fq 'bash scripts/check-bootstrap.sh' DEVELOPMENT.md ||
  fail "DEVELOPMENT.md must name the provider-neutral bootstrap command"

[ -L .claude/skills ] || fail ".claude/skills must be a symlink"
[ "$(readlink .claude/skills)" = "../.agents/skills" ] ||
  fail ".claude/skills must point to ../.agents/skills"

for skill in adr gate close-milestone; do
  [ -s ".agents/skills/$skill/SKILL.md" ] || fail "missing $skill skill"
  [ -s ".agents/skills/$skill/agents/openai.yaml" ] ||
    fail "missing $skill OpenAI metadata"
  [ -s ".claude/skills/$skill/SKILL.md" ] ||
    fail "Claude cannot resolve $skill"
done

jq empty .claude/settings.json
bash -n .claude/hooks/*.sh scripts/*.sh

for hook in .claude/hooks/*.sh; do
  [ -x "$hook" ] || fail "$hook is not executable"
done

for repository_check in scripts/check*.sh; do
  [ -x "$repository_check" ] || fail "$repository_check is not executable"
done

if grep -nE 'Bash\(git (add|commit|worktree)' .claude/settings.json >/dev/null; then
  fail "Claude settings auto-allow mutating Git commands"
fi

if grep -rnE 'gpt-5\.6-(luna|terra|sol)|(^|[^[:alnum:]_])(Luna|Terra|Sol)([^[:alnum:]_]|$)' .codex >/dev/null; then
  fail "Codex config contains an account-specific model alias"
fi

if grep -rnE 'findings inform, gates decide|Append a closure note|Status.*Proposed/Accepted' \
  .agents/skills >/dev/null; then
  fail "shared skill contains superseded authority language"
fi

if grep -rnE "CI owns enforcement|full gates are CI's job|Move to CI gates|get their own workflow" \
  AGENTS.md .claude .github docs/developer >/dev/null; then
  fail "hosted CI is described as owning repository enforcement"
fi

for duplicate in \
  docs/archive/loopex-AGENT-CONTEXT.md \
  docs/archive/loopex-AGENTS.md \
  docs/archive/loopex-README.md \
  docs/archive/loopex-dotcodex-config.toml \
  docs/archive/loopex-vision.md; do
  [ ! -e "$duplicate" ] || fail "redundant archive snapshot remains: $duplicate"
done

guard() {
  jq -nc --arg command "$1" '{tool_input:{command:$command}}' |
    .claude/hooks/guard-bash.sh >/dev/null 2>&1
}

file_guard() {
  local field="$1"
  local path_value="$2"
  jq -nc --arg field "$field" --arg path_value "$path_value" \
    '{tool_input:{($field):$path_value}}' |
    .claude/hooks/guard-filesystem.sh >/dev/null 2>&1
}

deny_commands=(
  'ls ~/.loopex'
  'ls $HOME/.loopex'
  'ls ${HOME}/.loopex'
  'ls "$HOME"/".loopex"'
  "ls ${HOME%/}/.loopex"
)
for command_text in "${deny_commands[@]}"; do
  set +e
  guard "$command_text"
  guard_result=$?
  set -e
  [ "$guard_result" -eq 2 ] ||
    fail "real-home guard returned $guard_result, expected deny 2: $command_text"
done

allow_commands=(
  'git status'
  'ls /tmp/loopex-smoke'
  'LOOPEX_HOME="$(mktemp -d)" mix test'
)
for command_text in "${allow_commands[@]}"; do
  set +e
  guard "$command_text"
  guard_result=$?
  set -e
  [ "$guard_result" -eq 0 ] ||
    fail "real-home guard returned $guard_result, expected allow 0: $command_text"
done

deny_paths=(
  '~/.loopex/journal'
  '$HOME/.loopex/journal'
  '${HOME}/.loopex/journal'
  '${HOME%/}/.loopex/journal'
  "${HOME%/}/.loopex/journal"
)
for field in file_path notebook_path path; do
  for path_text in "${deny_paths[@]}"; do
    set +e
    file_guard "$field" "$path_text"
    guard_result=$?
    set -e
    [ "$guard_result" -eq 2 ] ||
      fail "file guard returned $guard_result, expected deny 2: $field=$path_text"
  done
done

for path_text in AGENTS.md /tmp/loopex-smoke; do
  set +e
  file_guard file_path "$path_text"
  guard_result=$?
  set -e
  [ "$guard_result" -eq 0 ] ||
    fail "file guard returned $guard_result, expected allow 0: $path_text"
done

echo "agent bootstrap check passed"
