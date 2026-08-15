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

python3 - <<'PY'
import sys
if not __debug__:
    raise SystemExit("Python optimization disables bootstrap assertions")
assert sys.version_info >= (3, 11), "Python 3.11+ is required for tomllib"
PY

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

python3 - <<'PY'
from pathlib import Path
import tomllib

root = Path(".codex")
config_text = (root / "config.toml").read_text()
config = tomllib.loads(config_text)
assert config.get("features", {}).get("multi_agent_v2") is True, \
    "multi_agent_v2 must expose project custom agents"
for pointer in ("AGENTS.md", "docs/developer/agent-context-map.md"):
    assert pointer in config_text, ("Codex config missing canonical pointer", pointer)
assert config_text.index("AGENTS.md") < config_text.index(
    "docs/developer/agent-context-map.md"
), "Codex config must route AGENTS.md before the context map"

roles = config.get("agents", {})
assert roles, "no Codex roles registered"
expected_sandboxes = {
    "mechanical_worker": "workspace-write",
    "milestone_worker": "workspace-write",
    "release_architect": "read-only",
    "release_reviewer": "read-only",
}
assert set(roles) == set(expected_sandboxes), ("unexpected Codex roles", sorted(roles))
prologue = (
    "Authority loads first: `AGENTS.md`, then "
    "`docs/developer/agent-context-map.md` for routing and current-stage guidance. "
    "This profile only frames the assigned role."
)
for key, entry in roles.items():
    profile_path = root / entry["config_file"]
    profile = tomllib.loads(profile_path.read_text())
    assert profile["name"] == key, (key, profile_path, profile["name"])
    assert profile["description"] == entry["description"], (key, "description drift")
    instructions = profile.get("developer_instructions", "").strip()
    assert instructions, (key, "missing instructions")
    assert " ".join(instructions.split()).startswith(prologue), \
        (key, "canonical context prologue missing or out of order")
    assert profile.get("sandbox_mode") == expected_sandboxes[key], \
        (key, "sandbox drift", profile.get("sandbox_mode"))
    assert "model" not in profile, (key, "project-local model pin")
PY

jq empty .claude/settings.json
bash -n .claude/hooks/*.sh scripts/*.sh

python3 - <<'PY'
import json
from pathlib import Path


def markdown_frontmatter(path):
    text = path.read_text()
    lines = text.splitlines()
    assert lines and lines[0] == "---", (path, "missing frontmatter")
    try:
        end = lines.index("---", 1)
    except ValueError as error:
        raise AssertionError((path, "unterminated frontmatter")) from error
    fields = {}
    for line in lines[1:end]:
        if ":" in line:
            key, value = line.split(":", 1)
            key = key.strip()
            assert key not in fields, (path, "duplicate frontmatter key", key)
            fields[key] = value.strip()
    return fields, "\n".join(lines[end + 1:])


def assert_ordered_pointers(path, body):
    contract = "AGENTS.md"
    context = "docs/developer/agent-context-map.md"
    assert contract in body and context in body, (path, "missing canonical pointer")
    assert body.index(contract) < body.index(context), (path, "pointer order")

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

claude_agents = set(Path(".claude/agents").glob("*.md"))
expected_claude_agents = {
    Path(".claude/agents/conformance-author.md"),
    Path(".claude/agents/reviewer.md"),
}
assert claude_agents == expected_claude_agents, (
    "unexpected Claude agents",
    sorted(map(str, claude_agents)),
)
for path in sorted(claude_agents):
    fields, body = markdown_frontmatter(path)
    assert_ordered_pointers(path, body)
    if path.name == "reviewer.md":
        tools = [item.strip() for item in fields.get("tools", "").split(",")]
        assert tools == ["Read", "Grep", "Glob"], (path, "reviewer tools", tools)
        assert fields.get("permissionMode") == "plan", (path, "reviewer permissionMode")

for path in sorted(Path(".agents/skills").glob("*/SKILL.md")):
    fields, body = markdown_frontmatter(path)
    assert_ordered_pointers(path, body)
    if path.parent.name in {"gate", "close-milestone"}:
        assert fields.get("disable-model-invocation") == "true", (
            path,
            "Claude protected workflow must require explicit invocation",
        )
        metadata = (path.parent / "agents/openai.yaml").read_text()
        metadata_lines = metadata.splitlines()
        assert metadata_lines.count("policy:") == 1, (
            path,
            "Codex metadata must contain exactly one policy mapping",
        )
        policy_index = metadata_lines.index("policy:")
        invocation_lines = [
            line for line in metadata_lines if "allow_implicit_invocation:" in line
        ]
        assert invocation_lines == ["  allow_implicit_invocation: false"], (
            path,
            "Codex protected workflow must require explicit invocation",
        )
        assert metadata_lines[policy_index + 1] == invocation_lines[0], (
            path,
            "Codex invocation policy must be nested under policy",
        )
    else:
        assert "disable-model-invocation" not in fields, (
            path,
            "unexpected client invocation extension",
        )
PY

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

python3 - <<'PY'
from pathlib import Path

workflow = Path(".github/workflows/agent-bootstrap.yml")
if workflow.exists():
    structure = [
        line.rstrip()
        for line in workflow.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    expected_structure = [
        "name: agent-bootstrap",
        "on:",
        "  push:",
        "    branches: [main]",
        "  pull_request:",
        "jobs:",
        "  seed-checks:",
        "    runs-on: ubuntu-latest",
        "    steps:",
        "      - uses: actions/checkout@v4",
        "      - run: bash scripts/check-bootstrap.sh",
    ]
    assert structure == expected_structure, (
        "hosted bootstrap wrapper must remain the exact optional thin wrapper",
        structure,
    )
PY

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
