#!/usr/bin/env python3
"""Validate the small, marked set of human-facing project-status facts."""

from __future__ import annotations

import argparse
import hashlib
import os
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
SEED_BLOCKED_VALUES = {
    "Integrated phase": "Pre-implementation planning",
    "Last integrated checkpoint": "Seed bootstrap — 2026-08-15",
    "Blockers": (
        "[ADR 0001](../adr/0001-repository-and-application-layout.md) and "
        "[ADR 0002](../adr/0002-bootstrap-runtime-floor.md) must be accepted before "
        "M0 opens; a replacement requires a governed guard change"
    ),
    "Authorized work": (
        "Explicitly authorized planning, ADR, bootstrap, and review work only; "
        "no product implementation"
    ),
    "Next maintainer decision": "Disposition ADR 0001 and ADR 0002",
    "Next transition": (
        "After the prerequisites are accepted, the maintainer explicitly opens "
        "`M0` gate-first"
    ),
    "Validation": "`bash scripts/check-bootstrap.sh`",
}
ADR_PATHS = (
    "docs/adr/0001-repository-and-application-layout.md",
    "docs/adr/0002-bootstrap-runtime-floor.md",
)
ADR_NAMES = {
    ADR_PATHS[0]: "ADR 0001",
    ADR_PATHS[1]: "ADR 0002",
}
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
ADR_BOUND = re.compile(
    r"candidate `([0-9a-f]{40})`; document `sha256:([0-9a-f]{64})`\Z"
)

MARKERS = {
    "readme": ("<!-- loopex:readme-status:start -->", "<!-- loopex:readme-status:end -->"),
    "current": ("<!-- loopex:current-status:start -->", "<!-- loopex:current-status:end -->"),
    "register": ("<!-- loopex:milestone-register:start -->", "<!-- loopex:milestone-register:end -->"),
    "plan_envelope": ("<!-- loopex:plan-envelope:start -->", "<!-- loopex:plan-envelope:end -->"),
    "rejoin_source": ("<!-- loopex:rejoin-source:start -->", "<!-- loopex:rejoin-source:end -->"),
    "rejoin_copy": ("<!-- loopex:rejoin-copy:start -->", "<!-- loopex:rejoin-copy:end -->"),
}

PLAN_ENVELOPE_SECTIONS = (
    "### Purpose",
    "### Outcomes",
    "### Scope",
    "### Non-Goals",
    "### Prerequisites and Acceptance Points",
    "### Ownership, Decision Owners, and Rejoin Barriers",
    "### Evidence Obligations and Mapping",
    "### Compatibility",
    "### Migration and Rollback",
    "### Packaging",
    "### Proportional Minimalism Budget",
)


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


def _blocked_m0_values(statuses: Mapping[str, str]) -> dict[str, str]:
    values = dict(SEED_BLOCKED_VALUES)
    unresolved = [path for path in ADR_PATHS if statuses[path] != "Accepted"]
    if len(unresolved) == 1:
        path = unresolved[0]
        name = ADR_NAMES[path]
        filename = path.removeprefix("docs/adr/")
        values["Blockers"] = (
            f"[{name}](../adr/{filename}) must be accepted before M0 opens; "
            "a replacement requires a governed guard change"
        )
        values["Next maintainer decision"] = f"Disposition {name}"
    elif not unresolved:
        values["Blockers"] = "M0 has not been explicitly opened gate-first"
        values["Next maintainer decision"] = "Explicitly open or defer M0"
        values["Next transition"] = (
            "Create the branch-only M0 plan and red gate, install lifecycle-specific "
            "status checks, and move M0 to Open"
        )
    return values


def _gate_digest(text: str, path: str) -> str:
    if any(separator in text for separator in "\r\v\f\x1c\x1d\x1e\x85\u2028\u2029"):
        raise Invalid(f"{path}: gate text must use canonical UTF-8/LF bytes")
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _section_body(text: str, path: str, heading: str) -> tuple[list[str], int]:
    visible = _visible_line_numbers(text, path)
    lines = _lines(text, path)
    headings = [i for i, line in enumerate(lines) if line == heading and i in visible]
    if len(headings) != 1:
        raise Invalid(f"{path}: expected one top-level {heading.removeprefix('## ')} section")
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
    body_start = headings[0] + 1
    while body_start < end and not lines[body_start]:
        body_start += 1
    while body and not body[-1]:
        body.pop()
    return body, body_start


def _records_table(
    text: str, path: str, heading: str, decisions: tuple[str, ...]
) -> tuple[list[list[str]], list[int]]:
    body, body_start = _section_body(text, path, heading)
    rows = _table(body, ("Decision", "Authority", "Authority evidence", "Bound bytes"), path)
    if len(rows) != len(decisions) or [row[0] for row in rows] != list(decisions):
        expected = " then ".join(decisions)
        raise Invalid(f"{path}: governance rows must be {expected}")
    row_indices = list(range(body_start + 2, body_start + 2 + len(rows)))
    return rows, row_indices


def _governance_table(text: str, path: str) -> list[list[str]]:
    rows, _ = _records_table(
        text, path, "## Governance Records", ("Acceptance", "Closure")
    )
    return rows


def _governance_records(
    text: str, path: str
) -> tuple[list[list[str]], list[re.Match[str] | None], list[bool]]:
    rows = _governance_table(text, path)
    bound = [BOUND.fullmatch(row[3]) for row in rows]
    complete = [
        bool(AUTHORITY.fullmatch(row[1]) and EVIDENCE.fullmatch(row[2]) and digest)
        for row, digest in zip(rows, bound)
    ]
    empty = [row[1:] == ["—", "—", "—"] for row in rows]
    if any(not (is_empty or is_complete) for is_empty, is_complete in zip(empty, complete)):
        raise Invalid(f"{path}: each governance row must be exactly empty or structurally complete")
    return rows, bound, complete


def _adr_record(
    text: str, path: str, *, legacy_ok: bool = False
) -> tuple[str, list[str], bool, int, int] | None:
    if "\r" in text:
        raise Invalid(f"{path}: ADR text must use canonical UTF-8/LF bytes")
    lines = _lines(text, path)
    visible = _visible_line_numbers(text, path)
    statuses = [
        index
        for index, line in enumerate(lines)
        if line.startswith("- **Status:** ") and index in visible
    ]
    heading_present = any(
        lines[index] == "## Governance Record" for index in visible
    )
    if legacy_ok and not heading_present:
        return None
    if len(statuses) != 1:
        raise Invalid(f"{path}: expected one visible ADR Status field")
    status = lines[statuses[0]].removeprefix("- **Status:** ")
    if status not in {"Proposed", "Accepted"}:
        raise Invalid(f"{path}: bootstrap ADR status must be Proposed or Accepted")
    rows, row_indices = _records_table(
        text, path, "## Governance Record", ("Acceptance",)
    )
    row = rows[0]
    complete = bool(
        AUTHORITY.fullmatch(row[1])
        and EVIDENCE.fullmatch(row[2])
        and ADR_BOUND.fullmatch(row[3])
    )
    empty = row[1:] == ["—", "—", "—"]
    if not (empty or complete):
        raise Invalid(f"{path}: ADR governance row must be exactly empty or structurally complete")
    if (status == "Proposed") != empty or (status == "Accepted") != complete:
        raise Invalid(f"{path}: ADR Status and governance record do not match")
    return status, row, complete, statuses[0], row_indices[0]


def _validate_adr(
    text: str,
    path: str,
    resolve_file: Callable[[str, str], str | None] | None,
) -> str:
    record = _adr_record(text, path)
    if record is None:
        raise Invalid(f"{path}: ADR governance record is unavailable")
    status, row, complete, status_index, row_index = record
    if not complete:
        return status

    bound = ADR_BOUND.fullmatch(row[3])
    if bound is None:
        raise Invalid(f"{path}: accepted ADR bound bytes are malformed")
    candidate = resolve_file(bound.group(1), path) if resolve_file else None
    if candidate is None:
        raise Invalid(f"{path}: accepted ADR candidate is unavailable")
    candidate_record = _adr_record(
        candidate, f"{path} at historical candidate {bound.group(1)}"
    )
    if candidate_record is None:
        raise Invalid(f"{path}: historical candidate ADR governance record is unavailable")
    if candidate_record[0] != "Proposed" or candidate_record[2]:
        raise Invalid(f"{path}: historical candidate must be the Proposed ADR with an empty record")
    digest = hashlib.sha256(candidate.encode("utf-8")).hexdigest()
    if digest != bound.group(2):
        raise Invalid(f"{path}: ADR document digest does not match its historical candidate")

    reconstructed = _lines(text, path)
    reconstructed[status_index] = "- **Status:** Proposed"
    reconstructed[row_index] = "| Acceptance | — | — | — |"
    if "\n".join(reconstructed) != candidate:
        raise Invalid(
            f"{path}: accepted ADR differs from its historical candidate outside the disposition record"
        )
    return status


def _plan_envelope(text: str, path: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    if "\r" in text:
        raise Invalid(f"{path}: plan text must use canonical UTF-8/LF bytes")
    body = _block(text, path, "plan_envelope")
    lines = _lines(text, path)
    first_content = next((line for line in lines if line.strip()), None)
    if first_content != MARKERS["plan_envelope"][0]:
        raise Invalid(f"{path}: plan document must start with the plan-envelope marker")

    visible_document = _visible_line_numbers(text, path)
    document_headings: list[str] = []
    for index, line in enumerate(lines):
        if index not in visible_document:
            continue
        match = ATX.match(line)
        setext = (
            SETEXT.fullmatch(line)
            and index - 1 in visible_document
            and bool(lines[index - 1].strip())
        )
        if setext:
            raise Invalid(f"{path}: setext headings are not allowed in a plan document")
        if match:
            document_headings.append(line)
    expected_document_headings = (
        "## Normative Envelope",
        *PLAN_ENVELOPE_SECTIONS,
        "## Workstreams",
        "## Progress and Evidence",
        "## Governance Records",
    )
    if tuple(document_headings) != expected_document_headings:
        raise Invalid(
            f"{path}: plan document headings must be exactly the governed plan sequence"
        )

    envelope_end = lines.index(MARKERS["plan_envelope"][1])
    following = lines[envelope_end + 1 :]
    if following and following[0] == "":
        following = following[1:]
    if not following or following[0] != "## Workstreams":
        raise Invalid(
            f"{path}: plan-envelope end must be followed directly by Workstreams"
        )
    body_text = "\n".join(body)
    visible = _visible_line_numbers(body_text, path)
    if not body or body[0] != "## Normative Envelope":
        raise Invalid(f"{path}: normative plan envelope must start with its exact heading")
    sections: list[tuple[int, str]] = []
    for index, line in enumerate(body):
        if index not in visible:
            continue
        match = ATX.match(line)
        setext = (
            SETEXT.fullmatch(line)
            and index - 1 in visible
            and bool(body[index - 1].strip())
        )
        if setext:
            raise Invalid(f"{path}: setext headings are not allowed in the normative envelope")
        if match:
            sections.append((index, line))
    expected = ("## Normative Envelope", *PLAN_ENVELOPE_SECTIONS)
    if tuple(line for _, line in sections) != expected:
        raise Invalid(f"{path}: normative plan-envelope headings are missing, duplicated, or reordered")
    for position, (start, heading) in enumerate(sections[1:], 1):
        end = sections[position + 1][0] if position + 1 < len(sections) else len(body)
        content = [
            body[index]
            for index in range(start + 1, end)
            if index in visible and body[index].strip()
        ]
        if not content:
            raise Invalid(f"{path}: {heading} must contain a concrete commitment")

    outcomes_start = sections[2][0] + 1
    outcomes_end = sections[3][0]
    outcomes = body[outcomes_start:outcomes_end]
    header = "| # | Outcome | Evidence class | Gate selector |"
    if outcomes.count(header) != 1:
        raise Invalid(f"{path}: Outcomes must contain one exact normative outcomes table")
    table_start = outcomes.index(header)
    table_lines = outcomes[table_start:]
    while table_lines and not table_lines[-1]:
        table_lines.pop()
    rows = _table(
        table_lines,
        ("#", "Outcome", "Evidence class", "Gate selector"),
        f"{path} Outcomes",
    )
    if not rows or [row[0] for row in rows] != [str(index) for index in range(1, len(rows) + 1)]:
        raise Invalid(f"{path}: Outcomes must contain consecutively numbered commitments")
    return tuple(body), tuple(row[0] for row in rows)


def _progress(
    text: str, path: str, outcome_ids: tuple[str, ...], lifecycle_state: str
) -> None:
    body, _ = _section_body(text, path, "## Progress and Evidence")
    rows = _table(body, ("#", "State", "Evidence"), f"{path} Progress and Evidence")
    if tuple(row[0] for row in rows) != outcome_ids:
        raise Invalid(
            f"{path}: Progress and Evidence must contain exactly one row for every Outcome ID"
        )
    allowed = {"Open", "Proved", "Accepted limitation", "Accepted deferral"}
    if any(row[1] not in allowed for row in rows):
        raise Invalid(f"{path}: Progress and Evidence contains an unknown State")
    if lifecycle_state == "Closed" and any(row[1] == "Open" for row in rows):
        raise Invalid(f"{path}: Closed progress permits no Open outcomes")
    if any(
        row[1] in {"Accepted limitation", "Accepted deferral"}
        and not EVIDENCE.fullmatch(row[2])
        for row in rows
    ):
        raise Invalid(
            f"{path}: an accepted limitation or deferral requires disposition evidence"
        )


def _governance(
    text: str,
    gate_text: str,
    name: str,
    state: str,
    resolve_file: Callable[[str, str], str | None] | None,
) -> None:
    path = f"docs/plans/{name}.md"
    envelope, outcome_ids = _plan_envelope(text, path)
    _progress(text, path, outcome_ids, state)
    rows, bound, complete = _governance_records(text, path)
    expected = [False, False] if state == "Open" else [True, True] if state == "Closed" else [True, False]
    if complete != expected:
        raise Invalid(f"{path}: governance records do not match {state} lifecycle state")
    gate_path = f"docs/plans/{name}-gate.md"
    gate_digest = _gate_digest(gate_text, gate_path)
    for digest in (item for item in bound if item):
        historical = resolve_file(digest.group(1), gate_path) if resolve_file else None
        if historical is None:
            raise Invalid(f"{path}: governance candidate SHA or historical gate is unavailable")
        historical_digest = _gate_digest(historical, f"{gate_path} at {digest.group(1)}")
        if digest.group(2) != gate_digest or digest.group(2) != historical_digest:
            raise Invalid(f"{path}: governance digest does not match current and historical canonical gate text")

    if bound[0]:
        candidate = resolve_file(bound[0].group(1), path) if resolve_file else None
        if candidate is None:
            raise Invalid(f"{path}: accepted plan candidate is unavailable")
        candidate_envelope, candidate_outcomes = _plan_envelope(
            candidate, f"{path} at {bound[0].group(1)}"
        )
        _progress(
            candidate,
            f"{path} at acceptance candidate {bound[0].group(1)}",
            candidate_outcomes,
            "Open",
        )
        _, _, candidate_complete = _governance_records(
            candidate, f"{path} at acceptance candidate {bound[0].group(1)}"
        )
        if candidate_complete != [False, False]:
            raise Invalid(f"{path}: acceptance candidate governance must be empty")
        if envelope != candidate_envelope:
            raise Invalid(f"{path}: accepted normative plan envelope differs from its candidate")

    if bound[1]:
        closure_candidate = (
            resolve_file(bound[1].group(1), path) if resolve_file else None
        )
        if closure_candidate is None:
            raise Invalid(f"{path}: closure candidate plan is unavailable")
        closure_envelope, closure_outcomes = _plan_envelope(
            closure_candidate, f"{path} at closure candidate {bound[1].group(1)}"
        )
        _progress(
            closure_candidate,
            f"{path} at closure candidate {bound[1].group(1)}",
            closure_outcomes,
            "Closed",
        )
        closure_rows, _, closure_complete = _governance_records(
            closure_candidate, f"{path} at closure candidate {bound[1].group(1)}"
        )
        if closure_complete != [True, False] or closure_rows[0] != rows[0]:
            raise Invalid(
                f"{path}: closure candidate must retain Acceptance and leave Closure empty"
            )
        if closure_envelope != envelope:
            raise Invalid(f"{path}: closure candidate changed the accepted normative envelope")

    visible = _visible_line_numbers(text, path)
    lines = _lines(text, path)
    if any(lines[i] == "## Milestone Status" for i in visible):
        raise Invalid(f"{path}: lifecycle state belongs only in the canonical register")


def _governance_history(
    current: Mapping[str, str],
    history: tuple[
        str,
        tuple[tuple[str, tuple[str, ...], Mapping[str, str]], ...],
    ]
    | None,
) -> None:
    if history is None:
        raise Invalid("governed documents: complete reachable governance history is unavailable")
    head, snapshots = history

    all_paths = set(current)
    for _, _, governed in snapshots:
        all_paths.update(governed)
    for path in all_paths:
        if path in ADR_PATHS:
            continue
        relative = path.removeprefix("docs/plans/")
        if (
            not path.startswith("docs/plans/")
            or "/" in relative
            or not relative.endswith(".md")
            or relative == "README.md"
        ):
            raise Invalid(f"{path}: invalid historical governed-document path")
        name = (
            relative.removesuffix("-gate.md")
            if relative.endswith("-gate.md")
            else relative.removesuffix(".md")
        )
        _milestone(f"`{name}`", path)

    def plan_is_accepted(text: str | None, path: str, revision: str) -> bool:
        if text is None or "## Governance Records" not in text:
            return False
        _, _, complete = _governance_records(text, f"{path} at {revision}")
        return complete[0]

    def values(
        text: str,
        path: str,
        revision: str,
        governed: Mapping[str, str],
    ) -> tuple[str | None, ...]:
        historical_path = f"{path} at {revision}"
        if path in ADR_PATHS:
            record = _adr_record(text, historical_path, legacy_ok=True)
            if record is None or not record[2]:
                return (None, None)
            return ("\0".join(record[1]), text)
        if path.endswith("-gate.md"):
            plan_path = path.removesuffix("-gate.md") + ".md"
            if not plan_is_accepted(governed.get(plan_path), plan_path, revision):
                return (None,)
            digest = _gate_digest(text, historical_path)
            return (f"{digest}\0{text}",)
        rows, _, complete = _governance_records(text, historical_path)
        envelope = (
            "\n".join(_plan_envelope(text, historical_path)[0])
            if complete[0]
            else None
        )
        return (
            "\0".join(rows[0]) if complete[0] else None,
            "\0".join(rows[1]) if complete[1] else None,
            envelope,
        )

    def labels(path: str) -> tuple[str, ...]:
        return (
            ("Acceptance", "accepted document")
            if path in ADR_PATHS
            else ("accepted gate",)
            if path.endswith("-gate.md")
            else ("Acceptance", "Closure", "normative envelope")
        )

    inherited: dict[str, dict[str, list[str | None]]] = {}
    for revision, parents, governed in (
        *snapshots,
        ("working tree", (head,), current),
    ):
        if revision in inherited or any(parent not in inherited for parent in parents):
            raise Invalid("governed documents: history is duplicated or not parent-first")
        anchors: dict[str, list[str | None]] = {}
        for path in all_paths:
            path_anchors: list[str | None] = []
            path_labels = labels(path)
            for index, label in enumerate(path_labels):
                parent_anchors = {
                    inherited[parent][path][index]
                    for parent in parents
                    if inherited[parent][path][index] is not None
                }
                if len(parent_anchors) > 1:
                    raise Invalid(
                        f"{path}: conflicting completed {label} records meet at {revision}"
                    )
                path_anchors.append(next(iter(parent_anchors), None))
            anchors[path] = path_anchors

            text = governed.get(path)
            if text is None:
                if path.endswith("-gate.md"):
                    plan_path = path.removesuffix("-gate.md") + ".md"
                    if plan_is_accepted(governed.get(plan_path), plan_path, revision):
                        raise Invalid(
                            f"{path}: gate is missing when Acceptance completes at {revision}"
                        )
                if any(path_anchors):
                    raise Invalid(f"{path}: completed governance record disappeared at {revision}")
                continue
            current_values = values(text, path, revision, governed)
            for index, label in enumerate(path_labels):
                value = current_values[index]
                anchor = path_anchors[index]
                if anchor is None and value is not None:
                    path_anchors[index] = value
                elif anchor is not None and value != anchor:
                    raise Invalid(
                        f"{path}: completed {label} governance record changed at {revision}"
                    )
        inherited[revision] = anchors


def validate(
    documents: Mapping[str, str],
    resolve_file: Callable[[str, str], str | None] | None = None,
    first_parent_plans: Callable[
        [],
        tuple[
            str,
            tuple[tuple[str, tuple[str, ...], Mapping[str, str]], ...],
        ]
        | None,
    ]
    | None = None,
) -> list[str]:
    errors: list[str] = []
    try:
        required = (
            "README.md",
            "docs/plans/README.md",
            "docs/vision.md",
            "docs/roadmap.md",
            *ADR_PATHS,
        )
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

        adr_statuses = {
            path: _validate_adr(documents[path], path, resolve_file)
            for path in ADR_PATHS
        }
        if parsed_rows != [("M0", "Blocked", "—", "—")]:
            raise Invalid(
                "docs/plans/README.md: bootstrap permits only Blocked M0; its opening "
                "branch must replace this seed guard with lifecycle-specific enforcement"
            )
        if values != _blocked_m0_values(adr_statuses):
            raise Invalid(
                "docs/plans/README.md: ADR disposition requires the exact blocked-M0 status capsule"
            )

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

        current_governed = {
            path: documents[path]
            for path in documents
            if path in ADR_PATHS
            or (
                path.startswith("docs/plans/")
                and path != "docs/plans/README.md"
                and path.endswith(".md")
            )
        }
        _governance_history(
            current_governed,
            first_parent_plans() if first_parent_plans else None,
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
    paths = [
        root / name
        for name in (
            "README.md",
            "docs/plans/README.md",
            "docs/vision.md",
            "docs/roadmap.md",
            *ADR_PATHS,
        )
    ]
    plans = root / "docs/plans"
    if plans.exists():
        paths.extend(path for path in plans.rglob("*.md") if path != plans / "README.md")
    documents: dict[str, str] = {}
    for path in paths:
        if not path.exists():
            continue
        relative = path.relative_to(root).as_posix()
        try:
            documents[relative] = path.read_bytes().decode("utf-8")
        except UnicodeDecodeError as error:
            raise Invalid(f"{relative}: governed Markdown must be UTF-8") from error
    return documents


def _git_run(root: Path, *args: str) -> subprocess.CompletedProcess[bytes]:
    environment = os.environ.copy()
    environment.update(
        GIT_NO_LAZY_FETCH="1",
        GIT_NO_REPLACE_OBJECTS="1",
        GIT_OPTIONAL_LOCKS="0",
        LC_ALL="C",
    )
    return subprocess.run(
        ["git", "--no-replace-objects", *args],
        cwd=root,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def _git_resolver(
    root: Path,
    run: Callable[..., subprocess.CompletedProcess[bytes]] = _git_run,
) -> Callable[[str, str], str | None]:
    def resolve(sha: str, path: str) -> str | None:
        object_type = run(root, "cat-file", "-t", sha)
        if object_type.returncode or object_type.stdout != b"commit\n":
            return None
        reachable = run(root, "merge-base", "--is-ancestor", sha, "HEAD")
        if reachable.returncode:
            return None
        result = run(root, "show", f"{sha}:{path}")
        if result.returncode:
            return None
        try:
            return result.stdout.decode("utf-8")
        except UnicodeDecodeError:
            return None

    return resolve


def _git_plan_history(
    root: Path,
) -> Callable[
    [],
    tuple[
        str,
        tuple[tuple[str, tuple[str, ...], Mapping[str, str]], ...],
    ]
    | None,
]:
    def history() -> tuple[
        str,
        tuple[tuple[str, tuple[str, ...], Mapping[str, str]], ...],
    ] | None:
        shallow = _git_run(root, "rev-parse", "--is-shallow-repository")
        if shallow.returncode or shallow.stdout != b"false\n":
            return None

        graft = _git_run(root, "rev-parse", "--git-path", "info/grafts")
        if graft.returncode:
            return None
        try:
            graft_path = Path(graft.stdout.decode("utf-8").strip())
            if not graft_path.is_absolute():
                graft_path = root / graft_path
            if graft_path.exists() and (
                not graft_path.is_file() or bool(graft_path.read_bytes())
            ):
                return None
        except (OSError, UnicodeDecodeError):
            return None

        revisions = _git_run(root, "rev-list", "--parents", "--topo-order", "--reverse", "HEAD")
        if revisions.returncode:
            return None
        records = [line.split() for line in revisions.stdout.splitlines()]
        if not records or any(
            not record
            or any(not re.fullmatch(rb"[0-9a-f]{40}", item) for item in record)
            for record in records
        ):
            return None

        snapshots: list[tuple[str, tuple[str, ...], Mapping[str, str]]] = []
        for record in records:
            sha = record[0].decode("ascii")
            parents = tuple(item.decode("ascii") for item in record[1:])
            tree = _git_run(
                root,
                "ls-tree",
                "-rz",
                "-r",
                "--full-tree",
                sha,
                "--",
                "docs/plans",
                *ADR_PATHS,
            )
            if tree.returncode:
                return None
            plans: dict[str, str] = {}
            entries = tree.stdout.split(b"\0")
            if entries[-1]:
                return None
            for entry in entries[:-1]:
                metadata, separator, raw_path = entry.partition(b"\t")
                fields = metadata.split()
                if not separator or len(fields) != 3:
                    return None
                try:
                    path = raw_path.decode("utf-8")
                except UnicodeDecodeError:
                    return None
                relative = path.removeprefix("docs/plans/")
                plan = (
                    path.startswith("docs/plans/")
                    and relative.endswith(".md")
                    and relative != "README.md"
                )
                if path not in ADR_PATHS and not plan:
                    continue
                mode, object_type, object_id = fields
                if mode != b"100644" or object_type != b"blob":
                    return None
                blob = _git_run(root, "cat-file", "blob", object_id.decode("ascii"))
                if blob.returncode:
                    return None
                try:
                    plans[path] = blob.stdout.decode("utf-8")
                except UnicodeDecodeError:
                    return None
            snapshots.append((sha, parents, plans))
        return snapshots[-1][0], tuple(snapshots)

    return history


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    root = parser.parse_args().root.resolve()
    try:
        documents = _load(root)
    except Invalid as error:
        print(error, file=sys.stderr)
        return 1
    errors = validate(documents, _git_resolver(root), _git_plan_history(root))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("status check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
