#!/usr/bin/env python3
"""Validate paired project documents and the marked status facts they govern.

Concept:
    Keep the repository's visible project state and two-depth documentation
    complete, connected, and honest.

Technical depth:
    Parse a deliberately small Markdown subset, bind accepted ADR and milestone
    bytes to reachable Git history, and fail closed on ambiguous structure.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import posixpath
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
        "[ADR 0001](../adr/0001-repository-and-application-layout.md#concept) and "
        "[ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) must be accepted before "
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
BOOTSTRAP_ADR_PATHS = (
    "docs/adr/0001-repository-and-application-layout.md",
    "docs/adr/0002-bootstrap-runtime-floor.md",
)
ADR_NAMES = {
    BOOTSTRAP_ADR_PATHS[0]: "ADR 0001",
    BOOTSTRAP_ADR_PATHS[1]: "ADR 0002",
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
BOUND = re.compile(
    r"candidate `([0-9a-f]{40})`; "
    r"concept `sha256:([0-9a-f]{64})`; "
    r"technical `sha256:([0-9a-f]{64})`; "
    r"gate `sha256:([0-9a-f]{64})`\Z"
)
ADR_BOUND = re.compile(
    r"candidate `([0-9a-f]{40})`; "
    r"concept `sha256:([0-9a-f]{64})`; "
    r"technical `sha256:([0-9a-f]{64})`\Z"
)
ANCHOR_ID = r"[a-z0-9]+(?:-[a-z0-9]+)*"
ANCHOR_TAG = re.compile(rf'<a id="({ANCHOR_ID})"></a>')
ANCHOR = re.compile(rf'<a id="({ANCHOR_ID})"></a>\Z')
LINK = re.compile(r"\[([^\]\r\n]*)\]\(([^()\s]+)\)\Z")
LINK_ANY = re.compile(r"\[([^\]\r\n]*)\]\(([^()\s]+)\)")
ADR_CONCEPT_PATH = re.compile(r"docs/adr/[0-9]{4}-[a-z0-9]+(?:-[a-z0-9]+)*\.md\Z")

MARKERS = {
    "readme": ("<!-- loopex:readme-status:start -->", "<!-- loopex:readme-status:end -->"),
    "current": ("<!-- loopex:current-status:start -->", "<!-- loopex:current-status:end -->"),
    "register": ("<!-- loopex:milestone-register:start -->", "<!-- loopex:milestone-register:end -->"),
    "plan_concept_envelope": (
        "<!-- loopex:plan-concept-envelope:start -->",
        "<!-- loopex:plan-concept-envelope:end -->",
    ),
    "plan_technical_envelope": (
        "<!-- loopex:plan-technical-envelope:start -->",
        "<!-- loopex:plan-technical-envelope:end -->",
    ),
    "rejoin_source": ("<!-- loopex:rejoin-source:start -->", "<!-- loopex:rejoin-source:end -->"),
    "rejoin_copy": ("<!-- loopex:rejoin-copy:start -->", "<!-- loopex:rejoin-copy:end -->"),
}

PLAN_CONCEPT_SECTIONS = (
    "### Purpose",
    "### Outcomes",
    "### Scope",
    "### Non-Goals",
)
PLAN_CONCEPT_ANCHORS = (
    "concept-plan-purpose",
    "concept-plan-outcomes",
    "concept-plan-scope",
    "concept-plan-non-goals",
)

PLAN_TECHNICAL_SECTIONS = (
    "### Prerequisites and Acceptance Points",
    "### Ownership, Decision Owners, and Rejoin Barriers",
    "### Evidence Obligations and Mapping",
    "### Compatibility",
    "### Migration and Rollback",
    "### Packaging",
    "### Proportional Minimalism Budget",
)
PLAN_TECHNICAL_ANCHORS = (
    "technical-plan-prerequisites",
    "technical-plan-ownership",
    "technical-plan-evidence",
    "technical-plan-compatibility",
    "technical-plan-migration",
    "technical-plan-packaging",
    "technical-plan-minimalism",
)
PLAN_RELATIONSHIPS = {
    ("concept", "technical-depth"),
    ("concept-plan-outcomes", "technical-plan-evidence"),
    ("concept-plan-scope", "technical-plan-prerequisites"),
    ("concept-plan-scope", "technical-plan-ownership"),
    ("concept-plan-scope", "technical-plan-compatibility"),
    ("concept-plan-scope", "technical-plan-migration"),
    ("concept-plan-scope", "technical-plan-packaging"),
    ("concept-plan-scope", "technical-plan-minimalism"),
    ("concept-plan-non-goals", "technical-plan-prerequisites"),
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
            without_anchors = ANCHOR_TAG.sub("", exposed_text)
            if HTML_TAG.search(without_anchors) or without_anchors.lstrip().startswith("<"):
                raise Invalid(f"{path}: raw HTML is not allowed in active Markdown")

    if fence or comment or ticks is not None:
        raise Invalid(f"{path}: unclosed Markdown or HTML hiding construct")
    return visible


def _exposed_line(line: str) -> str:
    """Remove inline code and comments from a line already known to start visible."""
    exposed: list[str] = []
    ticks: int | None = None
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
    return "".join(exposed)


def _technical_path(concept_path: str) -> str:
    return concept_path.removesuffix(".md") + "-technical.md"


def _concept_path(technical_path: str) -> str:
    return technical_path.removesuffix("-technical.md") + ".md"


def _adr_concept_paths(documents: Mapping[str, str]) -> tuple[str, ...]:
    return tuple(
        sorted(
            path
            for path in documents
            if ADR_CONCEPT_PATH.fullmatch(path) and not path.endswith("-technical.md")
        )
    )


def _relative_target(source: str, target: str) -> str:
    return posixpath.relpath(target, posixpath.dirname(source) or ".")


def _is_depth_anchor(anchor: str, prefix: str) -> bool:
    return anchor == ("concept" if prefix == "concept" else "technical-depth") or anchor.startswith(
        prefix + "-"
    )


def _relationship(
    text: str,
    path: str,
    *,
    heading: str,
    own_prefix: str,
    label: str,
) -> tuple[str, str, str]:
    """Read the single top-level relationship carried by one paired document.

    Concept:
        Each depth announces itself once and immediately names the other depth.

    Technical depth:
        Only a visible semantic anchor, exact H2, optional blank line, and one
        labelled Markdown link are accepted. The returned fragment is resolved
        after both documents have been parsed.
    """
    lines = _lines(text, path)
    visible = _visible_line_numbers(text, path)
    expected_heading_text = heading.removeprefix("## ")
    headings: list[int] = []
    for index in visible:
        match = ATX.match(lines[index])
        if match and match.group(1) == "##":
            payload = lines[index][match.end() :].strip()
            payload = re.sub(r"[ \t]+#+[ \t]*\Z", "", payload).rstrip()
            if payload == expected_heading_text:
                headings.append(index)
        if (
            lines[index].strip() == expected_heading_text
            and index + 1 in visible
            and re.fullmatch(r" {0,3}-+[ \t]*", lines[index + 1])
        ):
            headings.append(index)
    if len(headings) != 1:
        raise Invalid(f"{path}: expected exactly one visible {heading}")
    heading_index = headings[0]
    if lines[heading_index] != heading:
        raise Invalid(f"{path}: {heading} must use its exact canonical ATX heading")
    anchor_index = heading_index - 1
    if anchor_index not in visible:
        raise Invalid(f"{path}: {heading} needs an immediately preceding semantic anchor")
    anchor = ANCHOR.fullmatch(lines[anchor_index])
    if anchor is None or not _is_depth_anchor(anchor.group(1), own_prefix):
        expected = "concept" if own_prefix == "concept" else "technical-depth"
        raise Invalid(f"{path}: {heading} needs the explicit {expected!r} relationship anchor")

    preamble = [line for line in lines[:anchor_index] if line.strip()]
    optional_title = ATX.match(preamble[0]) if len(preamble) == 1 else None
    optional_title_text = ""
    if optional_title is not None:
        optional_title_text = preamble[0][optional_title.end() :].strip()
        optional_title_text = re.sub(
            r"[ \t]+#+[ \t]*\Z", "", optional_title_text
        ).rstrip()
    if preamble and (
        optional_title is None
        or optional_title.group(1) != "#"
        or not optional_title_text
    ):
        raise Invalid(
            f"{path}: paired document must start with an optional H1 and its {heading} relationship"
        )

    link_index = heading_index + 1
    if link_index < len(lines) and not lines[link_index]:
        link_index += 1
    prefix = f"{label}: "
    if link_index not in visible or not lines[link_index].startswith(prefix):
        raise Invalid(f"{path}: {heading} must be followed immediately by {label}: link")
    payload = lines[link_index].removeprefix(prefix)
    if payload.endswith("."):
        payload = payload[:-1]
    link = LINK.fullmatch(payload)
    if link is None:
        raise Invalid(f"{path}: {label} relationship must be one exact Markdown link")
    destination = link.group(2)
    if destination.count("#") != 1:
        raise Invalid(f"{path}: {label} relationship needs one nonempty fragment")
    target, fragment = destination.split("#", 1)
    if not target or not fragment:
        raise Invalid(f"{path}: {label} relationship needs one nonempty fragment")
    return anchor.group(1), target, fragment


def _anchors(text: str, path: str, prefix: str) -> dict[str, int]:
    lines = _lines(text, path)
    visible = _visible_line_numbers(text, path)
    anchors: dict[str, int] = {}
    for index in visible:
        for match in ANCHOR_TAG.finditer(_exposed_line(lines[index])):
            anchor = match.group(1)
            if not _is_depth_anchor(anchor, prefix):
                raise Invalid(f"{path}: semantic anchor {anchor!r} has the wrong depth prefix")
            if anchor in anchors:
                raise Invalid(f"{path}: semantic anchor {anchor!r} must resolve exactly once")
            anchors[anchor] = index
    if not anchors:
        raise Invalid(f"{path}: no visible {prefix}-... semantic anchor")
    return anchors


def _labelled_links(
    text: str, path: str, *, label: str, own_prefix: str
) -> tuple[tuple[str, str, str], ...]:
    lines = _lines(text, path)
    visible = _visible_line_numbers(text, path)
    current_anchor: str | None = None
    links: list[tuple[str, str, str]] = []
    prefix = f"{label}: "
    for index, line in enumerate(lines):
        if index not in visible:
            continue
        exposed = _exposed_line(line)
        anchors = tuple(ANCHOR_TAG.finditer(exposed))
        if anchors:
            current_anchor = anchors[-1].group(1)
        if not exposed.startswith(prefix):
            continue
        if current_anchor is None or not _is_depth_anchor(current_anchor, own_prefix):
            raise Invalid(f"{path}: {label} link needs a preceding {own_prefix}-... anchor")
        payload = exposed.removeprefix(prefix)
        if payload.endswith("."):
            payload = payload[:-1]
        link = LINK.fullmatch(payload)
        if link is None or link.group(2).count("#") != 1:
            raise Invalid(f"{path}: {label} relationship must be one exact fragmented link")
        target, fragment = link.group(2).split("#", 1)
        if not target or not fragment:
            raise Invalid(f"{path}: {label} relationship needs one nonempty fragment")
        links.append((current_anchor, target, fragment))
    if len(set(links)) != len(links):
        raise Invalid(f"{path}: duplicate {label} relationship")
    return tuple(links)


def _companion_backlinks(
    text: str,
    path: str,
    *,
    companion_target: str,
    own_prefix: str,
) -> tuple[tuple[str, str], ...]:
    lines = _lines(text, path)
    visible = _visible_line_numbers(text, path)
    current_anchor: str | None = None
    backlinks: list[tuple[str, str]] = []
    for index, line in enumerate(lines):
        if index not in visible:
            continue
        exposed = _exposed_line(line)
        anchors = tuple(ANCHOR_TAG.finditer(exposed))
        anchored_here = bool(anchors)
        if anchors:
            current_anchor = anchors[-1].group(1)
        if current_anchor is None or not _is_depth_anchor(current_anchor, own_prefix):
            continue
        if not anchored_here and not exposed.startswith("Concept: "):
            continue
        for link in LINK_ANY.finditer(exposed):
            destination = link.group(2)
            if destination.count("#") != 1:
                continue
            target, fragment = destination.split("#", 1)
            if target == companion_target and fragment:
                backlinks.append((fragment, current_anchor))
    if len(set(backlinks)) != len(backlinks):
        raise Invalid(f"{path}: duplicate reciprocal companion relationship")
    return tuple(backlinks)


def _reject_label(text: str, path: str, label: str) -> None:
    lines = _lines(text, path)
    visible = _visible_line_numbers(text, path)
    if any(_exposed_line(lines[index]).startswith(f"{label}: ") for index in visible):
        raise Invalid(f"{path}: {label} relationship label belongs in the other depth")


def _visible_local_link_targets(text: str, path: str) -> set[str]:
    """Return repository-relative targets of visible local Markdown links."""
    lines = _lines(text, path)
    visible = _visible_line_numbers(text, path)
    targets: set[str] = set()
    for index in visible:
        for link in _markdown_links(_exposed_line(lines[index]), path):
            target = link.group(2).split("#", 1)[0]
            if not target or target.startswith("/") or ":" in target.split("/", 1)[0]:
                continue
            targets.add(posixpath.normpath(posixpath.join(posixpath.dirname(path), target)))
    return targets


def _markdown_links(
    line: str, path: str, *, raw_line: str | None = None
) -> tuple[re.Match[str], ...]:
    """Accept only the repository's small, unambiguous inline-link grammar."""
    matches = tuple(LINK_ANY.finditer(line))
    if any(match.start() and line[match.start() - 1] == "!" for match in matches):
        raise Invalid(f"{path}: unsupported Markdown image syntax")
    for match in matches:
        if match.group(1).strip():
            continue
        code_label = (
            raw_line is not None
            and "[](" not in raw_line
            and re.search(
                rf"\[`[^`\]\r\n]+`\]\({re.escape(match.group(2))}\)", raw_line
            )
        )
        if not code_label:
            raise Invalid(f"{path}: unsupported Markdown link syntax")
    remainder = list(line)
    for match in matches:
        remainder[match.start() : match.end()] = " " * (match.end() - match.start())
    unsupported = "".join(remainder)
    if (
        "](" in unsupported
        or re.search(r"\[[^\]\r\n]+\]\(", unsupported)
        or re.search(r"\[[^\]\r\n]+\]\[[^\]\r\n]*\]", unsupported)
        or re.match(r"[ \t]*\[(?!\^)[^\]\r\n]+\]:", unsupported)
    ):
        raise Invalid(f"{path}: unsupported Markdown link syntax")
    return matches


def _validate_directory_indexes(documents: Mapping[str, str]) -> None:
    """Every documentation directory indexes itself and links back up.

    A document reachable only by knowing it exists is not documented, so the
    index chain from the root README down to each directory is structural
    rather than a convention reviewers must remember.
    """
    directories: set[str] = set()
    for path in documents:
        if path.startswith("docs/") and path.endswith(".md"):
            directories.add(posixpath.dirname(path))

    for directory in sorted(directories):
        index = posixpath.join(directory, "README.md")
        if index not in documents:
            raise Invalid(f"{directory}: directory with Markdown needs a README.md index")

    root_index = "docs/README.md"
    root_targets = _visible_local_link_targets(documents[root_index], root_index)
    if "README.md" not in root_targets:
        raise Invalid(f"{root_index}: must link back to the root README.md")

    for directory in sorted(directories - {"docs"}):
        index = posixpath.join(directory, "README.md")
        if index not in root_targets:
            raise Invalid(f"{root_index}: must link the {directory}/ index")
        if root_index not in _visible_local_link_targets(documents[index], index):
            raise Invalid(f"{index}: must link back to {root_index}")


def _validate_local_links(documents: Mapping[str, str]) -> None:
    """Resolve visible local Markdown paths and explicit semantic fragments."""
    for source, text in documents.items():
        if source.startswith("docs/archive/"):
            continue
        lines = _lines(text, source)
        visible = _visible_line_numbers(text, source)
        for index in visible:
            for link in _markdown_links(
                _exposed_line(lines[index]), source, raw_line=lines[index]
            ):
                destination = link.group(2)
                if destination.startswith(("http://", "https://", "mailto:", "//")):
                    continue
                if "?" in destination:
                    raise Invalid(f"{source}: unsupported local Markdown query destination")
                raw_target, separator, fragment = destination.partition("#")
                if raw_target.startswith("/"):
                    raise Invalid(f"{source}: local Markdown link escapes the repository")
                target = (
                    source
                    if not raw_target
                    else posixpath.normpath(
                        posixpath.join(posixpath.dirname(source), raw_target)
                    )
                )
                if target == ".." or target.startswith("../"):
                    raise Invalid(f"{source}: local Markdown link escapes the repository")
                if raw_target.endswith("/"):
                    prefix = target.rstrip("/") + "/"
                    if not any(path.startswith(prefix) for path in documents):
                        raise Invalid(f"{source}: local documentation directory does not resolve: {destination}")
                    continue
                if target not in documents:
                    if raw_target.endswith(".md") or separator:
                        raise Invalid(f"{source}: local Markdown target does not resolve: {destination}")
                    continue
                if separator:
                    anchor = f'<a id="{fragment}"></a>'
                    target_lines = _lines(documents[target], target)
                    target_visible = _visible_line_numbers(documents[target], target)
                    if sum(target_lines[i].count(anchor) for i in target_visible) != 1:
                        raise Invalid(f"{source}: local Markdown fragment does not resolve exactly once: {destination}")


def _validate_pair(documents: Mapping[str, str], concept_path: str) -> None:
    """Validate one concept/technical pair without interpreting its prose.

    Concept:
        A reader can move between the two depths through one unambiguous entry.

    Technical depth:
        Paths, prefixes, fragments, and reciprocal relationship bytes are exact;
        semantic quality remains an independent review responsibility.
    """
    technical_path = _technical_path(concept_path)
    if concept_path not in documents:
        raise Invalid(f"{concept_path}: paired concept document is missing")
    if technical_path not in documents:
        raise Invalid(f"{technical_path}: paired technical document is missing")
    concept_anchor, concept_target, technical_fragment = _relationship(
        documents[concept_path],
        concept_path,
        heading="## Concept",
        own_prefix="concept",
        label="Technical depth",
    )
    technical_anchor, technical_target, concept_fragment = _relationship(
        documents[technical_path],
        technical_path,
        heading="## Technical depth",
        own_prefix="technical",
        label="Concept",
    )
    if concept_target != _relative_target(concept_path, technical_path):
        raise Invalid(f"{concept_path}: Technical depth link must name its own companion")
    if technical_target != _relative_target(technical_path, concept_path):
        raise Invalid(f"{technical_path}: Concept link must name its own companion")
    concept_anchors = _anchors(documents[concept_path], concept_path, "concept")
    technical_anchors = _anchors(documents[technical_path], technical_path, "technical")
    if concept_fragment not in concept_anchors:
        raise Invalid(f"{technical_path}: Concept fragment does not resolve exactly once")
    if technical_fragment not in technical_anchors:
        raise Invalid(f"{concept_path}: Technical depth fragment does not resolve exactly once")
    if concept_fragment != concept_anchor or technical_fragment != technical_anchor:
        raise Invalid(f"{concept_path}: paired relationship links are not reciprocal")
    concept_links = _labelled_links(
        documents[concept_path],
        concept_path,
        label="Technical depth",
        own_prefix="concept",
    )
    labelled_technical_links = _labelled_links(
        documents[technical_path],
        technical_path,
        label="Concept",
        own_prefix="technical",
    )
    _reject_label(documents[concept_path], concept_path, "Concept")
    _reject_label(documents[technical_path], technical_path, "Technical depth")
    expected_technical = _relative_target(concept_path, technical_path)
    expected_concept = _relative_target(technical_path, concept_path)
    if any(target != expected_technical for _, target, _ in concept_links):
        raise Invalid(f"{concept_path}: labelled Technical depth links may name only its companion")
    if any(fragment not in technical_anchors for _, _, fragment in concept_links):
        raise Invalid(f"{concept_path}: Technical depth fragment does not resolve exactly once")
    if any(target != expected_concept for _, target, _ in labelled_technical_links):
        raise Invalid(f"{technical_path}: labelled Concept links may name only its companion")
    if any(fragment not in concept_anchors for _, _, fragment in labelled_technical_links):
        raise Invalid(f"{technical_path}: Concept fragment does not resolve exactly once")
    forward = {(source, fragment) for source, _, fragment in concept_links}
    backward = set(
        _companion_backlinks(
            documents[technical_path],
            technical_path,
            companion_target=expected_concept,
            own_prefix="technical",
        )
    )
    if forward != backward:
        raise Invalid(f"{concept_path}: labelled relationship links are not reciprocal")


def _document_topology(documents: Mapping[str, str]) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """Classify every active Markdown path before semantic status validation.

    Concept:
        A new active document cannot silently fall outside the repository's
        declared documentation model.

    Technical depth:
        Required and newly discovered pairs, ADR pairs, and plan triples are
        enumerated; operational, index, adapter, skill, gate, and archived paths
        are explicit exceptions.
    """
    folded: dict[str, str] = {}
    for path in documents:
        prior = folded.setdefault(path.casefold(), path)
        if prior != path:
            raise Invalid(f"{path}: Markdown path collides by case with {prior}")
        if path.endswith("-technical-technical.md"):
            raise Invalid(f"{path}: doubled technical suffix is not a document class")

    fixed = {
        "docs/vision.md",
        "docs/roadmap.md",
        "docs/developer/development-charter.md",
    }
    adr_concepts = _adr_concept_paths(documents)
    pairs = fixed | set(adr_concepts)

    exact_exceptions = {
        "docs/README.md",
        "docs/developer/agent-context-map.md",
        "docs/developer/agent-adapter-smoke.md",
    }
    unpaired_prefixes = (
        "docs/archive/",
        "docs/operator/",
        "docs/generated/",
        "docs/evidence/",
        "docs/schemas/",
        "docs/fixtures/",
    )
    repository_exception_prefixes = (
        "conformance/",
        "schemas/",
        "fixtures/",
        "test/fixtures/",
    )
    repository_exception_paths = (
        re.compile(r"\.agents/skills/[a-z0-9]+(?:-[a-z0-9]+)*/SKILL\.md\Z"),
        re.compile(r"\.claude/agents/[a-z0-9]+(?:-[a-z0-9]+)*\.md\Z"),
        re.compile(r"\.github/ISSUE_TEMPLATE/[^/]+\.md\Z"),
        re.compile(r"\.github/PULL_REQUEST_TEMPLATE/[^/]+\.md\Z"),
        re.compile(r"\.github/pull_request_template\.md\Z"),
    )
    for path in documents:
        if (
            not path.startswith("docs/")
            or path in exact_exceptions
            or path.endswith("/README.md")
            or path.startswith("docs/adr/")
            or path.startswith("docs/plans/")
            or path.startswith(unpaired_prefixes)
        ):
            continue
        pairs.add(_concept_path(path) if path.endswith("-technical.md") else path)

    for concept in sorted(pairs):
        _validate_pair(documents, concept)

    plan_concepts: set[str] = set()
    plan_technical: set[str] = set()
    plan_gates: set[str] = set()
    for path in documents:
        if not path.startswith("docs/plans/") or path == "docs/plans/README.md":
            continue
        relative = path.removeprefix("docs/plans/")
        if "/" in relative:
            raise Invalid(f"{path}: nested plan Markdown is not allowed")
        if relative.endswith("-technical.md"):
            plan_technical.add(relative.removesuffix("-technical.md"))
        elif relative.endswith("-gate.md"):
            plan_gates.add(relative.removesuffix("-gate.md"))
        else:
            plan_concepts.add(relative.removesuffix(".md"))
    if plan_concepts != plan_technical or plan_concepts != plan_gates:
        raise Invalid("docs/plans: concept, technical depth, and gate files must form exact triples")
    for name in sorted(plan_concepts):
        _milestone(f"`{name}`", f"docs/plans/{name}.md")
        _validate_pair(documents, f"docs/plans/{name}.md")

    pair_paths = set(pairs) | {_technical_path(path) for path in pairs}
    index = documents.get("docs/README.md")
    if index is None:
        raise Invalid("docs/README.md: documentation index is missing")
    indexed = _visible_local_link_targets(index, "docs/README.md")
    missing_from_index = sorted(pair_paths - indexed)
    if missing_from_index:
        raise Invalid(
            "docs/README.md: active document pairs are missing from the index: "
            + ", ".join(missing_from_index)
        )
    plan_paths = {
        f"docs/plans/{name}{suffix}"
        for name in plan_concepts
        for suffix in (".md", "-technical.md", "-gate.md")
    }
    root_exceptions = {"AGENTS.md", "README.md", "DEVELOPMENT.md", "CHANGELOG.md", "CLAUDE.md"}
    for path in documents:
        exception = (
            path in root_exceptions
            or path in exact_exceptions
            or path.endswith("/README.md")
            or path.startswith(unpaired_prefixes)
            or path.startswith(repository_exception_prefixes)
            or posixpath.basename(path).casefold().startswith("license")
            or any(pattern.fullmatch(path) for pattern in repository_exception_paths)
        )
        if path not in pair_paths and path not in plan_paths and not exception:
            raise Invalid(f"{path}: unknown active Markdown document class")
    return tuple(sorted(adr_concepts)), tuple(sorted(plan_concepts))


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
        or folded.endswith("-technical")
    ):
        raise Invalid(f"{path}: invalid or reserved milestone name {name!r}")
    return name


def _summary(phase: str, rows: list[tuple[str, str, str, str, str]]) -> str:
    active = [(name, state) for name, state, _, _, _ in rows if state in ACTIVE_STATES]
    blocked = [name for name, state, _, _, _ in rows if state == "Blocked"]
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
    unresolved = [path for path in BOOTSTRAP_ADR_PATHS if statuses[path] != "Accepted"]
    if len(unresolved) == 1:
        path = unresolved[0]
        name = ADR_NAMES[path]
        filename = path.removeprefix("docs/adr/")
        values["Blockers"] = (
            f"[{name}](../adr/{filename}#concept) must be accepted before M0 opens; "
            "a replacement requires a governed guard change"
        )
        values["Next maintainer decision"] = f"Disposition {name}"
    elif not unresolved:
        values["Blockers"] = "M0 has not been explicitly opened gate-first"
        values["Next maintainer decision"] = "Explicitly open or defer M0"
        values["Next transition"] = (
            "Create the branch-only M0 Concept plan, Technical depth plan, and red gate; "
            "install lifecycle-specific status checks; and move M0 to Open"
        )
    return values


def _open_values(name: str) -> dict[str, str]:
    """Derived capsule for an opened milestone that is not yet accepted.

    Opening a gate authorises no implementation, so the authorized-work boundary
    is inherited unchanged from the blocked capsule.
    """
    values = dict(SEED_BLOCKED_VALUES)
    values["Blockers"] = (
        f"`{name}` is open and not accepted; the recorded acceptance authority must "
        "accept both normative envelopes and the gate"
    )
    values["Next maintainer decision"] = f"Accept or reject the `{name}` plan pair and gate"
    values["Next transition"] = (
        f"Record the acceptance governance row and move `{name}` to Accepted"
    )
    return values


def _accepted_values(name: str) -> dict[str, str]:
    """Derived capsule for an accepted milestone.

    Acceptance is the only transition that widens the authorized-work boundary,
    and it widens it to the accepted envelopes and locked gate, no further.
    """
    values = dict(SEED_BLOCKED_VALUES)
    values["Blockers"] = f"None; `{name}` is accepted and implementation may proceed"
    values["Authorized work"] = (
        f"Implementation inside the accepted `{name}` envelopes and its locked gate; "
        "no other product implementation"
    )
    values["Next maintainer decision"] = f"None until `{name}` is ready for independent review"
    values["Next transition"] = (
        f"Turn the locked gate green, then move `{name}` to In progress and In review"
    )
    return values


def _artifact_history(
    history: tuple[str, tuple[tuple[str, tuple[str, ...], Mapping[str, str]], ...]] | None,
) -> None:
    """A bound artifact must match at every revision where its gate declares it.

    Verifying only the current tree leaves a mutate-then-restore hole: a commit
    changes the runner, a later commit restores it, and final validation passes.
    Merge divergence has the same shape, so every reachable revision is checked
    rather than a selected one.
    """
    if history is None:
        return
    _, snapshots = history
    # Binding state propagates along parent edges and is reconciled at merges,
    # so the result does not depend on traversal order. Once a gate binds a
    # target, every descendant must keep binding it: dropping the gate, dropping
    # the declaration, or dropping a single row would each let a commit mutate
    # that artifact behind the gap and a later commit restore it.
    state: dict[str, dict[str, set[str]]] = {}
    for revision, parents, files in snapshots:
        inherited: dict[str, set[str]] = {}
        for parent in parents:
            for gate_path, targets in state.get(parent, {}).items():
                inherited.setdefault(gate_path, set()).update(targets)

        declared: dict[str, set[str]] = {}
        for path, text in files.items():
            if not path.startswith("docs/plans/") or not path.endswith("-gate.md"):
                continue
            if not any(line.strip() == "## Bound Artifacts" for line in text.splitlines()):
                continue
            try:
                artifacts = _bound_artifacts(text, path)
            except Invalid as error:
                raise Invalid(
                    f"{path} at {revision}: bound-artifact declaration is malformed ({error})"
                ) from error
            declared[path] = {target for _, target in artifacts}
            for digest, target in artifacts:
                content = files.get(target)
                if content is None:
                    raise Invalid(
                        f"{path} at {revision}: bound artifact {target} is missing"
                    )
                if hashlib.sha256(content.encode("utf-8")).hexdigest() != digest:
                    raise Invalid(
                        f"{path} at {revision}: bound artifact {target} "
                        "does not match its locked digest"
                    )

        for gate_path, targets in inherited.items():
            if gate_path not in files:
                raise Invalid(
                    f"{gate_path} at {revision}: gate disappeared after binding artifacts"
                )
            if gate_path not in declared:
                raise Invalid(
                    f"{gate_path} at {revision}: bound-artifact declaration disappeared"
                )
            dropped = sorted(targets - declared[gate_path])
            if dropped:
                raise Invalid(
                    f"{gate_path} at {revision}: bound artifact "
                    f"{dropped[0]} is no longer declared"
                )

        merged = {path: set(targets) for path, targets in inherited.items()}
        for path, targets in declared.items():
            merged.setdefault(path, set()).update(targets)
        state[revision] = merged


def _bound_artifacts(gate_text: str, gate_path: str) -> tuple[tuple[str, str], ...]:
    """Digest and path pairs a gate binds outside its own bytes.

    A gate document governs nothing executable on its own: its runner could be
    replaced with a command that exits zero while the document's digest stays
    valid. Binding the runner by content closes that.
    """
    body, _ = _section_body(gate_text, gate_path, "## Bound Artifacts")
    rows = _table(
        [line for line in body if line.startswith("|")],
        ("SHA-256", "Path"),
        f"{gate_path} Bound Artifacts",
    )
    artifacts: list[tuple[str, str]] = []
    for digest, path in rows:
        match = re.fullmatch(r"`([0-9a-f]{64})`", digest)
        target = re.fullmatch(r"`([^`]+)`", path)
        if not match or not target:
            raise Invalid(f"{gate_path}: malformed bound-artifact row")
        artifacts.append((match.group(1), target.group(1)))
    return tuple(artifacts)


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
    table_length = 2 + len(decisions)
    table_body = body[:table_length]
    trailing = [line for line in body[table_length:] if line]
    if trailing and not (len(trailing) == 1 and ANCHOR.fullmatch(trailing[0])):
        raise Invalid(f"{path}: governance rows have trailing content")
    rows = _table(
        table_body,
        ("Decision", "Authority", "Authority evidence", "Bound bytes"),
        path,
    )
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
    technical_text: str,
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
    technical_path = _technical_path(path)
    technical_candidate = (
        resolve_file(bound.group(1), technical_path) if resolve_file else None
    )
    if candidate is None:
        raise Invalid(f"{path}: accepted ADR candidate is unavailable")
    if technical_candidate is None:
        raise Invalid(f"{technical_path}: accepted ADR candidate is unavailable")
    candidate_record = _adr_record(
        candidate, f"{path} at historical candidate {bound.group(1)}"
    )
    if candidate_record is None:
        raise Invalid(f"{path}: historical candidate ADR governance record is unavailable")
    if candidate_record[0] != "Proposed" or candidate_record[2]:
        raise Invalid(f"{path}: historical candidate must be the Proposed ADR with an empty record")
    concept_digest = hashlib.sha256(candidate.encode("utf-8")).hexdigest()
    technical_digest = hashlib.sha256(technical_candidate.encode("utf-8")).hexdigest()
    if concept_digest != bound.group(2):
        raise Invalid(f"{path}: ADR concept digest does not match its historical candidate")
    if technical_digest != bound.group(3):
        raise Invalid(f"{path}: ADR technical digest does not match its historical candidate")
    if technical_text != technical_candidate:
        raise Invalid(f"{technical_path}: accepted ADR technical depth differs from its candidate")

    reconstructed = _lines(text, path)
    reconstructed[status_index] = "- **Status:** Proposed"
    reconstructed[row_index] = "| Acceptance | — | — | — |"
    if "\n".join(reconstructed) != candidate:
        raise Invalid(
            f"{path}: accepted ADR differs from its historical candidate outside the disposition record"
        )
    return status


def _plan_envelope(
    text: str,
    path: str,
    *,
    key: str,
    title: str,
    sections_expected: tuple[str, ...],
    section_anchors: tuple[str, ...],
    depth_heading: str,
    trailing: tuple[str, ...] = (),
) -> tuple[tuple[str, ...], tuple[tuple[int, str], ...]]:
    """Parse one locked half of a milestone plan.

    Concept:
        The accepted intent and its technical obligations are separately clear
        while remaining one milestone commitment.

    Technical depth:
        Exact markers and heading order delimit immutable bytes; mutable progress
        can exist only after the concept envelope.
    """
    if "\r" in text:
        raise Invalid(f"{path}: plan text must use canonical UTF-8/LF bytes")
    body = _block(text, path, key)
    lines = _lines(text, path)
    first_content = next((line for line in lines if line.strip()), None)
    expected_anchor = "concept" if depth_heading == "## Concept" else "technical-depth"
    first_anchor = ANCHOR.fullmatch(first_content or "")
    if first_anchor is None or first_anchor.group(1) != expected_anchor:
        raise Invalid(f"{path}: plan document must start with its semantic anchor")
    marker_start = lines.index(MARKERS[key][0])
    before_marker = next(
        (line for line in reversed(lines[:marker_start]) if line.strip()), None
    )
    expected_label = "Technical depth: " if depth_heading == "## Concept" else "Concept: "
    if before_marker is None or not before_marker.startswith(expected_label):
        raise Invalid(f"{path}: normative envelope must directly follow its relationship link")
    marker_end = lines.index(MARKERS[key][1])
    after_marker = next((line for line in lines[marker_end + 1 :] if line.strip()), None)
    if trailing:
        if after_marker != trailing[0]:
            raise Invalid(f"{path}: envelope end must be followed directly by {trailing[0]}")
    elif after_marker is not None:
        raise Invalid(f"{path}: technical plan contains content outside its normative envelope")
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
        depth_heading,
        title,
        *sections_expected,
        *trailing,
    )
    if tuple(document_headings) != expected_document_headings:
        raise Invalid(f"{path}: plan document headings must be exactly the governed plan sequence")

    body_text = "\n".join(body)
    visible = _visible_line_numbers(body_text, path)
    if not body or body[0] != title:
        raise Invalid(f"{path}: normative plan envelope must start with {title}")
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
    expected = (title, *sections_expected)
    if tuple(line for _, line in sections) != expected:
        raise Invalid(f"{path}: normative plan-envelope headings are missing, duplicated, or reordered")
    if len(section_anchors) != len(sections_expected):
        raise Invalid(f"{path}: plan section-anchor contract is misconfigured")
    for (start, heading), anchor in zip(sections[1:], section_anchors):
        if start < 1 or body[start - 1] != f'<a id="{anchor}"></a>':
            raise Invalid(f"{path}: {heading} needs its exact semantic anchor {anchor!r}")
    for position, (start, heading) in enumerate(sections[1:], 1):
        end = sections[position + 1][0] if position + 1 < len(sections) else len(body)
        content: list[str] = []
        for index in range(start + 1, end):
            if index not in visible or not body[index].strip():
                continue
            line = body[index].strip()
            if ANCHOR.fullmatch(line):
                continue
            relationship = line.removeprefix("Concept: ").removeprefix(
                "Technical depth: "
            )
            if relationship.endswith("."):
                relationship = relationship[:-1]
            if relationship != line and LINK.fullmatch(relationship):
                continue
            content.append(line)
        if not content:
            raise Invalid(f"{path}: {heading} must contain a concrete commitment")
    return tuple(body), tuple(sections)


def _plan_concept_envelope(text: str, path: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    envelope, sections = _plan_envelope(
        text,
        path,
        key="plan_concept_envelope",
        title="## Normative Concept Envelope",
        sections_expected=PLAN_CONCEPT_SECTIONS,
        section_anchors=PLAN_CONCEPT_ANCHORS,
        depth_heading="## Concept",
        trailing=("## Workstreams", "## Progress and Evidence", "## Governance Records"),
    )
    outcomes_start = sections[2][0] + 1
    outcomes_end = sections[3][0]
    outcomes = list(envelope[outcomes_start:outcomes_end])
    header = "| # | Outcome | Evidence class | Gate selector |"
    if outcomes.count(header) != 1:
        raise Invalid(f"{path}: Outcomes must contain one exact normative outcomes table")
    table_start = outcomes.index(header)
    table_end = table_start
    while table_end < len(outcomes) and outcomes[table_end].startswith("|"):
        table_end += 1
    table_lines = outcomes[table_start:table_end]
    rows = _table(
        table_lines,
        ("#", "Outcome", "Evidence class", "Gate selector"),
        f"{path} Outcomes",
    )
    if not rows or [row[0] for row in rows] != [str(index) for index in range(1, len(rows) + 1)]:
        raise Invalid(f"{path}: Outcomes must contain consecutively numbered commitments")
    return envelope, tuple(row[0] for row in rows)


def _plan_technical_envelope(text: str, path: str) -> tuple[str, ...]:
    envelope, _ = _plan_envelope(
        text,
        path,
        key="plan_technical_envelope",
        title="## Normative Technical Envelope",
        sections_expected=PLAN_TECHNICAL_SECTIONS,
        section_anchors=PLAN_TECHNICAL_ANCHORS,
        depth_heading="## Technical depth",
    )
    return envelope


def _envelope_digest(envelope: tuple[str, ...]) -> str:
    return hashlib.sha256("\n".join(envelope).encode("utf-8")).hexdigest()


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
    technical_text: str,
    gate_text: str,
    name: str,
    state: str,
    resolve_file: Callable[[str, str], str | None] | None,
) -> None:
    path = f"docs/plans/{name}.md"
    technical_path = f"docs/plans/{name}-technical.md"
    relationships = {
        (source, fragment)
        for source, _, fragment in _labelled_links(
            text, path, label="Technical depth", own_prefix="concept"
        )
    }
    if relationships != PLAN_RELATIONSHIPS:
        raise Invalid(f"{path}: plan sections need the exact Concept-to-Technical-depth mapping")
    envelope, outcome_ids = _plan_concept_envelope(text, path)
    technical_envelope = _plan_technical_envelope(technical_text, technical_path)
    current_concept_digest = _envelope_digest(envelope)
    current_technical_digest = _envelope_digest(technical_envelope)
    _progress(text, path, outcome_ids, state)
    rows, bound, complete = _governance_records(text, path)
    expected = [False, False] if state == "Open" else [True, True] if state == "Closed" else [True, False]
    if complete != expected:
        raise Invalid(f"{path}: governance records do not match {state} lifecycle state")
    gate_path = f"docs/plans/{name}-gate.md"
    gate_digest = _gate_digest(gate_text, gate_path)
    candidates: dict[str, tuple[str, str, str]] = {}
    for digest in (item for item in bound if item):
        revision = digest.group(1)
        historical_concept = resolve_file(revision, path) if resolve_file else None
        historical_technical = resolve_file(revision, technical_path) if resolve_file else None
        historical_gate = resolve_file(revision, gate_path) if resolve_file else None
        if None in (historical_concept, historical_technical, historical_gate):
            raise Invalid(f"{path}: governance candidate or one of its bound files is unavailable")
        assert historical_concept is not None
        assert historical_technical is not None
        assert historical_gate is not None
        historical_concept_envelope, _ = _plan_concept_envelope(
            historical_concept, f"{path} at {revision}"
        )
        historical_technical_envelope = _plan_technical_envelope(
            historical_technical, f"{technical_path} at {revision}"
        )
        concept_digest = _envelope_digest(historical_concept_envelope)
        technical_digest = _envelope_digest(historical_technical_envelope)
        historical_gate_digest = _gate_digest(
            historical_gate, f"{gate_path} at {revision}"
        )
        if digest.group(2) != concept_digest or digest.group(2) != current_concept_digest:
            raise Invalid(f"{path}: governance concept digest does not match current and candidate envelopes")
        if digest.group(3) != technical_digest or digest.group(3) != current_technical_digest:
            raise Invalid(f"{path}: governance technical digest does not match current and candidate envelopes")
        if digest.group(4) != gate_digest or digest.group(4) != historical_gate_digest:
            raise Invalid(f"{path}: governance gate digest does not match current and historical gate text")
        candidates[revision] = (historical_concept, historical_technical, historical_gate)

    if bound[0]:
        candidate, technical_candidate, _ = candidates[bound[0].group(1)]
        candidate_envelope, candidate_outcomes = _plan_concept_envelope(
            candidate, f"{path} at {bound[0].group(1)}"
        )
        candidate_technical_envelope = _plan_technical_envelope(
            technical_candidate, f"{technical_path} at {bound[0].group(1)}"
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
            raise Invalid(f"{path}: accepted normative concept envelope differs from its candidate")
        if technical_envelope != candidate_technical_envelope:
            raise Invalid(f"{technical_path}: accepted normative technical envelope differs from its candidate")

    if bound[1]:
        closure_candidate, closure_technical_candidate, _ = candidates[bound[1].group(1)]
        closure_envelope, closure_outcomes = _plan_concept_envelope(
            closure_candidate, f"{path} at closure candidate {bound[1].group(1)}"
        )
        closure_technical_envelope = _plan_technical_envelope(
            closure_technical_candidate,
            f"{technical_path} at closure candidate {bound[1].group(1)}",
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
            raise Invalid(f"{path}: closure candidate changed the accepted normative concept envelope")
        if closure_technical_envelope != technical_envelope:
            raise Invalid(f"{technical_path}: closure candidate changed the accepted normative technical envelope")

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

    all_governed_paths = set(current)
    for _, _, governed in snapshots:
        all_governed_paths.update(governed)

    adr_concepts = {
        path
        for path in all_governed_paths
        if ADR_CONCEPT_PATH.fullmatch(path) and not path.endswith("-technical.md")
    }
    plan_concepts: set[str] = set()
    gates: set[str] = set()
    for path in all_governed_paths:
        if path in adr_concepts or path.endswith("-technical.md"):
            continue
        relative = path.removeprefix("docs/plans/")
        if (
            not path.startswith("docs/plans/")
            or "/" in relative
            or not relative.endswith(".md")
            or relative == "README.md"
        ):
            raise Invalid(f"{path}: invalid historical governed-document path")
        is_gate = relative.endswith("-gate.md")
        name = relative.removesuffix("-gate.md") if is_gate else relative.removesuffix(".md")
        _milestone(f"`{name}`", path)
        (gates if is_gate else plan_concepts).add(path)
    primary_paths = adr_concepts | plan_concepts | gates

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
        if path in adr_concepts:
            record = _adr_record(text, historical_path, legacy_ok=True)
            if record is None or not record[2]:
                return (None, None, None)
            technical_path = _technical_path(path)
            technical = governed.get(technical_path)
            if technical is None:
                raise Invalid(
                    f"{technical_path}: accepted ADR technical depth disappeared at {revision}"
                )
            return ("\0".join(record[1]), text, technical)
        if path.endswith("-gate.md"):
            plan_path = path.removesuffix("-gate.md") + ".md"
            if not plan_is_accepted(governed.get(plan_path), plan_path, revision):
                return (None,)
            digest = _gate_digest(text, historical_path)
            return (f"{digest}\0{text}",)
        rows, _, complete = _governance_records(text, historical_path)
        if not complete[0]:
            return (None, None, None, None)
        technical_path = path.removesuffix(".md") + "-technical.md"
        technical = governed.get(technical_path)
        if technical is None:
            raise Invalid(
                f"{technical_path}: accepted plan technical depth disappeared at {revision}"
            )
        concept_envelope = "\n".join(_plan_concept_envelope(text, historical_path)[0])
        technical_envelope = "\n".join(
            _plan_technical_envelope(technical, f"{technical_path} at {revision}")
        )
        return (
            "\0".join(rows[0]),
            "\0".join(rows[1]) if complete[1] else None,
            concept_envelope,
            technical_envelope,
        )

    def labels(path: str) -> tuple[str, ...]:
        return (
            ("Acceptance", "accepted concept", "accepted technical depth")
            if path in adr_concepts
            else ("accepted gate",)
            if path.endswith("-gate.md")
            else (
                "Acceptance",
                "Closure",
                "normative concept envelope",
                "normative technical envelope",
            )
        )

    inherited: dict[str, dict[str, list[str | None]]] = {}
    for revision, parents, governed in (
        *snapshots,
        ("working tree", (head,), current),
    ):
        if revision in inherited or any(parent not in inherited for parent in parents):
            raise Invalid("governed documents: history is duplicated or not parent-first")
        anchors: dict[str, list[str | None]] = {}
        for path in primary_paths:
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
    read_artifact: Callable[[str], bytes | None] | None = None,
) -> list[str]:
    errors: list[str] = []
    try:
        adr_paths, plan_names = _document_topology(documents)
        _validate_local_links(documents)
        _validate_directory_indexes(documents)
        required = (
            "README.md",
            "docs/plans/README.md",
            "docs/vision.md",
            "docs/vision-technical.md",
            "docs/roadmap.md",
            "docs/roadmap-technical.md",
            "docs/developer/development-charter.md",
            "docs/developer/development-charter-technical.md",
            *BOOTSTRAP_ADR_PATHS,
            *(_technical_path(path) for path in BOOTSTRAP_ADR_PATHS),
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
        parsed_rows: list[tuple[str, str, str, str, str]] = []
        names: set[str] = set()
        for raw_name, state, concept_link, technical_link, gate_link in _table(
            register[2:],
            ("Milestone", "State", "Concept", "Technical depth", "Gate"),
            "docs/plans/README.md Milestone Register",
        ):
            name = _milestone(raw_name, "docs/plans/README.md Milestone Register")
            if name.casefold() in names:
                raise Invalid(f"docs/plans/README.md: duplicate or case-colliding milestone {name!r}")
            names.add(name.casefold())
            if state not in STATES:
                raise Invalid(f"docs/plans/README.md: unknown milestone state {state!r}")
            expected = (
                ("—", "—", "—")
                if state == "Blocked"
                else (
                    f"[concept]({name}.md)",
                    f"[technical depth]({name}-technical.md)",
                    f"[gate]({name}-gate.md)",
                )
            )
            if (concept_link, technical_link, gate_link) != expected:
                raise Invalid(f"docs/plans/README.md: {name} has incorrect paired plan/gate links for {state}")
            parsed_rows.append((name, state, concept_link, technical_link, gate_link))

        closed = [name for name, state, _, _, _ in parsed_rows if state == "Closed"]
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
            path: _validate_adr(
                documents[path], documents[_technical_path(path)], path, resolve_file
            )
            for path in adr_paths
        }
        # Lifecycle enforcement. Every representable register state derives its
        # exact status capsule, and a state without a derivation fails closed so
        # the transition that first records it must add one.
        if len(parsed_rows) != 1:
            raise Invalid(
                "docs/plans/README.md: lifecycle enforcement covers exactly one registered "
                "milestone; extend it before registering another"
            )
        registered_name, registered_state = parsed_rows[0][0], parsed_rows[0][1]
        if registered_state == "Blocked":
            if registered_name != "M0":
                raise Invalid(
                    "docs/plans/README.md: the blocked-candidate capsule is derived from the "
                    "founding ADR records and applies only to M0"
                )
            expected_values = _blocked_m0_values(adr_statuses)
        elif registered_state == "Open":
            expected_values = _open_values(registered_name)
        elif registered_state == "Accepted":
            expected_values = _accepted_values(registered_name)
        else:
            raise Invalid(
                f"docs/plans/README.md: milestone state {registered_state!r} has no derived "
                "status capsule; the transition that first records it must add lifecycle "
                "enforcement rather than relax this check"
            )
        if values != expected_values:
            raise Invalid(
                "docs/plans/README.md: the register state requires its exact derived status capsule"
            )

        represented = {name for name, state, _, _, _ in parsed_rows if state != "Blocked"}
        if set(plan_names) != represented:
            raise Invalid("docs/plans: paired plan triples and non-Blocked register rows must match exactly")
        state_by_name = {name: state for name, state, _, _, _ in parsed_rows}
        # A gate binds artifacts outside its own bytes. Verify each against the
        # file it names, so swapping the runner for a no-op fails immediately.
        if read_artifact is not None:
            for name in plan_names:
                gate_path = f"docs/plans/{name}-gate.md"
                for digest, target in _bound_artifacts(documents[gate_path], gate_path):
                    content = read_artifact(target)
                    if content is None:
                        raise Invalid(f"{gate_path}: bound artifact {target} is missing")
                    if hashlib.sha256(content).hexdigest() != digest:
                        raise Invalid(
                            f"{gate_path}: bound artifact {target} does not match its locked digest"
                        )
        for name in plan_names:
            _governance(
                documents[f"docs/plans/{name}.md"],
                documents[f"docs/plans/{name}-technical.md"],
                documents[f"docs/plans/{name}-gate.md"],
                name,
                state_by_name[name],
                resolve_file,
            )

        current_governed = {
            path: documents[path]
            for path in documents
            if path in adr_paths
            or path in {_technical_path(adr_path) for adr_path in adr_paths}
            or (
                path.startswith("docs/plans/")
                and path != "docs/plans/README.md"
                and path.endswith(".md")
            )
        }
        plan_history = first_parent_plans() if first_parent_plans else None
        # The governance walk owns documents; the artifact walk owns bound
        # executables and configuration. Give each only what it governs.
        governance_history = (
            None
            if plan_history is None
            else (
                plan_history[0],
                tuple(
                    (
                        revision,
                        parents,
                        {
                            path: text
                            for path, text in files.items()
                            if path.startswith("docs/")
                        },
                    )
                    for revision, parents, files in plan_history[1]
                ),
            )
        )
        _governance_history(current_governed, governance_history)
        _artifact_history(plan_history)

        source = _block(
            documents["docs/vision-technical.md"],
            "docs/vision-technical.md",
            "rejoin_source",
            "## 22. Ownership and serial barriers",
        )
        copy = _block(
            documents["docs/roadmap-technical.md"],
            "docs/roadmap-technical.md",
            "rejoin_copy",
            "## The Enduring Rejoin Order",
        )
        if source != copy:
            raise Invalid("docs/roadmap-technical.md: rejoin block differs from vision technical §22")
        if len(source) < 4 or source[0] != "```text" or source[-1] != "```":
            raise Invalid("docs/vision-technical.md: rejoin payload must be one complete text fence")
        steps = source[1:-1]
        if len(steps) < 2 or not steps[0].strip() or steps[0].startswith("-> "):
            raise Invalid("docs/vision-technical.md: rejoin payload needs an initial step and at least one transition")
        if any(not step.startswith("-> ") or not step[3:].strip() for step in steps[1:]):
            raise Invalid("docs/vision-technical.md: every later rejoin step must start with '-> '")
    except Invalid as error:
        errors.append(str(error))
    return errors


def _load(root: Path) -> dict[str, str]:
    listed = _git_run(
        root,
        "ls-files",
        "-z",
        "--cached",
        "--others",
        "--exclude-standard",
        "--",
        "*.md",
    )
    if listed.returncode or not listed.stdout.endswith(b"\0"):
        raise Invalid("repository Markdown inventory is unavailable")
    try:
        names = [item.decode("utf-8") for item in listed.stdout[:-1].split(b"\0")]
    except UnicodeDecodeError as error:
        raise Invalid("repository Markdown paths must be UTF-8") from error
    paths = [root / name for name in names]
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
    artifact_paths: tuple[str, ...] = (),
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
                "docs/adr",
                *artifact_paths,
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
                adr = bool(
                    ADR_CONCEPT_PATH.fullmatch(path)
                    or (
                        path.endswith("-technical.md")
                        and ADR_CONCEPT_PATH.fullmatch(_concept_path(path))
                    )
                )
                artifact = path in artifact_paths
                if not adr and not plan and not artifact:
                    continue
                mode, object_type, object_id = fields
                # A bound runner is executable, so artifacts allow mode 100755.
                allowed = (b"100644", b"100755") if artifact else (b"100644",)
                if mode not in allowed or object_type != b"blob":
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
    def read_artifact(relative: str) -> bytes | None:
        target = (root / relative).resolve()
        if root not in target.parents and target != root:
            return None
        return target.read_bytes() if target.is_file() else None

    declared: set[str] = set()
    for path, text in documents.items():
        if path.startswith("docs/plans/") and path.endswith("-gate.md"):
            try:
                declared.update(target for _, target in _bound_artifacts(text, path))
            except Invalid:
                pass

    errors = validate(
        documents,
        _git_resolver(root),
        _git_plan_history(root, tuple(sorted(declared))),
        read_artifact=read_artifact,
    )
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("status check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
