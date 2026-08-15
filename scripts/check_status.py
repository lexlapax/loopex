#!/usr/bin/env python3
"""Validate the small, marked set of human-facing project-status facts."""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from collections.abc import Callable, Mapping
from datetime import date
from pathlib import Path


CURRENT_FIELDS = (
    "Integrated phase",
    "Last integrated checkpoint",
    "Blockers",
    "Authorized work",
    "Next maintainer decision",
    "Next transition",
    "Validation",
)
STATES = {"Blocked", "Open", "Accepted", "In progress", "In review", "Closed"}
ACTIVE_STATES = {"Open", "Accepted", "In progress", "In review"}
NAME = re.compile(r"(?:M[0-9]+|v?[0-9]+(?:\.[0-9]+)+|[a-z0-9]+(?:-[a-z0-9]+)*)\Z")
MAX_NAME_BYTES = 64
RESERVED = {"planning", "seed", "readme", "con", "prn", "aux", "nul"}
RESERVED.update(f"{prefix}{number}" for prefix in ("com", "lpt") for number in range(1, 10))
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
HTML_TAG = re.compile(r"</?[A-Za-z][^>]*>")
ATX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+|$)")
SETEXT = re.compile(r"^ {0,3}(?:=+|-+)[ \t]*$")
AUTHORITY = re.compile(r"(?:Maintainer|Delegate: [A-Za-z0-9][A-Za-z0-9 ._@-]*)\Z")
EVIDENCE = re.compile(r"\[disposition\]\([^) \t]+\)\Z")
BOUND = re.compile(r"candidate `([0-9a-f]{40})`; gate `sha256:([0-9a-f]{64})`\Z")

MARKERS = {
    "readme": ("<!-- loopex:readme-status:start -->", "<!-- loopex:readme-status:end -->"),
    "current": ("<!-- loopex:current-status:start -->", "<!-- loopex:current-status:end -->"),
    "register": ("<!-- loopex:milestone-register:start -->", "<!-- loopex:milestone-register:end -->"),
    "rejoin_source": ("<!-- loopex:rejoin-source:start -->", "<!-- loopex:rejoin-source:end -->"),
    "rejoin_copy": ("<!-- loopex:rejoin-copy:start -->", "<!-- loopex:rejoin-copy:end -->"),
}


class Invalid(Exception):
    pass


def _lines(text: str, path: str) -> list[str]:
    if any(separator in text for separator in "\v\f\x1c\x1d\x1e\x85\u2028\u2029"):
        raise Invalid(f"{path}: unsupported non-Markdown line separator")
    return text.replace("\r\n", "\n").replace("\r", "\n").split("\n")


def _visible_line_numbers(text: str, path: str) -> set[int]:
    """Return lines outside fenced/code-span/comment hiding constructs."""
    visible: set[int] = set()
    fence: tuple[str, int] | None = None
    comment = False
    ticks: int | None = None
    known_markers = {marker for pair in MARKERS.values() for marker in pair}

    for number, line in enumerate(_lines(text, path)):
        if fence:
            match = re.match(rf"^ {{0,3}}{re.escape(fence[0])}{{{fence[1]},}}[ \t]*$", line)
            if match:
                fence = None
            continue
        if comment:
            if "-->" in line:
                comment = False
            continue

        if ticks is None:
            match = FENCE.match(line)
            if match:
                fence = (match.group(1)[0], len(match.group(1)))
                continue
            if line in known_markers:
                visible.add(number)
                continue

        started_in_code = ticks is not None
        exposed: list[str] = []
        index = 0
        while index < len(line):
            if ticks is not None:
                if line[index] == "`":
                    end = index
                    while end < len(line) and line[end] == "`":
                        end += 1
                    if end - index == ticks:
                        ticks = None
                    index = end
                else:
                    index += 1
                continue
            if line.startswith("<!--", index):
                end = line.find("-->", index + 4)
                if end < 0:
                    comment = True
                    break
                index = end + 3
                continue
            if line[index] == "`":
                end = index
                while end < len(line) and line[end] == "`":
                    end += 1
                ticks = end - index
                index = end
                continue
            exposed.append(line[index])
            index += 1

        if not started_in_code:
            visible.add(number)
            exposed_text = "".join(exposed)
            if HTML_TAG.search(exposed_text) or exposed_text.lstrip().startswith("<"):
                raise Invalid(f"{path}: raw HTML is not allowed in a governed status document")

    if fence or comment or ticks is not None:
        raise Invalid(f"{path}: unclosed Markdown or HTML hiding construct")
    return visible


def _block(text: str, path: str, key: str, heading: str | None = None) -> list[str]:
    start, end = MARKERS[key]
    if text.count(start) != 1 or text.count(end) != 1:
        raise Invalid(f"{path}: {key} markers must each occur exactly once")
    lines = _lines(text, path)
    visible = _visible_line_numbers(text, path)
    starts = [i for i, line in enumerate(lines) if line == start and i in visible]
    ends = [i for i, line in enumerate(lines) if line == end and i in visible]
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise Invalid(f"{path}: {key} markers must be ordered and top-level")
    if heading:
        headings = [i for i, line in enumerate(lines) if line == heading and i in visible]
        if len(headings) != 1 or not headings[0] < starts[0]:
            raise Invalid(f"{path}: {key} block must follow unique {heading!r}")
        for index in range(headings[0] + 1, starts[0]):
            if index not in visible:
                continue
            match = ATX.match(lines[index])
            setext = (
                SETEXT.fullmatch(lines[index])
                and index - 1 in visible
                and bool(lines[index - 1].strip())
            )
            if (match and len(match.group(1)) <= 2) or setext:
                raise Invalid(f"{path}: {key} block is outside {heading!r}")
    return lines[starts[0] + 1 : ends[0]]


def _table(lines: list[str], header: tuple[str, ...], path: str) -> list[list[str]]:
    expected_header = "| " + " | ".join(header) + " |"
    expected_rule = "| " + " | ".join("---" for _ in header) + " |"
    if len(lines) < 2 or lines[:2] != [expected_header, expected_rule]:
        raise Invalid(f"{path}: expected exact {' | '.join(header)} table")
    rows: list[list[str]] = []
    for line in lines[2:]:
        if not line.startswith("| ") or not line.endswith(" |"):
            raise Invalid(f"{path}: malformed table row {line!r}")
        cells = line[2:-2].split(" | ")
        if len(cells) != len(header) or any(not cell.strip() or cell != cell.strip() for cell in cells):
            raise Invalid(f"{path}: malformed table row {line!r}")
        rows.append(cells)
    return rows


def _milestone(raw: str, path: str) -> str:
    if len(raw) < 3 or raw[0] != "`" or raw[-1] != "`":
        raise Invalid(f"{path}: milestone names must be code-formatted")
    name = raw[1:-1]
    folded = name.casefold()
    if (
        not NAME.fullmatch(name)
        or len(name.encode("ascii")) > MAX_NAME_BYTES
        or folded in RESERVED
        or folded.endswith("-gate")
    ):
        raise Invalid(f"{path}: invalid or reserved milestone name {name!r}")
    return name


def _summary(phase: str, rows: list[tuple[str, str, str, str]]) -> str:
    active = [(name, state) for name, state, _, _ in rows if state in ACTIVE_STATES]
    blocked = [name for name, state, _, _ in rows if state == "Blocked"]
    if len(active) > 1 or len(blocked) > 1:
        raise Invalid("docs/plans/README.md: at most one active and one Blocked milestone are allowed")
    if active:
        status = f"active milestone `{active[0][0]}` is {active[0][1].lower()}"
    else:
        status = "no milestone is active"
    if blocked:
        next_status = f"next candidate `{blocked[0]}` is blocked"
    else:
        next_status = "no next candidate is recorded"
    return f"**Revision status:** {phase}; {status}; {next_status}."


def _canonical_digest(text: str) -> str:
    canonical = text.replace("\r\n", "\n").replace("\r", "\n")
    return hashlib.sha256(canonical.encode()).hexdigest()


def _governance_table(text: str, path: str) -> list[list[str]]:
    visible = _visible_line_numbers(text, path)
    lines = _lines(text, path)
    headings = [i for i, line in enumerate(lines) if line == "## Governance Records" and i in visible]
    if len(headings) != 1:
        raise Invalid(f"{path}: expected one top-level Governance Records section")
    end = len(lines)
    for index in sorted(visible):
        if index <= headings[0]:
            continue
        match = ATX.match(lines[index])
        if match and len(match.group(1)) <= 2:
            end = index
            break
        if (
            SETEXT.fullmatch(lines[index])
            and index - 1 > headings[0]
            and index - 1 in visible
            and bool(lines[index - 1].strip())
        ):
            end = index - 1
            break
    body = lines[headings[0] + 1 : end]
    while body and not body[0]:
        body.pop(0)
    while body and not body[-1]:
        body.pop()
    rows = _table(body, ("Decision", "Authority", "Authority evidence", "Bound bytes"), path)
    if len(rows) != 2 or [row[0] for row in rows] != ["Acceptance", "Closure"]:
        raise Invalid(f"{path}: governance rows must be Acceptance then Closure")
    return rows


def _governance(
    text: str,
    gate_text: str,
    name: str,
    state: str,
    resolve_file: Callable[[str, str], str | None] | None,
) -> None:
    path = f"docs/plans/{name}.md"
    rows = _governance_table(text, path)
    bound = [BOUND.fullmatch(row[3]) for row in rows]
    complete = [
        bool(AUTHORITY.fullmatch(row[1]) and EVIDENCE.fullmatch(row[2]) and digest)
        for row, digest in zip(rows, bound)
    ]
    empty = [row[1:] == ["—", "—", "—"] for row in rows]
    if any(not (is_empty or is_complete) for is_empty, is_complete in zip(empty, complete)):
        raise Invalid(f"{path}: each governance row must be exactly empty or structurally complete")
    expected = [False, False] if state == "Open" else [True, True] if state == "Closed" else [True, False]
    if complete != expected:
        raise Invalid(f"{path}: governance records do not match {state} lifecycle state")
    gate_path = f"docs/plans/{name}-gate.md"
    gate_digest = _canonical_digest(gate_text)
    for digest in (item for item in bound if item):
        historical = resolve_file(digest.group(1), gate_path) if resolve_file else None
        if historical is None:
            raise Invalid(f"{path}: governance candidate SHA or historical gate is unavailable")
        if digest.group(2) != gate_digest or digest.group(2) != _canonical_digest(historical):
            raise Invalid(f"{path}: governance digest does not match current and historical canonical gate text")

    visible = _visible_line_numbers(text, path)
    lines = _lines(text, path)
    if any(lines[i] == "## Milestone Status" for i in visible):
        raise Invalid(f"{path}: lifecycle state belongs only in the canonical register")


def validate(
    documents: Mapping[str, str],
    resolve_file: Callable[[str, str], str | None] | None = None,
) -> list[str]:
    errors: list[str] = []
    try:
        required = ("README.md", "docs/plans/README.md", "docs/vision.md", "docs/roadmap.md")
        for path in required:
            if path not in documents:
                raise Invalid(f"{path}: missing")

        plans_text = documents["docs/plans/README.md"]
        current = _block(plans_text, "docs/plans/README.md", "current")
        if len(current) != 13 or current[0] != "## Current Status" or current[1] or current[3]:
            raise Invalid("docs/plans/README.md: Current Status block has the wrong shape")
        current_rows = _table(current[4:], ("Field", "Value"), "docs/plans/README.md Current Status")
        if tuple(row[0] for row in current_rows) != CURRENT_FIELDS:
            raise Invalid("docs/plans/README.md: Current Status fields are missing, duplicated, or reordered")
        values = {key: value for key, value in current_rows}
        if values["Validation"] != "`bash scripts/check-bootstrap.sh`":
            raise Invalid("docs/plans/README.md: Validation must name the exact bootstrap aggregate")

        register = _block(plans_text, "docs/plans/README.md", "register")
        if len(register) < 4 or register[0] != "## Milestone Register" or register[1]:
            raise Invalid("docs/plans/README.md: Milestone Register block has the wrong shape")
        parsed_rows: list[tuple[str, str, str, str]] = []
        names: set[str] = set()
        for raw_name, state, plan_link, gate_link in _table(
            register[2:], ("Milestone", "State", "Plan", "Gate"), "docs/plans/README.md Milestone Register"
        ):
            name = _milestone(raw_name, "docs/plans/README.md Milestone Register")
            if name.casefold() in names:
                raise Invalid(f"docs/plans/README.md: duplicate or case-colliding milestone {name!r}")
            names.add(name.casefold())
            if state not in STATES:
                raise Invalid(f"docs/plans/README.md: unknown milestone state {state!r}")
            expected = ("—", "—") if state == "Blocked" else (f"[plan]({name}.md)", f"[gate]({name}-gate.md)")
            if (plan_link, gate_link) != expected:
                raise Invalid(f"docs/plans/README.md: {name} has incorrect plan/gate links for {state}")
            parsed_rows.append((name, state, plan_link, gate_link))

        closed = [name for name, state, _, _ in parsed_rows if state == "Closed"]
        checkpoint = values["Last integrated checkpoint"]
        if closed:
            match = re.fullmatch(r"`([^`]+)` — [0-9]{4}-[0-9]{2}-[0-9]{2}", checkpoint)
            try:
                checkpoint_date = date.fromisoformat(checkpoint.rsplit(" ", 1)[-1])
            except ValueError:
                checkpoint_date = None
            if not match or not checkpoint_date or match.group(1) != closed[-1]:
                raise Invalid("docs/plans/README.md: Last integrated checkpoint must name the final Closed row")
        elif checkpoint != "Seed bootstrap — 2026-08-15":
            raise Invalid("docs/plans/README.md: seed checkpoint must remain until the first milestone closes")

        expected_summary = _summary(values["Integrated phase"], parsed_rows)
        if current[2] != expected_summary:
            raise Invalid("docs/plans/README.md: Revision status is not derived from phase and register")
        if not documents["README.md"].startswith("# Loopex\n"):
            raise Invalid("README.md: # Loopex must be the first line")
        readme = _block(documents["README.md"], "README.md", "readme", "# Loopex")
        expected_readme = [
            "## Where Things Stand",
            "",
            expected_summary,
            "",
            "[Canonical milestone status and plan records](docs/plans/)",
        ]
        if readme != expected_readme:
            raise Invalid("README.md: status block must be the exact derived summary and visible plans link")

        plan_keys: set[str] = set()
        gate_keys: set[str] = set()
        for path in documents:
            if not path.startswith("docs/plans/") or path == "docs/plans/README.md" or not path.endswith(".md"):
                continue
            relative = path.removeprefix("docs/plans/")
            if "/" in relative:
                raise Invalid(f"{path}: nested plan Markdown is not allowed")
            if relative.endswith("-gate.md"):
                gate_keys.add(relative.removesuffix("-gate.md"))
            else:
                plan_keys.add(relative.removesuffix(".md"))
        represented = {name for name, state, _, _ in parsed_rows if state != "Blocked"}
        if plan_keys != gate_keys or plan_keys != represented:
            raise Invalid("docs/plans: plan files, gate files, and non-Blocked register rows must match exactly")
        state_by_name = {name: state for name, state, _, _ in parsed_rows}
        for name in plan_keys:
            _milestone(f"`{name}`", f"docs/plans/{name}.md")
            _governance(
                documents[f"docs/plans/{name}.md"],
                documents[f"docs/plans/{name}-gate.md"],
                name,
                state_by_name[name],
                resolve_file,
            )

        source = _block(
            documents["docs/vision.md"], "docs/vision.md", "rejoin_source", "## 22. Ownership and serial barriers"
        )
        copy = _block(
            documents["docs/roadmap.md"], "docs/roadmap.md", "rejoin_copy", "## The Enduring Rejoin Order"
        )
        if source != copy:
            raise Invalid("docs/roadmap.md: rejoin block differs from vision §22")
        if len(source) < 4 or source[0] != "```text" or source[-1] != "```":
            raise Invalid("docs/vision.md: rejoin payload must be one complete text fence")
        steps = source[1:-1]
        if len(steps) < 2 or not steps[0].strip() or steps[0].startswith("-> "):
            raise Invalid("docs/vision.md: rejoin payload needs an initial step and at least one transition")
        if any(not step.startswith("-> ") or not step[3:].strip() for step in steps[1:]):
            raise Invalid("docs/vision.md: every later rejoin step must start with '-> '")
    except Invalid as error:
        errors.append(str(error))
    return errors


def _load(root: Path) -> dict[str, str]:
    paths = [root / name for name in ("README.md", "docs/plans/README.md", "docs/vision.md", "docs/roadmap.md")]
    plans = root / "docs/plans"
    if plans.exists():
        paths.extend(path for path in plans.rglob("*.md") if path != plans / "README.md")
    return {path.relative_to(root).as_posix(): path.read_text(encoding="utf-8") for path in paths if path.exists()}


def _git_resolver(root: Path) -> Callable[[str, str], str | None]:
    def resolve(sha: str, path: str) -> str | None:
        object_type = subprocess.run(
            ["git", "--no-replace-objects", "cat-file", "-t", sha],
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if object_type.returncode or object_type.stdout != b"commit\n":
            return None
        result = subprocess.run(
            ["git", "--no-replace-objects", "show", f"{sha}:{path}"],
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode:
            return None
        try:
            return result.stdout.decode("utf-8")
        except UnicodeDecodeError:
            return None

    return resolve


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    root = parser.parse_args().root.resolve()
    errors = validate(_load(root), _git_resolver(root))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("status check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
