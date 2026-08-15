#!/usr/bin/env python3
"""Read-only structural assertions for the seed agent bootstrap."""

import sys

if not __debug__:
    raise SystemExit("Python optimization disables bootstrap assertions")
if sys.version_info < (3, 11):
    raise SystemExit("Python 3.11+ is required for tomllib")

import json
from pathlib import Path
import tomllib


ROOT = Path.cwd()

for shell_check in (
    ROOT / "scripts/check-bootstrap.sh",
    ROOT / "scripts/check-agent-bootstrap.sh",
    ROOT / "scripts/check-gitignore.sh",
):
    assert "<<" not in shell_check.read_text(), (
        shell_check,
        "bootstrap shell checks must not use temporary-file here-documents",
    )


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
    return fields, "\n".join(lines[end + 1 :])


def assert_ordered_pointers(path, body):
    contract = "AGENTS.md"
    context = "docs/developer/agent-context-map.md"
    assert contract in body and context in body, (path, "missing canonical pointer")
    assert body.index(contract) < body.index(context), (path, "pointer order")


codex_root = ROOT / ".codex"
config_text = (codex_root / "config.toml").read_text()
config = tomllib.loads(config_text)
assert config.get("features", {}).get("multi_agent_v2") is True, (
    "multi_agent_v2 must expose project custom agents"
)
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
    profile_path = codex_root / entry["config_file"]
    profile = tomllib.loads(profile_path.read_text())
    assert profile["name"] == key, (key, profile_path, profile["name"])
    assert profile["description"] == entry["description"], (key, "description drift")
    instructions = profile.get("developer_instructions", "").strip()
    assert instructions, (key, "missing instructions")
    assert " ".join(instructions.split()).startswith(prologue), (
        key,
        "canonical context prologue missing or out of order",
    )
    assert profile.get("sandbox_mode") == expected_sandboxes[key], (
        key,
        "sandbox drift",
        profile.get("sandbox_mode"),
    )
    assert "model" not in profile, (key, "project-local model pin")

settings = json.loads((ROOT / ".claude/settings.json").read_text())
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

claude_agents = set((ROOT / ".claude/agents").glob("*.md"))
expected_claude_agents = {
    ROOT / ".claude/agents/conformance-author.md",
    ROOT / ".claude/agents/reviewer.md",
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

for path in sorted((ROOT / ".agents/skills").glob("*/SKILL.md")):
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

workflow = ROOT / ".github/workflows/agent-bootstrap.yml"
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
        "        with:",
        # Full history only; the commit-message check needs its policy baseline.
        "          fetch-depth: 0",
        "      - run: bash scripts/check-bootstrap.sh",
    ]
    assert structure == expected_structure, (
        "hosted bootstrap wrapper must remain the exact optional thin wrapper",
        structure,
    )
