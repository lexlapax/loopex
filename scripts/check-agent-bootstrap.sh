#!/usr/bin/env bash
# Portable seed check for project instructions, skills, and client adapters.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  echo "agent bootstrap check failed: $*" >&2
  exit 1
}

for command in python3 jq; do
  command -v "$command" >/dev/null 2>&1 || fail "missing $command"
done

[ "$(tr -d '\r\n' < CLAUDE.md)" = "@AGENTS.md" ] ||
  fail "CLAUDE.md must contain only @AGENTS.md"

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

python3 - <<'PY'
from pathlib import Path
import tomllib

root = Path(".codex")
config = tomllib.loads((root / "config.toml").read_text())
assert config.get("features", {}).get("multi_agent_v2") is True, \
    "multi_agent_v2 must expose project custom agents"
roles = config.get("agents", {})
assert roles, "no Codex roles registered"
for key, entry in roles.items():
    profile_path = root / entry["config_file"]
    profile = tomllib.loads(profile_path.read_text())
    assert profile["name"] == key, (key, profile_path, profile["name"])
    assert profile["description"] == entry["description"], (key, "description drift")
    assert profile.get("developer_instructions", "").strip(), (key, "missing instructions")
    assert "model" not in profile, (key, "project-local model pin")
PY

jq empty .claude/settings.json
bash -n .claude/hooks/*.sh scripts/check-agent-bootstrap.sh

python3 - <<'PY'
import json
from pathlib import Path

settings = json.loads(Path(".claude/settings.json").read_text())
pre_hooks = settings.get("hooks", {}).get("PreToolUse", [])
expected_hooks = {
    "Bash": "${CLAUDE_PROJECT_DIR}/.claude/hooks/guard-bash.sh",
    "Read|Grep|Glob|Edit|Write|NotebookEdit": (
        "${CLAUDE_PROJECT_DIR}/.claude/hooks/guard-filesystem.sh"
    ),
}
for matcher, command in expected_hooks.items():
    matching = [entry for entry in pre_hooks if entry.get("matcher") == matcher]
    assert len(matching) == 1, (matcher, "missing or duplicate PreToolUse registration")
    commands = [hook.get("command") for hook in matching[0].get("hooks", [])]
    assert commands == [command], (matcher, "incorrect guard wiring", commands)

denies = set(settings.get("permissions", {}).get("deny", []))
# Claude Code consults path rules for Read(path) and Edit(path) only: Read
# rules cover Grep/Glob reads, Edit rules cover all file-editing tools. Path
# rules on the other tools are accepted but never consulted and warn at
# startup, so their presence is a defect, not extra protection.
for tool in ("Read", "Edit"):
    rule = f"{tool}(~/.loopex/**)"
    assert rule in denies, (tool, "missing real-home deny rule")
for tool in ("Grep", "Glob", "Write", "NotebookEdit"):
    rule = f"{tool}(~/.loopex/**)"
    assert rule not in denies, (tool, "inert path rule; use Read/Edit instead")
PY

for hook in .claude/hooks/*.sh; do
  [ -x "$hook" ] || fail "$hook is not executable"
done

reviewer_tools="$(sed -n 's/^tools:[[:space:]]*//p' .claude/agents/reviewer.md)"
if printf '%s' "$reviewer_tools" | tr -d '[:space:]' |
  grep -Eq '(^|,)(Bash|Edit|Write|NotebookEdit)(,|$)'; then
  fail "Claude reviewer has a mutating or command tool"
fi

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
