#!/usr/bin/env python3
"""Run the delegated M6 ask without retaining failed child output."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path


EXIT_CLASS = {
    1: "diagnostic_or_cleanup",
    2: "failed",
    3: "bound_reached",
    4: "outcome_unknown",
    5: "cancelled",
    6: "no_ending",
}
ASK_KEYS = {
    "schema", "session_id", "run_id", "profile", "outcome", "text",
    "text_truncated", "tools", "tools_truncated", "shadowed_skills",
    "cleanup", "details",
}
TOOL_OUTCOMES = {
    "completed", "failed", "denied", "cancelled",
    "cancelled_workspace_lease_lost", "outcome_unknown",
}
UINT64_MAX = 18_446_744_073_709_551_615


def report(status):
    print(
        f"m6-demonstration: delegated command exit={status} "
        f"exit_class={EXIT_CLASS.get(status, 'unrecognized')}",
        file=sys.stderr,
    )
    return status if 1 <= status <= 255 else 1


def unique_pairs(pairs):
    value = {}
    for key, member in pairs:
        if key in value:
            raise ValueError("duplicate JSON member")
        value[key] = member
    return value


def reject_constant(_value):
    raise ValueError("non-JSON constant")


def bounded_text(value, limit, allow_empty=False):
    if not isinstance(value, str):
        return False
    try:
        size = len(value.encode("utf-8"))
    except UnicodeError:
        return False
    return size <= limit and (allow_empty or size > 0)


def valid_tool(tool):
    return (
        isinstance(tool, dict)
        and set(tool) == {"tool_id", "outcome"}
        and (tool["tool_id"] is None or bounded_text(tool["tool_id"], 128))
        and isinstance(tool["outcome"], str)
        and tool["outcome"] in TOOL_OUTCOMES
    )


def valid_shadowed_skill(skill):
    return (
        bounded_text(skill, 1_024)
        and len(skill.encode("utf-8")) > 5
        and skill.startswith("user:")
    )


def valid_success(stdout):
    if stdout.count(b"\n") != 1 or not stdout.endswith(b"\n"):
        return False
    line = stdout[:-1]
    if not line.startswith(b"{") or not line.endswith(b"}"):
        return False
    try:
        value = json.loads(
            line.decode("utf-8"),
            object_pairs_hook=unique_pairs,
            parse_constant=reject_constant,
        )
    except (UnicodeError, ValueError, RecursionError):
        return False
    if not isinstance(value, dict) or set(value) != ASK_KEYS:
        return False
    details = value["details"]
    cleanup = value["cleanup"]
    grace = details.get("cleanup_grace_ms") if isinstance(details, dict) else None
    tools = value["tools"]
    shadowed = value["shadowed_skills"]
    return (
        value["schema"] == "loopex.ask/1"
        and value["profile"] == "ephemeral"
        and value["outcome"] == "completed"
        and isinstance(cleanup, dict)
        and set(cleanup) == {"proved"}
        and cleanup["proved"] is True
        and bounded_text(value["session_id"], 1_024)
        and bounded_text(value["run_id"], 1_024)
        and bounded_text(value["text"], 65_536, allow_empty=True)
        and type(value["text_truncated"]) is bool
        and (value["text"] != "" or not value["text_truncated"])
        and isinstance(tools, list)
        and len(tools) <= 256
        and all(valid_tool(tool) for tool in tools)
        and type(value["tools_truncated"]) is bool
        and (tools or not value["tools_truncated"])
        and isinstance(shadowed, list)
        and len(shadowed) <= 4
        and all(valid_shadowed_skill(skill) for skill in shadowed)
        and shadowed == sorted(set(shadowed))
        and isinstance(details, dict)
        and set(details) == {"cleanup_grace_ms"}
        and isinstance(grace, str)
        and re.fullmatch(r"[1-9][0-9]{0,19}", grace) is not None
        and int(grace) <= UINT64_MAX
    )


def main():
    try:
        workspace = os.environ["M6_DEMO_WORKSPACE"]
        result = subprocess.run(
            [
                os.environ["M6_DEMO_COMMAND"], "-p", os.environ["M6_DEMO_PROMPT"],
                "--policy", "allow-all", "--model", os.environ["M6_DEMO_LOCAL_MODEL"],
                "--tools", "coding", "--cwd", workspace, "--skill-dir",
                os.environ["M6_DEMO_SKILL"], "--deadline-ms", "120000",
                "--max-steps", "8", "--output", "json",
            ],
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            return report(result.returncode)
        if result.stderr or not valid_success(result.stdout):
            return report(0)
        (Path(workspace) / "delegated.json").write_bytes(result.stdout)
        return 0
    except BaseException:
        return report(1)


if __name__ == "__main__":
    sys.exit(main())
