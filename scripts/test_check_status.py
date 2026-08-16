#!/usr/bin/env python3
"""Adversarial controls for paired documents and governed project status.

Concept:
    Mutations that could make project state or documentation ambiguous fail.

Technical depth:
    Compact in-memory fixtures exercise structural parsing, digest binding, and
    full reachable-history anchoring without changing the checkout.
"""

from __future__ import annotations

import copy
import hashlib
import subprocess
import unittest
from pathlib import Path

from check_status import (
    _git_plan_history,
    _git_resolver,
    _governance,
    _governance_history,
    _plan_concept_envelope,
    _plan_technical_envelope,
    _validate_pair,
    validate,
)


SUMMARY = "**Revision status:** Pre-implementation planning; no milestone is active; next candidate `M0` is blocked."
CURRENT = f"""<!-- loopex:current-status:start -->
## Current Status

{SUMMARY}

| Field | Value |
| --- | --- |
| Integrated phase | Pre-implementation planning |
| Last integrated checkpoint | Seed bootstrap — 2026-08-15 |
| Blockers | [ADR 0001](../adr/0001-repository-and-application-layout.md#concept) and [ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) must be accepted before M0 opens; a replacement requires a governed guard change |
| Authorized work | Explicitly authorized planning, ADR, bootstrap, and review work only; no product implementation |
| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |
| Next transition | After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first |
| Validation | `bash scripts/check-bootstrap.sh` |
<!-- loopex:current-status:end -->"""
REGISTER = """<!-- loopex:milestone-register:start -->
## Milestone Register

| Milestone | State | Concept | Technical depth | Gate |
| --- | --- | --- | --- | --- |
| `M0` | Blocked | — | — | — |
<!-- loopex:milestone-register:end -->"""
README = f"""# Loopex

<!-- loopex:readme-status:start -->
## Where Things Stand

{SUMMARY}

[Canonical milestone status and plan records](docs/plans/)
<!-- loopex:readme-status:end -->
"""
REJOIN = """```text
durable local session and operation truth
-> multi-client attachment and protocol candidate
```"""
GATE = "# Gate\n"
GATE_SEPARATORS = (
    "\r\n",
    "\r",
    "\v",
    "\f",
    "\x1c",
    "\x1d",
    "\x1e",
    "\x85",
    "\u2028",
    "\u2029",
)
PLAN_PREAMBLE = """<a id="concept"></a>
## Concept

Technical depth: [Milestone technical depth](M0-technical.md#technical-depth)
"""
ENVELOPE = """<!-- loopex:plan-concept-envelope:start -->
## Normative Concept Envelope

<a id="concept-plan-purpose"></a>
### Purpose

Prove one bounded behavior.

<a id="concept-plan-outcomes"></a>
### Outcomes

| # | Outcome | Evidence class | Gate selector |
| --- | --- | --- | --- |
| 1 | One bounded outcome | focused test | `test/example_test.exs` |

Technical depth: [Evidence obligations and mapping](M0-technical.md#technical-plan-evidence)

<a id="concept-plan-scope"></a>
### Scope

Only the bounded outcome.

Technical depth: [Prerequisites and acceptance points](M0-technical.md#technical-plan-prerequisites)
Technical depth: [Ownership and rejoin barriers](M0-technical.md#technical-plan-ownership)
Technical depth: [Compatibility mechanics](M0-technical.md#technical-plan-compatibility)
Technical depth: [Migration and rollback](M0-technical.md#technical-plan-migration)
Technical depth: [Packaging mechanics](M0-technical.md#technical-plan-packaging)
Technical depth: [Proportional minimalism budget](M0-technical.md#technical-plan-minimalism)

<a id="concept-plan-non-goals"></a>
### Non-Goals

No public freeze.

Technical depth: [Deferral acceptance points](M0-technical.md#technical-plan-prerequisites)
<!-- loopex:plan-concept-envelope:end -->"""

TECHNICAL_PLAN = """<a id="technical-depth"></a>
## Technical depth

Concept: [Milestone concept](M0.md#concept)

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Milestone scope](M0.md#concept-plan-scope)
Concept: [Milestone non-goals](M0.md#concept-plan-non-goals)

Prerequisites are accepted before plan acceptance.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Milestone scope](M0.md#concept-plan-scope)

The maintainer owns decisions; there is one serial rejoin.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Milestone outcomes](M0.md#concept-plan-outcomes)

Outcome 1 maps to the named focused test.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Milestone scope](M0.md#concept-plan-scope)

No compatibility claim.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Milestone scope](M0.md#concept-plan-scope)

Rollback removes the candidate.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](M0.md#concept-plan-scope)

No package or release.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Milestone scope](M0.md#concept-plan-scope)

Use direct code; add no abstraction without two concrete examples.
<!-- loopex:plan-technical-envelope:end -->
"""

ADR_PATHS = (
    "docs/adr/0001-repository-and-application-layout.md",
    "docs/adr/0002-bootstrap-runtime-floor.md",
)


def adr_technical(number: int) -> str:
    concept_name = ADR_PATHS[number - 1].removeprefix("docs/adr/")
    return f"""# 000{number}. Decision {number}: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Decision]({concept_name}#concept)

Exact constraints for decision {number}.
"""


def adr(number: int, accepted: bool = False) -> str:
    path = ADR_PATHS[number - 1]
    technical_name = path.removeprefix("docs/adr/").removesuffix(".md") + "-technical.md"
    proposal = f"""# 000{number}. Decision {number}

<a id="concept"></a>
## Concept

Technical depth: [Decision details]({technical_name}#technical-depth)

- **Status:** Proposed
- **Date:** 2026-08-15
- **Decision owner:** Maintainer

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

## Context

Concrete decision context for {path}.

## Decision

Choose the bounded decision.
"""
    if not accepted:
        return proposal
    candidate = ("d" if number == 1 else "e") * 40
    concept_digest = hashlib.sha256(proposal.encode()).hexdigest()
    technical_digest = hashlib.sha256(adr_technical(number).encode()).hexdigest()
    return proposal.replace("- **Status:** Proposed", "- **Status:** Accepted").replace(
        "| Acceptance | — | — | — |",
        "| Acceptance | Maintainer | [disposition](../vision.md#concept) | "
        f"candidate `{candidate}`; concept `sha256:{concept_digest}`; "
        f"technical `sha256:{technical_digest}` |",
    )


def documents() -> dict[str, str]:
    result = {
        "README.md": README,
        "docs/README.md": """# Documentation

[Root](../README.md)
[Developer](developer/README.md)
[Decisions](adr/README.md)
[Plans](plans/README.md)
[Vision](vision.md#concept)
[Vision technical](vision-technical.md#technical-depth)
[Roadmap](roadmap.md#concept)
[Roadmap technical](roadmap-technical.md#technical-depth)
[Development charter](developer/development-charter.md#concept)
[Development charter technical](developer/development-charter-technical.md#technical-depth)
[ADR 0001](adr/0001-repository-and-application-layout.md#concept)
[ADR 0001 technical](adr/0001-repository-and-application-layout-technical.md#technical-depth)
[ADR 0002](adr/0002-bootstrap-runtime-floor.md#concept)
[ADR 0002 technical](adr/0002-bootstrap-runtime-floor-technical.md#technical-depth)
""",
        "docs/plans/README.md": (
            f"# Plans\n\n[Documentation](../README.md)\n\n{CURRENT}\n\n{REGISTER}\n"
        ),
        "docs/adr/README.md": "# Decisions\n\n[Documentation](../README.md)\n",
        "docs/developer/README.md": (
            "# Developer documentation\n\n[Documentation](../README.md)\n"
        ),
        "docs/vision.md": (
            "# Vision\n\n<a id=\"concept\"></a>\n## Concept\n\n"
            "Technical depth: [Vision details](vision-technical.md#technical-depth)\n"
        ),
        "docs/vision-technical.md": (
            "# Vision: Technical depth\n\n<a id=\"technical-depth\"></a>\n"
            "## Technical depth\n\nConcept: [Vision](vision.md#concept)\n\n"
            "## 22. Ownership and serial barriers\n\n"
            f"<!-- loopex:rejoin-source:start -->\n{REJOIN}\n<!-- loopex:rejoin-source:end -->\n"
        ),
        "docs/roadmap.md": (
            "# Roadmap\n\n<a id=\"concept\"></a>\n## Concept\n\n"
            "Technical depth: [Roadmap details](roadmap-technical.md#technical-depth)\n"
        ),
        "docs/roadmap-technical.md": (
            "# Roadmap: Technical depth\n\n<a id=\"technical-depth\"></a>\n"
            "## Technical depth\n\nConcept: [Roadmap](roadmap.md#concept)\n\n"
            "## The Enduring Rejoin Order\n\n"
            f"<!-- loopex:rejoin-copy:start -->\n{REJOIN}\n<!-- loopex:rejoin-copy:end -->\n"
        ),
        "docs/developer/development-charter.md": (
            "# Development charter\n\n<a id=\"concept\"></a>\n"
            "## Concept\n\nTechnical depth: [Charter mechanics]"
            "(development-charter-technical.md#technical-depth)\n"
        ),
        "docs/developer/development-charter-technical.md": (
            "# Development charter: Technical depth\n\n"
            "<a id=\"technical-depth\"></a>\n## Technical depth\n\n"
            "Concept: [Development charter](development-charter.md#concept)\n"
        ),
        "docs/developer/agent-context-map.md": (
            "# Context map\n\n[Product definition]"
            "(../vision.md#concept)\n"
        ),
    }
    for index, path in enumerate(ADR_PATHS, 1):
        result[path] = adr(index)
        result[path.removesuffix(".md") + "-technical.md"] = adr_technical(index)
    return result


def _plan_text(acceptance: str, closure: str, progress_state: str) -> str:
    return f"""{PLAN_PREAMBLE}
{ENVELOPE}

## Workstreams

One direct workstream.

## Progress and Evidence

| # | State | Evidence |
| --- | --- | --- |
| 1 | {progress_state} | — |

## Governance Records

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | {acceptance} |
| Closure | {closure} |
"""


def fixture_envelope_digest(text: str, start: str, end: str) -> str:
    lines = text.splitlines()
    body = lines[lines.index(start) + 1 : lines.index(end)]
    return hashlib.sha256("\n".join(body).encode()).hexdigest()


def plan(
    governed: bool = False,
    closed: bool = False,
    gate: str = GATE,
    progress: str | None = None,
) -> str:
    progress_state = progress or ("Proved" if closed else "Open")
    empty = "— | — | —"
    concept_digest = fixture_envelope_digest(
        ENVELOPE,
        "<!-- loopex:plan-concept-envelope:start -->",
        "<!-- loopex:plan-concept-envelope:end -->",
    )
    technical_digest = fixture_envelope_digest(
        TECHNICAL_PLAN,
        "<!-- loopex:plan-technical-envelope:start -->",
        "<!-- loopex:plan-technical-envelope:end -->",
    )
    gate_digest = hashlib.sha256(gate.encode()).hexdigest()
    acceptance_bound = (
        f"candidate `{'a' * 40}`; "
        f"concept `sha256:{concept_digest}`; "
        f"technical `sha256:{technical_digest}`; gate `sha256:{gate_digest}`"
    )
    acceptance = (
        f"Maintainer | [disposition](../vision.md#concept) | {acceptance_bound}"
        if governed
        else empty
    )
    closure_bound = (
        f"candidate `{'c' * 40}`; "
        f"concept `sha256:{concept_digest}`; "
        f"technical `sha256:{technical_digest}`; gate `sha256:{gate_digest}`"
    )
    closure = (
        f"Maintainer | [disposition](../roadmap.md#concept) | {closure_bound}"
        if closed
        else empty
    )
    return _plan_text(acceptance, closure, progress_state)


def plan_snapshot(concept: str, gate: str | None = None, technical: str = TECHNICAL_PLAN) -> dict[str, str]:
    result = {
        "docs/plans/M0.md": concept,
        "docs/plans/M0-technical.md": technical,
    }
    if gate is not None:
        result["docs/plans/M0-gate.md"] = gate
    return result


def adr_snapshot(number: int, concept: str) -> dict[str, str]:
    path = ADR_PATHS[number - 1]
    return {
        path: concept,
        path.removesuffix(".md") + "-technical.md": adr_technical(number),
    }


def checked(
    docs: dict[str, str],
    historical_gate: str = GATE,
    plan_history: tuple[tuple[str, dict[str, str]], ...] = (),
    read_artifact=None,
) -> list[str]:
    snapshots: list[tuple[str, tuple[str, ...], dict[str, str]]] = [
        ("fixture-root", (), {})
    ]
    parent = "fixture-root"
    for revision, plans in plan_history:
        snapshots.append((revision, (parent,), plans))
        parent = revision
    def resolve(sha: str, path: str) -> str | None:
        if path.endswith("M0-gate.md") and sha in {"a" * 40, "b" * 40, "c" * 40}:
            return historical_gate
        if path.endswith("M0-technical.md") and sha in {"a" * 40, "b" * 40, "c" * 40}:
            return TECHNICAL_PLAN
        if path.endswith("M0.md"):
            if sha in {"a" * 40, "b" * 40}:
                return plan(False)
            if sha == "c" * 40:
                return plan(True, progress="Proved")
        if path == ADR_PATHS[0] and sha == "d" * 40:
            return adr(1)
        if path == ADR_PATHS[0].removesuffix(".md") + "-technical.md" and sha == "d" * 40:
            return adr_technical(1)
        if path == ADR_PATHS[1] and sha == "e" * 40:
            return adr(2)
        if path == ADR_PATHS[1].removesuffix(".md") + "-technical.md" and sha == "e" * 40:
            return adr_technical(2)
        return None

    return validate(
        docs,
        resolve,
        lambda: (parent, tuple(snapshots)),
        read_artifact=read_artifact,
    )


def accepted_adr_documents(*accepted: int) -> dict[str, str]:
    docs = documents()
    for number in accepted:
        docs[ADR_PATHS[number - 1]] = adr(number, True)
    unresolved = [number for number in (1, 2) if number not in accepted]
    if len(unresolved) == 1:
        number = unresolved[0]
        filename = ADR_PATHS[number - 1].removeprefix("docs/adr/")
        docs["docs/plans/README.md"] = docs["docs/plans/README.md"].replace(
            "[ADR 0001](../adr/0001-repository-and-application-layout.md#concept) and "
            "[ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) must be accepted before "
            "M0 opens; a replacement requires a governed guard change",
            f"[ADR 000{number}](../adr/{filename}#concept) must be accepted before M0 opens; "
            "a replacement requires a governed guard change",
        ).replace(
            "Disposition ADR 0001 and ADR 0002", f"Disposition ADR 000{number}"
        )
    elif not unresolved:
        docs["docs/plans/README.md"] = docs["docs/plans/README.md"].replace(
            "[ADR 0001](../adr/0001-repository-and-application-layout.md#concept) and "
            "[ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) must be accepted before "
            "M0 opens; a replacement requires a governed guard change",
            "M0 has not been explicitly opened gate-first",
        ).replace(
            "Disposition ADR 0001 and ADR 0002", "Explicitly open or defer M0"
        ).replace(
            "After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first",
            "Create the branch-only M0 Concept plan, Technical depth plan, and red gate; "
            "install lifecycle-specific status checks; and move M0 to Open",
        )
    return docs


OPEN_SUMMARY = (
    "**Revision status:** Pre-implementation planning; active milestone "
    "`M0` is open; no next candidate is recorded."
)


def _open_capsule(text: str) -> str:
    """Rewrite the blocked capsule into its derived Open form."""
    return (
        text.replace(
            "| Blockers | [ADR 0001](../adr/0001-repository-and-application-layout.md#concept) and [ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) must be accepted before M0 opens; a replacement requires a governed guard change |",
            "| Blockers | `M0` is open and not accepted; the recorded acceptance "
            "authority must accept both normative envelopes and the gate |",
        )
        .replace(
            "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |",
            "| Next maintainer decision | Accept or reject the `M0` plan pair and gate |",
        )
        .replace(
            "| Next transition | After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first |",
            "| Next transition | Record the acceptance governance row and move `M0` to Accepted |",
        )
    )


class StatusTest(unittest.TestCase):
    def assert_invalid(self, docs: dict[str, str], fragment: str = "") -> None:
        errors = checked(docs)
        self.assertTrue(errors, "mutation unexpectedly passed")
        if fragment:
            self.assertIn(fragment, errors[0])

    def test_current_fixture_and_input_are_unchanged(self) -> None:
        docs = documents()
        before = copy.deepcopy(docs)
        self.assertEqual([], checked(docs))
        self.assertEqual(before, docs)

    def test_pair_topology_links_and_anchors_fail_closed(self) -> None:
        cases: list[tuple[str, callable, str]] = [
            (
                "missing companion",
                lambda docs: docs.pop("docs/vision-technical.md"),
                "paired technical document is missing",
            ),
            (
                "orphan companion",
                lambda docs: docs.pop("docs/vision.md"),
                "paired concept document is missing",
            ),
            (
                "hidden heading",
                lambda docs: docs.__setitem__(
                    "docs/vision.md",
                    docs["docs/vision.md"].replace(
                        "## Concept", "<!--\n## Concept\n-->", 1
                    ),
                ),
                "visible ## Concept",
            ),
            (
                "duplicate heading",
                lambda docs: docs.__setitem__(
                    "docs/vision.md", docs["docs/vision.md"] + "\n## Concept\n"
                ),
                "exactly one visible",
            ),
            (
                "duplicate heading with trailing spaces",
                lambda docs: docs.__setitem__(
                    "docs/vision.md", docs["docs/vision.md"] + "\n## Concept   \n"
                ),
                "exactly one visible",
            ),
            (
                "duplicate heading with closing hashes",
                lambda docs: docs.__setitem__(
                    "docs/vision.md", docs["docs/vision.md"] + "\n## Concept ##\n"
                ),
                "exactly one visible",
            ),
            (
                "duplicate setext heading",
                lambda docs: docs.__setitem__(
                    "docs/vision.md", docs["docs/vision.md"] + "\nConcept\n---\n"
                ),
                "exactly one visible",
            ),
            (
                "hidden anchor",
                lambda docs: docs.__setitem__(
                    "docs/vision.md",
                    docs["docs/vision.md"].replace(
                        '<a id="concept"></a>',
                        '<!-- <a id="concept"></a> -->',
                    ),
                ),
                "relationship anchor",
            ),
            (
                "duplicate anchor",
                lambda docs: docs.__setitem__(
                    "docs/vision.md",
                    docs["docs/vision.md"] + '\n<a id="concept"></a>\n',
                ),
                "exactly once",
            ),
            (
                "wrong companion",
                lambda docs: docs.__setitem__(
                    "docs/vision.md",
                    docs["docs/vision.md"].replace(
                        "vision-technical.md#technical-depth",
                        "roadmap-technical.md#technical-depth",
                    ),
                ),
                "own companion",
            ),
            (
                "empty fragment",
                lambda docs: docs.__setitem__(
                    "docs/vision.md",
                    docs["docs/vision.md"].replace(
                        "#technical-depth", "#"
                    ),
                ),
                "nonempty fragment",
            ),
            (
                "unknown fragment",
                lambda docs: docs.__setitem__(
                    "docs/vision.md",
                    docs["docs/vision.md"].replace(
                        "#technical-depth", "#technical-missing"
                    ),
                ),
                "does not resolve",
            ),
            (
                "nonreciprocal backlink",
                lambda docs: docs.__setitem__(
                    "docs/vision-technical.md",
                    docs["docs/vision-technical.md"].replace(
                        "vision.md#concept", "vision.md#concept-other"
                    ),
                )
                or docs.__setitem__(
                    "docs/vision.md",
                    docs["docs/vision.md"]
                    + '\n<a id="concept-other"></a>\n### Other concept\n',
                ),
                "not reciprocal",
            ),
            (
                "wrong depth label",
                lambda docs: docs.__setitem__(
                    "docs/vision-technical.md",
                    docs["docs/vision-technical.md"]
                    + "\nTechnical depth: [Wrong direction]"
                    "(vision.md#concept).\n",
                ),
                "belongs in the other depth",
            ),
            (
                "visible preamble before relationship",
                lambda docs: docs.__setitem__(
                    "docs/vision.md", "Unexpected preamble.\n\n" + docs["docs/vision.md"]
                ),
                "must start with an optional H1",
            ),
            (
                "section before relationship",
                lambda docs: docs.__setitem__(
                    "docs/vision.md",
                    docs["docs/vision.md"].replace(
                        '<a id="concept"></a>',
                        "## Earlier section\n\nText.\n\n<a id=\"concept\"></a>",
                        1,
                    ),
                ),
                "must start with an optional H1",
            ),
            (
                "fenced preamble before relationship",
                lambda docs: docs.__setitem__(
                    "docs/vision.md",
                    "```text\nHidden preamble.\n```\n\n" + docs["docs/vision.md"],
                ),
                "must start with an optional H1",
            ),
            (
                "empty optional title",
                lambda docs: docs.__setitem__(
                    "docs/vision.md", docs["docs/vision.md"].replace("# Vision", "#", 1)
                ),
                "must start with an optional H1",
            ),
        ]
        for label, mutate, error in cases:
            with self.subTest(label=label):
                docs = documents()
                mutate(docs)
                self.assert_invalid(docs, error)

        docs = documents()
        docs["docs/vision.md"] += (
            '\n<a id="concept-effects"></a>\n### Effects\n\n'
            "Technical depth: [Effect ordering]"
            "(vision-technical.md#technical-effects)\n"
        )
        docs["docs/vision-technical.md"] += (
            '\n<a id="technical-effects"></a>\n### Effect ordering\n\n'
            "Concept: [Effects](vision.md#concept-effects)\n"
        )
        self.assertEqual([], checked(docs))
        docs["docs/vision.md"] = docs["docs/vision.md"].replace(
            "vision-technical.md#technical-effects",
            "roadmap-technical.md#technical-depth",
        )
        self.assert_invalid(docs, "only its companion")

        docs = documents()
        docs["docs/developer/agent-context-map.md"] = docs[
            "docs/developer/agent-context-map.md"
        ].replace("#concept", "#concept-does-not-exist")
        self.assert_invalid(docs, "fragment does not resolve")

        for link, error in (
            ('[broken](missing.md "title")', "unsupported Markdown link syntax"),
            ('[broken](<missing file.md>)', "raw HTML"),
            ('[broken][target]\n\n[target]: missing.md', "unsupported Markdown link syntax"),
            ('[broken](missing.md?x=1)', "unsupported local Markdown query"),
            ('[](docs/vision.md#concept)', "unsupported Markdown link syntax"),
            ('![](missing.md)', "unsupported Markdown image syntax"),
            ('![broken](missing.md)', "unsupported Markdown image syntax"),
            ('[a [nested]](missing.md)', "unsupported Markdown link syntax"),
        ):
            with self.subTest(link=link):
                docs = documents()
                docs["README.md"] += f"\n{link}\n"
                self.assert_invalid(docs, error)

    def test_documentation_directories_are_indexed(self) -> None:
        """A document reachable only by knowing it exists is not documented."""
        docs = documents()
        docs["docs/operator/recovery.md"] = "# Recovery runbook\n"
        self.assert_invalid(
            docs, "docs/operator: directory with Markdown needs a README.md index"
        )

        docs = documents()
        docs["docs/operator/recovery.md"] = "# Recovery runbook\n"
        docs["docs/operator/README.md"] = "# Operator\n\n[Documentation](../README.md)\n"
        self.assert_invalid(docs, "must link the docs/operator/ index")

        docs = documents()
        docs["docs/operator/recovery.md"] = "# Recovery runbook\n"
        docs["docs/operator/README.md"] = "# Operator\n"
        docs["docs/README.md"] += "[Operator](operator/README.md)\n"
        self.assert_invalid(
            docs, "docs/operator/README.md: must link back to docs/README.md"
        )

        docs = documents()
        docs["docs/README.md"] = docs["docs/README.md"].replace("[Root](../README.md)\n", "")
        self.assert_invalid(docs, "docs/README.md: must link back to the root README.md")

        docs = documents()
        docs["docs/operator/recovery.md"] = "# Recovery runbook\n"
        docs["docs/operator/README.md"] = "# Operator\n\n[Documentation](../README.md)\n"
        docs["docs/README.md"] += "[Operator](operator/README.md)\n"
        self.assertEqual([], checked(docs))

    def test_markdown_classification_rejects_ambiguous_paths(self) -> None:
        for path, error in (
            ("docs/unknown.md", "paired technical document is missing"),
            ("OTHER.md", "unknown active"),
            ("docs/vision-technical-technical.md", "doubled technical suffix"),
            ("Docs/VISION.md", "collides by case"),
            ("docs/adr/0003-new-decision.md", "paired technical document is missing"),
            ("docs/plans/sample-technical.md", "exact triples"),
            ("docs/plans/sample-technical-technical.md", "doubled technical suffix"),
        ):
            with self.subTest(path=path):
                docs = documents()
                docs[path] = "# Unexpected\n"
                self.assert_invalid(docs, error)

        docs = documents()
        docs[".agents/skills/example/SKILL.md"] = "# Portable skill\n"
        docs[".claude/agents/example.md"] = "# Client role prompt\n"
        docs[".github/ISSUE_TEMPLATE/bug.md"] = "# Issue template\n"
        docs["docs/archive/old.md"] = "# Historical bytes\n"
        docs["docs/operator/recovery.md"] = "# Recovery runbook\n"
        docs["docs/archive/README.md"] = "# Archive\n\n[Documentation](../README.md)\n"
        docs["docs/operator/README.md"] = "# Operator\n\n[Documentation](../README.md)\n"
        docs["docs/README.md"] += "[Archive](archive/README.md)\n[Operator](operator/README.md)\n"
        self.assertEqual([], checked(docs))

        for path in (
            ".agents/policy.md",
            ".claude/policy.md",
            ".codex/policy.md",
            ".github/policy.md",
        ):
            with self.subTest(path=path):
                docs = documents()
                docs[path] = "# Hidden policy\n"
                self.assert_invalid(docs, "unknown active Markdown document class")

        docs = documents()
        docs["docs/architecture.md"] = (
            '<a id="concept"></a>\n## Concept\n\n'
            "Technical depth: [Architecture mechanics]"
            "(architecture-technical.md#technical-depth)\n"
        )
        docs["docs/architecture-technical.md"] = (
            '<a id="technical-depth"></a>\n## Technical depth\n\n'
            "Concept: [Architecture](architecture.md#concept)\n"
        )
        self.assert_invalid(docs, "missing from the index")
        docs["docs/README.md"] += (
            "\n[Architecture](architecture.md#concept)\n"
            "[Architecture technical](architecture-technical.md#technical-depth)\n"
        )
        self.assertEqual([], checked(docs))

    def test_adr_acceptance_is_bound_and_drives_the_blocked_capsule(self) -> None:
        for accepted in ((), (1,), (2,), (1, 2)):
            with self.subTest(accepted=accepted):
                self.assertEqual([], checked(accepted_adr_documents(*accepted)))

        docs = accepted_adr_documents(1)
        docs[ADR_PATHS[0]] = docs[ADR_PATHS[0]].replace(
            "Choose the bounded decision.", "Rewrite the accepted decision."
        )
        self.assert_invalid(docs, "historical candidate")

        docs = accepted_adr_documents(1)
        docs[ADR_PATHS[0]] = docs[ADR_PATHS[0]].replace("d" * 40, "f" * 40)
        self.assert_invalid(docs, "candidate")

        docs = accepted_adr_documents(1)
        technical_path = ADR_PATHS[0].removesuffix(".md") + "-technical.md"
        docs[technical_path] = docs[technical_path].replace(
            "Exact constraints", "Changed constraints"
        )
        self.assert_invalid(docs, "accepted ADR technical depth differs")

        docs = accepted_adr_documents(1)
        technical_digest = hashlib.sha256(adr_technical(1).encode()).hexdigest()
        docs[ADR_PATHS[0]] = docs[ADR_PATHS[0]].replace(
            technical_digest, "f" * 64
        )
        self.assert_invalid(docs, "ADR technical digest")

    def test_plan_envelope_and_candidate_shapes_are_locked(self) -> None:
        _validate_pair(
            {
                "docs/plans/M0.md": plan(False),
                "docs/plans/M0-technical.md": TECHNICAL_PLAN,
            },
            "docs/plans/M0.md",
        )
        with self.assertRaisesRegex(Exception, "not reciprocal"):
            _validate_pair(
                {
                    "docs/plans/M0.md": plan(False),
                    "docs/plans/M0-technical.md": TECHNICAL_PLAN.replace(
                        "Concept: [Milestone outcomes](M0.md#concept-plan-outcomes)",
                        "Concept: [Milestone outcomes](M0.md#concept-plan-scope)",
                    ),
                },
                "docs/plans/M0.md",
            )

        resolve = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else TECHNICAL_PLAN
            if path.endswith("M0-technical.md")
            else plan(False)
            if sha == "a" * 40
            else plan(True, progress="Proved")
            if sha == "c" * 40
            else None
        )
        _governance(plan(True), TECHNICAL_PLAN, GATE, "M0", "Accepted", resolve)
        _governance(plan(True, True), TECHNICAL_PLAN, GATE, "M0", "Closed", resolve)

        with self.assertRaisesRegex(Exception, "concrete commitment"):
            _plan_concept_envelope(
                plan(False).replace("Only the bounded outcome.\n", "", 1),
                "docs/plans/M0.md",
            )
        with self.assertRaisesRegex(Exception, "concrete commitment"):
            _plan_concept_envelope(
                plan(False).replace("No public freeze.\n", "", 1),
                "docs/plans/M0.md",
            )
        with self.assertRaisesRegex(Exception, "concrete commitment"):
            _plan_technical_envelope(
                TECHNICAL_PLAN.replace(
                    "Prerequisites are accepted before plan acceptance.\n", "", 1
                ),
                "docs/plans/M0-technical.md",
            )

        mutable = plan(True).replace("One direct workstream.", "Two direct workstreams.").replace(
            "| 1 | Open | — |", "| 1 | Proved | [run](evidence.md) |"
        )
        _governance(mutable, TECHNICAL_PLAN, GATE, "M0", "Accepted", resolve)

        for heading in (
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
        ):
            with self.subTest(heading=heading):
                concept_heading = heading in {
                    "### Purpose",
                    "### Outcomes",
                    "### Scope",
                    "### Non-Goals",
                }
                changed = plan(True).replace(heading, heading + " changed", 1)
                changed_technical = TECHNICAL_PLAN.replace(
                    heading, heading + " changed", 1
                )
                with self.assertRaisesRegex(Exception, "headings"):
                    _governance(
                        changed if concept_heading else plan(True),
                        TECHNICAL_PLAN if concept_heading else changed_technical,
                        GATE,
                        "M0",
                        "Accepted",
                        resolve,
                    )

        for label, changed in (
            (
                "missing marker",
                plan(True).replace("<!-- loopex:plan-concept-envelope:start -->\n", "", 1),
            ),
            (
                "duplicate marker",
                plan(True) + "\n<!-- loopex:plan-concept-envelope:start -->\n",
            ),
            (
                "hidden marker",
                plan(True).replace(
                    "<!-- loopex:plan-concept-envelope:start -->",
                    "<!--\n<!-- loopex:plan-concept-envelope:start -->\n-->",
                    1,
                ),
            ),
            (
                "empty section",
                plan(True).replace(
                    "### Scope\n\nOnly the bounded outcome.", "### Scope\n", 1
                ),
            ),
            (
                "bad outcomes",
                plan(True).replace("| 1 | One bounded outcome", "| 2 | One bounded outcome"),
            ),
            (
                "setext heading",
                plan(True).replace(
                    "Only the bounded outcome.", "Only the bounded outcome.\n---"
                ),
            ),
            (
                "missing section anchor",
                plan(True).replace('<a id="concept-plan-scope"></a>\n', "", 1),
            ),
            (
                "missing section mapping",
                plan(True).replace(
                    "Technical depth: [Packaging mechanics]"
                    "(M0-technical.md#technical-plan-packaging)\n",
                    "",
                    1,
                ),
            ),
        ):
            with self.subTest(label=label):
                with self.assertRaises(Exception):
                    _governance(changed, TECHNICAL_PLAN, GATE, "M0", "Accepted", resolve)

        candidate_with_completed_acceptance = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else TECHNICAL_PLAN
            if path.endswith("M0-technical.md")
            else plan(True)
        )
        with self.assertRaisesRegex(Exception, "concept digest|candidate.*governance"):
            _governance(
                plan(True),
                TECHNICAL_PLAN,
                GATE,
                "M0",
                "Accepted",
                candidate_with_completed_acceptance,
            )

        candidate_without_progress = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else TECHNICAL_PLAN
            if path.endswith("M0-technical.md")
            else plan(False).replace("## Progress and Evidence", "## Progress")
        )
        with self.assertRaisesRegex(Exception, "plan document|Progress and Evidence|concept digest"):
            _governance(
                plan(True), TECHNICAL_PLAN, GATE, "M0", "Accepted", candidate_without_progress
            )

        closure_without_acceptance = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else TECHNICAL_PLAN
            if path.endswith("M0-technical.md")
            else plan(False, progress="Proved")
        )
        with self.assertRaisesRegex(Exception, "closure candidate|concept digest"):
            _governance(
                plan(True, True),
                TECHNICAL_PLAN,
                GATE,
                "M0",
                "Closed",
                closure_without_acceptance,
            )

        closure_with_open_progress = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else TECHNICAL_PLAN
            if path.endswith("M0-technical.md")
            else plan(False)
            if sha == "a" * 40
            else plan(True)
        )
        with self.assertRaisesRegex(Exception, "no Open|concept digest"):
            _governance(
                plan(True, True),
                TECHNICAL_PLAN,
                GATE,
                "M0",
                "Closed",
                closure_with_open_progress,
            )

        different_candidate = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else TECHNICAL_PLAN
            if path.endswith("M0-technical.md")
            else plan(False).replace("Only the bounded outcome.", "Different scope.")
        )
        with self.assertRaisesRegex(Exception, "differs from its candidate|concept digest"):
            _governance(
                plan(True), TECHNICAL_PLAN, GATE, "M0", "Accepted", different_candidate
            )

        different_closure = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else TECHNICAL_PLAN
            if path.endswith("M0-technical.md")
            else plan(False)
            if sha == "a" * 40
            else plan(True, progress="Proved").replace(
                "Only the bounded outcome.", "Different scope."
            )
        )
        with self.assertRaisesRegex(Exception, "closure candidate changed|concept digest"):
            _governance(
                plan(True, True), TECHNICAL_PLAN, GATE, "M0", "Closed", different_closure
            )

        with self.assertRaisesRegex(Exception, "normative technical envelope|technical digest"):
            _governance(
                plan(True),
                TECHNICAL_PLAN.replace("No compatibility claim.", "Changed compatibility."),
                GATE,
                "M0",
                "Accepted",
                resolve,
            )

        technical_digest = fixture_envelope_digest(
            TECHNICAL_PLAN,
            "<!-- loopex:plan-technical-envelope:start -->",
            "<!-- loopex:plan-technical-envelope:end -->",
        )
        with self.assertRaisesRegex(Exception, "technical digest"):
            _governance(
                plan(True).replace(technical_digest, "f" * 64),
                TECHNICAL_PLAN,
                GATE,
                "M0",
                "Accepted",
                resolve,
            )

    def test_progress_table_is_total_and_lifecycle_aware(self) -> None:
        def invalid(text: str, state: str, fragment: str) -> None:
            with self.assertRaisesRegex(Exception, fragment):
                _governance(text, TECHNICAL_PLAN, GATE, "M0", state, lambda sha, path: None)

        for label, text in (
            (
                "missing",
                plan(False).replace(
                    "## Progress and Evidence\n\n| # | State | Evidence |\n"
                    "| --- | --- | --- |\n| 1 | Open | — |\n",
                    "",
                ),
            ),
            ("duplicate", plan(False) + "\n## Progress and Evidence\n"),
            (
                "invalid state",
                plan(False).replace("| 1 | Open | — |", "| 1 | Done | — |"),
            ),
            (
                "extra outcome",
                plan(False).replace(
                    "| 1 | Open | — |", "| 1 | Open | — |\n| 2 | Open | — |"
                ),
            ),
            (
                "missing outcome",
                plan(False).replace(
                    "| 1 | One bounded outcome | focused test | `test/example_test.exs` |",
                    "| 1 | One bounded outcome | focused test | `test/example_test.exs` |\n"
                    "| 2 | Another outcome | focused test | `test/another_test.exs` |",
                ),
            ),
            (
                "duplicate outcome",
                plan(False).replace(
                    "| 1 | Open | — |", "| 1 | Open | — |\n| 1 | Proved | evidence |"
                ),
            ),
        ):
            with self.subTest(label=label):
                invalid(text, "Open", "plan document|Progress and Evidence")

        for state in ("Accepted limitation", "Accepted deferral"):
            with self.subTest(state=state):
                invalid(
                    plan(False).replace("| 1 | Open | — |", f"| 1 | {state} | — |"),
                    "Open",
                    "disposition evidence",
                )
                _governance(
                    plan(False).replace(
                        "| 1 | Open | — |",
                        f"| 1 | {state} | [disposition](decision.md) |",
                    ),
                    TECHNICAL_PLAN,
                    GATE,
                    "M0",
                    "Open",
                    lambda sha, path: None,
                )

                for bad_evidence in ("evidence.md", "[decision](decision.md)"):
                    invalid(
                        plan(False).replace(
                            "| 1 | Open | — |",
                            f"| 1 | {state} | {bad_evidence} |",
                        ),
                        "Open",
                        "disposition evidence",
                    )

        invalid(
            plan(True, True).replace("| 1 | Proved | — |", "| 1 | Open | pending |"),
            "Closed",
            "no Open",
        )

    def test_plan_document_has_no_second_normative_surface(self) -> None:
        mutations = (
            ("identity heading", "# M0\n\n" + plan(False)),
            ("leading prose", "Plan identity M0.\n\n" + plan(False)),
            (
                "interstitial prose",
                plan(False).replace(
                    "<!-- loopex:plan-concept-envelope:end -->\n\n## Workstreams",
                    "<!-- loopex:plan-concept-envelope:end -->\n\nScope override.\n\n## Workstreams",
                ),
            ),
            (
                "second section",
                plan(False).replace(
                    "## Workstreams", "## Scope Override\n\nBroader work.\n\n## Workstreams"
                ),
            ),
        )
        for label, text in mutations:
            with self.subTest(label=label), self.assertRaisesRegex(
                Exception, "plan document|headings|Workstreams"
            ):
                _governance(text, TECHNICAL_PLAN, GATE, "M0", "Open", lambda sha, path: None)

        bad_candidate = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else TECHNICAL_PLAN
            if path.endswith("M0-technical.md")
            else plan(False).replace(
                "<!-- loopex:plan-concept-envelope:end -->\n\n## Workstreams",
                "<!-- loopex:plan-concept-envelope:end -->\n\nScope override.\n\n## Workstreams",
            )
        )
        with self.assertRaisesRegex(Exception, "Workstreams|concept digest"):
            _governance(plan(True), TECHNICAL_PLAN, GATE, "M0", "Accepted", bad_candidate)

        path = "docs/plans/M0.md"
        original = plan(True)
        bad_history = original.replace(
            "## Workstreams", "## Scope Override\n\nBroader work.\n\n## Workstreams"
        )
        history = (
            "accepted",
            (("root", (), {}), ("accepted", ("root",), plan_snapshot(original))),
        )
        with self.assertRaisesRegex(Exception, "headings|Workstreams"):
            _governance_history(plan_snapshot(bad_history), history)

    def test_plan_envelope_is_anchored_with_acceptance_history(self) -> None:
        path = "docs/plans/M0.md"
        original = plan(True)
        changed = original.replace("Only the bounded outcome.", "A larger scope.")
        history = (
            "accepted",
            (("root", (), {}), ("accepted", ("root",), plan_snapshot(original))),
        )
        progress_changed = original.replace(
            "| 1 | Open | — |", "| 1 | Proved | [run](evidence.md) |"
        )
        _governance_history(plan_snapshot(progress_changed), history)
        with self.assertRaisesRegex(Exception, "normative concept envelope"):
            _governance_history(plan_snapshot(changed), history)

        merge = (
            "merge",
            (
                ("root", (), {}),
                ("accepted", ("root",), plan_snapshot(original)),
                ("main", ("root",), {}),
                ("merge", ("main", "accepted"), plan_snapshot(changed)),
            ),
        )
        with self.assertRaisesRegex(Exception, "normative concept envelope"):
            _governance_history(plan_snapshot(changed), merge)

    def test_accepted_adr_history_is_anchored_through_merges(self) -> None:
        path = ADR_PATHS[0]
        proposal = adr(1)
        accepted = adr(1, True)
        legacy = proposal.split("## Governance Record", 1)[0] + "## Context\n\nLegacy.\n"
        history = (
            "accepted",
            (
                ("legacy", (), {path: legacy}),
                ("proposal", ("legacy",), adr_snapshot(1, proposal)),
                ("accepted", ("proposal",), adr_snapshot(1, accepted)),
            ),
        )
        _governance_history(adr_snapshot(1, accepted), history)

        changed = accepted.replace(
            "Choose the bounded decision.", "Rewrite the accepted decision."
        )
        with self.assertRaisesRegex(Exception, "accepted concept"):
            _governance_history(adr_snapshot(1, changed), history)

        deleted = (
            "deleted",
            (*history[1], ("deleted", ("accepted",), {})),
        )
        with self.assertRaisesRegex(Exception, "disappeared"):
            _governance_history(adr_snapshot(1, accepted), deleted)

        merge = (
            "merge",
            (
                ("root", (), {}),
                ("accepted", ("root",), adr_snapshot(1, accepted)),
                ("main", ("root",), {}),
                ("merge", ("main", "accepted"), adr_snapshot(1, changed)),
            ),
        )
        with self.assertRaisesRegex(Exception, "accepted concept"):
            _governance_history(adr_snapshot(1, changed), merge)

        docs = documents()
        del docs[ADR_PATHS[1]]
        self.assert_invalid(docs, "unknown active")

    def test_paired_technical_history_rejects_restore_delete_and_merge_divergence(self) -> None:
        accepted = plan(True)
        changed_technical = TECHNICAL_PLAN.replace(
            "No compatibility claim.", "A different compatibility claim."
        )
        accepted_snapshot = plan_snapshot(accepted, GATE)
        history = (
            "accepted",
            (
                ("root", (), {}),
                ("accepted", ("root",), accepted_snapshot),
            ),
        )
        with self.assertRaisesRegex(Exception, "normative technical envelope"):
            _governance_history(
                plan_snapshot(accepted, GATE, changed_technical), history
            )

        mutated = (
            "mutated",
            (
                *history[1],
                (
                    "mutated",
                    ("accepted",),
                    plan_snapshot(accepted, GATE, changed_technical),
                ),
            ),
        )
        with self.assertRaisesRegex(Exception, "normative technical envelope"):
            _governance_history(accepted_snapshot, mutated)

        without_technical = {
            "docs/plans/M0.md": accepted,
            "docs/plans/M0-gate.md": GATE,
        }
        deleted = (
            "deleted",
            (*history[1], ("deleted", ("accepted",), without_technical)),
        )
        with self.assertRaisesRegex(Exception, "technical depth disappeared"):
            _governance_history(accepted_snapshot, deleted)

        merged = (
            "merge",
            (
                ("root", (), {}),
                ("accepted", ("root",), accepted_snapshot),
                ("main", ("root",), {}),
                (
                    "merge",
                    ("main", "accepted"),
                    plan_snapshot(accepted, GATE, changed_technical),
                ),
            ),
        )
        with self.assertRaisesRegex(Exception, "normative technical envelope"):
            _governance_history(
                plan_snapshot(accepted, GATE, changed_technical), merged
            )

        open_history = (
            "open",
            (
                ("root", (), {}),
                ("open", ("root",), plan_snapshot(plan(False), GATE)),
            ),
        )
        _governance_history(
            plan_snapshot(plan(False), GATE, changed_technical), open_history
        )

        adr_path = ADR_PATHS[0]
        accepted_adr = adr(1, True)
        accepted_adr_snapshot = adr_snapshot(1, accepted_adr)
        adr_history = (
            "accepted-adr",
            (
                ("root", (), {}),
                ("accepted-adr", ("root",), accepted_adr_snapshot),
            ),
        )
        changed_adr_snapshot = dict(accepted_adr_snapshot)
        technical_path = adr_path.removesuffix(".md") + "-technical.md"
        changed_adr_snapshot[technical_path] = changed_adr_snapshot[technical_path].replace(
            "Exact constraints", "Different constraints"
        )
        with self.assertRaisesRegex(Exception, "accepted technical depth"):
            _governance_history(changed_adr_snapshot, adr_history)

        restored_adr_history = (
            "restored",
            (
                *adr_history[1],
                ("changed", ("accepted-adr",), changed_adr_snapshot),
            ),
        )
        with self.assertRaisesRegex(Exception, "accepted technical depth"):
            _governance_history(accepted_adr_snapshot, restored_adr_history)

    def test_git_resolver_requires_a_commit_object(self) -> None:
        root = Path(__file__).resolve().parents[1]
        tree = subprocess.check_output(
            ["git", "rev-parse", "HEAD^{tree}"], cwd=root, text=True
        ).strip()
        self.assertIsNone(_git_resolver(root)(tree, "README.md"))
        history = _git_plan_history(root)()
        self.assertIsNotNone(history)
        assert history is not None
        self.assertTrue(set(ADR_PATHS).issubset(history[1][-1][2]))

    def test_git_resolver_rejects_unreachable_commits_without_writes(self) -> None:
        root = Path(__file__).resolve().parents[1]
        unreachable = "f" * 40
        calls: list[tuple[str, ...]] = []

        def run(_root: Path, *args: str) -> subprocess.CompletedProcess[bytes]:
            calls.append(args)
            if args == ("cat-file", "-t", unreachable):
                return subprocess.CompletedProcess(args, 0, b"commit\n", b"")
            if args == ("merge-base", "--is-ancestor", unreachable, "HEAD"):
                return subprocess.CompletedProcess(args, 1, b"", b"")
            raise AssertionError(f"unexpected command: {args}")

        self.assertIsNone(_git_resolver(root, run)(unreachable, "README.md"))
        self.assertEqual(
            [
                ("cat-file", "-t", unreachable),
                ("merge-base", "--is-ancestor", unreachable, "HEAD"),
            ],
            calls,
        )

        head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True
        ).strip()
        self.assertIsNotNone(_git_resolver(root)(head, "README.md"))

    def test_open_and_closed_plans(self) -> None:
        for state, governed, closed in (("Open", False, False), ("Closed", True, True)):
            docs = documents()
            old_row = "| `M0` | Blocked | — | — | — |"
            new_row = (
                f"| `M0` | {state} | [concept](M0.md) | "
                "[technical depth](M0-technical.md) | [gate](M0-gate.md) |"
            )
            old_summary = SUMMARY
            if state == "Open":
                new_summary = "**Revision status:** Pre-implementation planning; active milestone `M0` is open; no next candidate is recorded."
            else:
                new_summary = "**Revision status:** Pre-implementation planning; no milestone is active; no next candidate is recorded."
            docs = {key: value.replace(old_row, new_row).replace(old_summary, new_summary) for key, value in docs.items()}
            if state == "Closed":
                docs["docs/plans/README.md"] = docs["docs/plans/README.md"].replace(
                    "Seed bootstrap — 2026-08-15", "`M0` — 2026-08-15"
                )
            docs["docs/plans/M0.md"] = plan(governed, closed)
            docs["docs/plans/M0-technical.md"] = TECHNICAL_PLAN
            docs["docs/plans/M0-gate.md"] = GATE
            if state == "Open":
                docs["docs/plans/README.md"] = _open_capsule(
                    docs["docs/plans/README.md"]
                )
                self.assertEqual([], checked(docs))
                stale = dict(docs)
                stale["docs/plans/README.md"] = stale["docs/plans/README.md"].replace(
                    "| Next maintainer decision | Accept or reject the `M0` plan pair and gate |",
                    "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |",
                )
                self.assert_invalid(stale, "exact derived status capsule")
            else:
                self.assert_invalid(docs, "no derived status capsule")

    def test_bound_artifacts_are_anchored_across_history(self) -> None:
        """Mutate-then-restore and merge divergence must both be caught."""
        good = "#!/usr/bin/env bash\nexit 1\n"
        bad = "#!/usr/bin/env bash\nexit 0\n"
        digest = hashlib.sha256(good.encode("utf-8")).hexdigest()
        gate = (
            "# Gate\n\n## Bound Artifacts\n\n"
            "| SHA-256 | Path |\n| --- | --- |\n"
            f"| `{digest}` | `scripts/run-gate.sh` |\n"
        )
        docs = documents()
        docs["docs/plans/README.md"] = _open_capsule(
            docs["docs/plans/README.md"]
            .replace(
                "| `M0` | Blocked | — | — | — |",
                "| `M0` | Open | [concept](M0.md) | "
                "[technical depth](M0-technical.md) | [gate](M0-gate.md) |",
            )
            .replace(SUMMARY, OPEN_SUMMARY)
        )
        docs["README.md"] = docs["README.md"].replace(SUMMARY, OPEN_SUMMARY)
        docs["docs/plans/M0.md"] = plan(False)
        docs["docs/plans/M0-technical.md"] = TECHNICAL_PLAN
        docs["docs/plans/M0-gate.md"] = gate

        def run(snapshots):
            return validate(
                docs,
                None,
                lambda: (snapshots[-1][0], tuple(snapshots)),
                read_artifact=lambda _: good.encode("utf-8"),
            )

        clean = [
            ("a" * 40, (), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": good}),
            ("b" * 40, ("a" * 40,), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": good}),
        ]
        self.assertEqual([], run(clean))

        # Mutate at one revision and restore at the next. The current tree is
        # clean, so only history can catch it.
        restored = [
            ("a" * 40, (), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": good}),
            ("b" * 40, ("a" * 40,), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": bad}),
            ("c" * 40, ("b" * 40,), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": good}),
        ]
        errors = run(restored)
        self.assertTrue(errors and "does not match its locked digest" in errors[0], errors)

        # Merge divergence: one parent carried the mutated artifact.
        merged = [
            ("a" * 40, (), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": good}),
            ("b" * 40, ("a" * 40,), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": bad}),
            ("c" * 40, ("a" * 40,), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": good}),
            (
                "d" * 40,
                ("c" * 40, "b" * 40),
                {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": good},
            ),
        ]
        errors = run(merged)
        self.assertTrue(errors and "does not match its locked digest" in errors[0], errors)

        # A missing artifact in history fails too.
        absent = [
            ("a" * 40, (), {"docs/plans/M0-gate.md": gate}),
        ]
        errors = run(absent)
        self.assertTrue(errors and "is missing" in errors[0], errors)

    def test_artifact_binding_persists_along_every_parent(self) -> None:
        """Dropping the gate, the section, or one row must all fail."""
        good = "#!/usr/bin/env bash\nexit 1\n"
        bad = "#!/usr/bin/env bash\nexit 0\n"
        other = "x = 1\n"
        d_good = hashlib.sha256(good.encode("utf-8")).hexdigest()
        d_other = hashlib.sha256(other.encode("utf-8")).hexdigest()
        two = (
            "# Gate\n\n## Bound Artifacts\n\n| SHA-256 | Path |\n| --- | --- |\n"
            f"| `{d_good}` | `scripts/run-gate.sh` |\n| `{d_other}` | `cfg.exs` |\n"
        )
        one = (
            "# Gate\n\n## Bound Artifacts\n\n| SHA-256 | Path |\n| --- | --- |\n"
            f"| `{d_other}` | `cfg.exs` |\n"
        )
        docs = documents()
        docs["docs/plans/README.md"] = _open_capsule(
            docs["docs/plans/README.md"]
            .replace(
                "| `M0` | Blocked | — | — | — |",
                "| `M0` | Open | [concept](M0.md) | "
                "[technical depth](M0-technical.md) | [gate](M0-gate.md) |",
            )
            .replace(SUMMARY, OPEN_SUMMARY)
        )
        docs["README.md"] = docs["README.md"].replace(SUMMARY, OPEN_SUMMARY)
        docs["docs/plans/M0.md"] = plan(False)
        docs["docs/plans/M0-technical.md"] = TECHNICAL_PLAN
        docs["docs/plans/M0-gate.md"] = two

        def run(snapshots):
            return validate(
                docs, None, lambda: (snapshots[-1][0], tuple(snapshots)),
                read_artifact=lambda t: (other if t == "cfg.exs" else good).encode("utf-8"),
            )

        base = {"docs/plans/M0-gate.md": two, "scripts/run-gate.sh": good, "cfg.exs": other}

        # The gate file itself is deleted, then restored.
        errors = run([
            ("a" * 40, (), dict(base)),
            ("b" * 40, ("a" * 40,), {"scripts/run-gate.sh": bad, "cfg.exs": other}),
            ("c" * 40, ("b" * 40,), dict(base)),
        ])
        self.assertTrue(errors and "gate disappeared" in errors[0], errors)

        # One row is removed from an otherwise valid table, then restored.
        errors = run([
            ("a" * 40, (), dict(base)),
            ("b" * 40, ("a" * 40,), {"docs/plans/M0-gate.md": one, "scripts/run-gate.sh": bad, "cfg.exs": other}),
            ("c" * 40, ("b" * 40,), dict(base)),
        ])
        self.assertTrue(errors and "no longer declared" in errors[0], errors)

        # A merge whose other parent dropped the gate is still caught.
        errors = run([
            ("a" * 40, (), dict(base)),
            ("b" * 40, ("a" * 40,), {"scripts/run-gate.sh": bad, "cfg.exs": other}),
            ("c" * 40, ("a" * 40,), dict(base)),
            ("d" * 40, ("c" * 40, "b" * 40), dict(base)),
        ])
        self.assertTrue(errors and "gate disappeared" in errors[0], errors)

    def test_malformed_or_removed_artifact_declaration_fails(self) -> None:
        """A broken declaration must not read as predating the convention."""
        good = "#!/usr/bin/env bash\nexit 1\n"
        bad = "#!/usr/bin/env bash\nexit 0\n"
        digest = hashlib.sha256(good.encode("utf-8")).hexdigest()
        gate = (
            "# Gate\n\n## Bound Artifacts\n\n"
            "| SHA-256 | Path |\n| --- | --- |\n"
            f"| `{digest}` | `scripts/run-gate.sh` |\n"
        )
        malformed = "# Gate\n\n## Bound Artifacts\n\nnot a table at all\n"
        absent = "# Gate\n"
        docs = documents()
        docs["docs/plans/README.md"] = _open_capsule(
            docs["docs/plans/README.md"]
            .replace(
                "| `M0` | Blocked | — | — | — |",
                "| `M0` | Open | [concept](M0.md) | "
                "[technical depth](M0-technical.md) | [gate](M0-gate.md) |",
            )
            .replace(SUMMARY, OPEN_SUMMARY)
        )
        docs["README.md"] = docs["README.md"].replace(SUMMARY, OPEN_SUMMARY)
        docs["docs/plans/M0.md"] = plan(False)
        docs["docs/plans/M0-technical.md"] = TECHNICAL_PLAN
        docs["docs/plans/M0-gate.md"] = gate

        def run(snapshots):
            return validate(
                docs,
                None,
                lambda: (snapshots[-1][0], tuple(snapshots)),
                read_artifact=lambda _: good.encode("utf-8"),
            )

        # Malformed declaration hiding a mutated artifact, then restored.
        errors = run([
            ("a" * 40, (), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": good}),
            ("b" * 40, ("a" * 40,), {"docs/plans/M0-gate.md": malformed, "scripts/run-gate.sh": bad}),
            ("c" * 40, ("b" * 40,), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": good}),
        ])
        self.assertTrue(errors and "malformed" in errors[0], errors)

        # Declaration removed entirely after being introduced.
        errors = run([
            ("a" * 40, (), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": good}),
            ("b" * 40, ("a" * 40,), {"docs/plans/M0-gate.md": absent, "scripts/run-gate.sh": bad}),
            ("c" * 40, ("b" * 40,), {"docs/plans/M0-gate.md": gate, "scripts/run-gate.sh": good}),
        ])
        self.assertTrue(errors and "disappeared" in errors[0], errors)

    def test_gate_bound_artifacts_are_verified(self) -> None:
        """A gate governs nothing executable unless its runner is bound."""
        runner = b"#!/usr/bin/env bash\nexit 1\n"
        digest = hashlib.sha256(runner).hexdigest()
        gate = (
            "# Gate\n\n## Bound Artifacts\n\n"
            "| SHA-256 | Path |\n| --- | --- |\n"
            f"| `{digest}` | `scripts/run-gate.sh` |\n"
        )
        docs = documents()
        docs["docs/plans/README.md"] = _open_capsule(
            docs["docs/plans/README.md"]
            .replace(
                "| `M0` | Blocked | — | — | — |",
                "| `M0` | Open | [concept](M0.md) | "
                "[technical depth](M0-technical.md) | [gate](M0-gate.md) |",
            )
            .replace(SUMMARY, OPEN_SUMMARY)
        )
        docs["README.md"] = docs["README.md"].replace(SUMMARY, OPEN_SUMMARY)
        docs["docs/plans/M0.md"] = plan(False)
        docs["docs/plans/M0-technical.md"] = TECHNICAL_PLAN
        docs["docs/plans/M0-gate.md"] = gate

        self.assertEqual(
            [], checked(docs, historical_gate=gate, read_artifact=lambda _: runner)
        )
        swapped = b"#!/usr/bin/env bash\nexit 0\n"
        errors = checked(docs, historical_gate=gate, read_artifact=lambda _: swapped)
        self.assertTrue(errors and "does not match its locked digest" in errors[0], errors)
        errors = checked(docs, historical_gate=gate, read_artifact=lambda _: None)
        self.assertTrue(errors and "is missing" in errors[0], errors)

    def test_status_shape_mutations_fail(self) -> None:
        cases = (
            ("summary drift", SUMMARY, SUMMARY.replace("blocked", "open")),
            ("field removed", "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |\n", ""),
            (
                "field reordered",
                "| Authorized work | Explicitly authorized planning, ADR, bootstrap, and review work only; no product implementation |\n| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |",
                "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |\n| Authorized work | Explicitly authorized planning, ADR, bootstrap, and review work only; no product implementation |",
            ),
            (
                "empty value",
                "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |",
                "| Next maintainer decision |  |",
            ),
            (
                "whitespace value",
                "| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |",
                "| Next maintainer decision |    |",
            ),
            ("validation drift", "| Validation | `bash scripts/check-bootstrap.sh` |", "| Validation | true |"),
            ("wrong link", "[Canonical milestone status and plan records](docs/plans/)", "[Canonical milestone status and plan records](docs/roadmap.md)"),
        )
        for label, old, new in cases:
            with self.subTest(label):
                docs = documents()
                target = "README.md" if "link" in label else "docs/plans/README.md"
                docs[target] = docs[target].replace(old, new)
                self.assert_invalid(docs)

        authority_cases = (
            ("phase", "Pre-implementation planning", "Product implementation authorized"),
            ("blockers", "must be accepted before M0 opens; a replacement requires a governed guard change", "are optional"),
            ("authorized work", "no product implementation", "product implementation is authorized"),
            ("decision", "Disposition ADR 0001 and ADR 0002", "Begin product implementation"),
            ("transition", "the maintainer explicitly opens `M0` gate-first", "implementation begins immediately"),
        )
        for label, old, new in authority_cases:
            with self.subTest(label):
                docs = {path: text.replace(old, new) for path, text in documents().items()}
                self.assert_invalid(docs, "exact derived status capsule")

        for label, row, summary in (
            (
                "renamed M0",
                "| `m0` | Blocked | — | — | — |",
                "**Revision status:** Pre-implementation planning; no milestone is active; next candidate `m0` is blocked.",
            ),
            (
                "removed M0",
                "",
                "**Revision status:** Pre-implementation planning; no milestone is active; no next candidate is recorded.",
            ),
        ):
            with self.subTest(label):
                source_row = "| `M0` | Blocked | — | — | — |"
                docs = {}
                for path, text in documents().items():
                    replacement = text.replace(source_row, row) if row else text.replace(source_row + "\n", "")
                    docs[path] = (
                        replacement.replace(SUMMARY, summary)
                        .replace("no product implementation", "product implementation is authorized")
                    )
                expected = (
                    "applies only to M0"
                    if label == "renamed M0"
                    else "exactly one registered milestone"
                )
                self.assert_invalid(docs, expected)

    def test_hidden_or_duplicated_markers_fail(self) -> None:
        wrappers = (
            ("```text\n", "\n````"),
            ("<!--\n", "\n-->"),
            ("`\n", "\n`"),
            ("<pre>\n", "\n</pre>"),
            ("<?loopex\n", "\n?>"),
            ("<![CDATA[\n", "\n]]>"),
            ("<!STATUS\n", "\n>"),
        )
        for prefix, suffix in wrappers:
            with self.subTest(prefix):
                docs = documents()
                docs["README.md"] = prefix + docs["README.md"] + suffix
                self.assert_invalid(docs)
        docs = documents()
        docs["README.md"] += "\n<!-- loopex:readme-status:start -->"
        self.assert_invalid(docs)
        docs = documents()
        docs["README.md"] = docs["README.md"].replace(
            "<!-- loopex:readme-status:start -->", "## Earlier\n\n<!-- loopex:readme-status:start -->"
        )
        self.assert_invalid(docs, "outside")
        docs = documents()
        docs["README.md"] = "# Decoy\n\n## Earlier\n\nText\n\n" + docs["README.md"]
        self.assert_invalid(docs, "first line")
        docs = documents()
        docs["README.md"] = docs["README.md"].replace("\n## Where Things Stand", "\u2028## Where Things Stand")
        self.assert_invalid(docs, "line separator")

    def test_register_and_file_mutations_fail(self) -> None:
        mutations = (
            ("bad state", "Blocked", "Ready"),
            ("reserved", "`M0`", "`con`"),
            ("bad name", "`M0`", "`kernel--a`"),
            ("wrong links", "| `M0` | Blocked | — | — | — |", "| `M0` | Open | [M0](M0.md) | — | [gate](M0-gate.md) |"),
            ("second blocked", "| `M0` | Blocked | — | — | — |", "| `M0` | Blocked | — | — | — |\n| `M1` | Blocked | — | — | — |"),
            ("case collision", "| `M0` | Blocked | — | — | — |", "| `M0` | Blocked | — | — | — |\n| `m0` | Closed | [concept](m0.md) | [technical depth](m0-technical.md) | [gate](m0-gate.md) |"),
            ("name too long", "`M0`", f"`{'a' * 65}`"),
        )
        for label, old, new in mutations:
            with self.subTest(label):
                docs = documents()
                docs["docs/plans/README.md"] = docs["docs/plans/README.md"].replace(old, new)
                self.assert_invalid(docs)
        for path in ("docs/plans/M0.md", "docs/plans/M0-gate.md", "docs/plans/M0/evidence.md"):
            with self.subTest(path):
                docs = documents()
                docs[path] = "# orphan\n"
                self.assert_invalid(docs)

    def test_governance_matches_state(self) -> None:
        def resolve(sha: str, path: str, historical_gate: str = GATE) -> str | None:
            if path.endswith("M0-gate.md"):
                return historical_gate
            if path.endswith("M0-technical.md"):
                return TECHNICAL_PLAN
            if path.endswith("M0.md") and sha in {"a" * 40, "b" * 40}:
                return plan(False)
            if path.endswith("M0.md") and sha == "c" * 40:
                return plan(True, progress="Proved")
            return None

        def invalid(text: str, state: str, fragment: str, gate: str = GATE) -> None:
            with self.assertRaisesRegex(Exception, fragment):
                _governance(text, TECHNICAL_PLAN, gate, "M0", state, resolve)

        invalid(plan(False), "Accepted", "lifecycle state")
        invalid(
            plan(True).replace(
                "| Closure | — | — | — |",
                "| Closure | — | — | — |\n| Acceptance | x | x | x |",
            ),
            "Accepted",
            "governance rows",
        )
        invalid(
            plan(True).replace(
                "| --- | --- | --- | --- |",
                "| --- | --- | --- | --- |\n```text\ndecoy\n````",
            ),
            "Accepted",
            "malformed table|consecutively numbered",
        )
        invalid(
            plan(True) + "\n---\n\nignored extra\n",
            "Accepted",
            "malformed table|trailing content",
        )
        invalid(
            plan(True).replace(hashlib.sha256(GATE.encode()).hexdigest(), "b" * 64),
            "Accepted",
            "does not match",
        )
        changed_gate = "# Changed gate\n"
        with self.assertRaisesRegex(Exception, "historical"):
            _governance(
                plan(True, gate=changed_gate),
                TECHNICAL_PLAN,
                changed_gate,
                "M0",
                "Accepted",
                resolve,
            )
        invalid(plan(True) + "\n## Milestone Status\n", "Accepted", "plan document headings")
        for separator in GATE_SEPARATORS:
            with self.subTest(f"current {separator!r}"):
                noncanonical_gate = f"# Gate{separator}continued\n"
                invalid(
                    plan(True, gate=noncanonical_gate),
                    "Accepted",
                    "UTF-8/LF",
                    noncanonical_gate,
                )
        for separator in GATE_SEPARATORS:
            with self.subTest(f"historical {separator!r}"):
                historical_gate = f"# Gate{separator}continued\n"
                with self.assertRaisesRegex(Exception, "UTF-8/LF"):
                    _governance(
                        plan(True),
                        TECHNICAL_PLAN,
                        GATE,
                        "M0",
                        "Accepted",
                        lambda sha, path: resolve(sha, path, historical_gate),
                    )
        closed_docs = documents()
        closed_summary = "**Revision status:** Pre-implementation planning; no milestone is active; no next candidate is recorded."
        closed_docs = {
            key: value.replace(
                "| `M0` | Blocked | — | — | — |",
                "| `M0` | Closed | [concept](M0.md) | "
                "[technical depth](M0-technical.md) | [gate](M0-gate.md) |",
            ).replace(SUMMARY, closed_summary)
            for key, value in closed_docs.items()
        }
        closed_docs["docs/plans/README.md"] = closed_docs["docs/plans/README.md"].replace(
            "Seed bootstrap — 2026-08-15", "`M0` — 2026-99-99"
        )
        closed_docs["docs/plans/M0.md"] = plan(True, True)
        closed_docs["docs/plans/M0-technical.md"] = TECHNICAL_PLAN
        closed_docs["docs/plans/M0-gate.md"] = GATE
        self.assert_invalid(closed_docs, "Last integrated checkpoint")
        invalid(
            plan().replace(
                "| Acceptance | — | — | — |", "| Acceptance | Maintainer | — | junk |"
            ),
            "Open",
            "exactly empty",
        )

    def test_completed_governance_rows_are_history_anchored(self) -> None:
        original = plan(True)
        path = "docs/plans/M0.md"
        current = original.replace("| 1 | Open | — |", "| 1 | Proved | evidence |")
        anchored = (
            "first-completion",
            (
                ("root", (), {}),
                ("first-completion", ("root",), plan_snapshot(original)),
            ),
        )
        _governance_history(plan_snapshot(current), anchored)

        mutations = (
            ("authority", "Maintainer", "Delegate: Reviewer"),
            ("evidence", "../vision.md#concept", "../vision.md#concept-other"),
            ("candidate", "a" * 40, "b" * 40),
        )
        for label, old, new in mutations:
            with self.subTest(label):
                changed = original.replace(old, new, 1)
                with self.assertRaisesRegex(Exception, "completed Acceptance"):
                    _governance_history(plan_snapshot(changed), anchored)

        changed_gate = "# Changed gate\n"
        changed = plan(True, gate=changed_gate).replace(
            "Maintainer | [disposition](../vision.md#concept)",
            "Delegate: Reviewer | [disposition](../vision.md#concept-other)",
        )
        with self.assertRaisesRegex(Exception, "completed Acceptance"):
            _governance_history(plan_snapshot(changed), anchored)

        for label, intermediate in (
            ("mutate then restore", original.replace("Maintainer", "Delegate: Reviewer", 1)),
            ("clear then restore", plan(False)),
        ):
            with self.subTest(label):
                history = (
                    "later",
                    (
                        ("root", (), {}),
                        ("first-completion", ("root",), plan_snapshot(original)),
                        ("later", ("first-completion",), plan_snapshot(intermediate)),
                    ),
                )
                with self.assertRaisesRegex(Exception, "completed Acceptance"):
                    _governance_history(plan_snapshot(original), history)

        deleted = (
            "deleted",
            (
                ("root", (), {}),
                ("first-completion", ("root",), plan_snapshot(original)),
                ("deleted", ("first-completion",), {}),
            ),
        )
        with self.assertRaisesRegex(Exception, "disappeared"):
            _governance_history(plan_snapshot(original), deleted)
        with self.assertRaisesRegex(Exception, "disappeared"):
            _governance_history({}, anchored)

        closed_original = plan(True, True)
        closure_history = (
            "closure",
            (
                ("root", (), {}),
                ("closure", ("root",), plan_snapshot(closed_original)),
            ),
        )
        with self.assertRaisesRegex(Exception, "completed Closure"):
            _governance_history(
                plan_snapshot(
                    closed_original.replace(
                        "../roadmap.md#concept", "../roadmap.md#concept-other", 1
                    )
                ),
                closure_history,
            )
        with self.assertRaisesRegex(Exception, "history is unavailable"):
            _governance_history(plan_snapshot(original), None)

        merged = original.replace("Maintainer", "Delegate: Reviewer", 1)
        history = (
            "merge",
            (
                ("root", (), {}),
                ("accepted-topic", ("root",), plan_snapshot(original)),
                ("main-work", ("root",), {}),
                ("merge", ("main-work", "accepted-topic"), plan_snapshot(merged)),
            ),
        )
        with self.assertRaisesRegex(Exception, "completed Acceptance"):
            _governance_history(plan_snapshot(merged), history)

    def test_accepted_gate_is_anchored_but_open_gate_is_mutable(self) -> None:
        plan_path = "docs/plans/M0.md"
        gate_path = "docs/plans/M0-gate.md"
        accepted = plan(True)
        history = (
            "accepted",
            (
                ("root", (), {}),
                (
                    "accepted",
                    ("root",),
                    plan_snapshot(accepted, GATE),
                ),
            ),
        )
        _governance_history(plan_snapshot(accepted, GATE), history)

        changed_gate = "# Changed gate\n"
        with self.assertRaisesRegex(Exception, "accepted gate"):
            _governance_history(
                plan_snapshot(accepted, changed_gate), history
            )

        for label, later in (
            (
                "mutate then restore",
                plan_snapshot(accepted, changed_gate),
            ),
            ("delete then restore", plan_snapshot(accepted)),
        ):
            with self.subTest(label=label):
                traversed = (
                    "later",
                    (*history[1], ("later", ("accepted",), later)),
                )
                with self.assertRaisesRegex(Exception, "accepted gate|gate is missing"):
                    _governance_history(
                        plan_snapshot(accepted, GATE), traversed
                    )

        merged = (
            "merge",
            (
                ("root", (), {}),
                (
                    "accepted",
                    ("root",),
                    plan_snapshot(accepted, GATE),
                ),
                (
                    "main",
                    ("root",),
                    plan_snapshot(plan(False), changed_gate),
                ),
                (
                    "merge",
                    ("main", "accepted"),
                    plan_snapshot(accepted, changed_gate),
                ),
            ),
        )
        with self.assertRaisesRegex(Exception, "accepted gate"):
            _governance_history(
                plan_snapshot(accepted, changed_gate), merged
            )

        open_history = (
            "open",
            (
                ("root", (), {}),
                (
                    "open",
                    ("root",),
                    plan_snapshot(plan(False), GATE),
                ),
            ),
        )
        _governance_history(
            plan_snapshot(plan(False), changed_gate), open_history
        )

        noncanonical = "# Gate\r\n"
        with self.assertRaisesRegex(Exception, "UTF-8/LF"):
            _governance_history(
                plan_snapshot(accepted, noncanonical),
                (
                    "accepted",
                    (
                        ("root", (), {}),
                        (
                            "accepted",
                            ("root",),
                            plan_snapshot(accepted, noncanonical),
                        ),
                    ),
                ),
            )


    def test_barrier_mutations_fail_and_matching_change_passes(self) -> None:
        mutations = (
            ("source append", "docs/vision-technical.md", "-> multi-client attachment and protocol candidate", "-> multi-client attachment and protocol candidate\n-> extra"),
            ("renamed heading", "docs/vision-technical.md", "## 22. Ownership and serial barriers", "## 22. Barriers"),
            ("different section", "docs/vision-technical.md", "<!-- loopex:rejoin-source:start -->", "# Different section\n\n<!-- loopex:rejoin-source:start -->"),
            ("setext h1", "docs/vision-technical.md", "<!-- loopex:rejoin-source:start -->", "Different\n=========\n\n<!-- loopex:rejoin-source:start -->"),
            ("setext h2", "docs/vision-technical.md", "<!-- loopex:rejoin-source:start -->", "Different\n---------\n\n<!-- loopex:rejoin-source:start -->"),
            ("hidden", "docs/roadmap-technical.md", "<!-- loopex:rejoin-copy:start -->", "<!--\n<!-- loopex:rejoin-copy:start -->"),
        )
        for label, path, old, new in mutations:
            with self.subTest(label):
                docs = documents()
                docs[path] = docs[path].replace(old, new)
                self.assert_invalid(docs)
        for label, replacement, error in (
            ("empty", "```text\n```", "complete text fence"),
            ("blank first", "```text\n   \n-> next\n```", "needs an initial step"),
            ("blank transition", "```text\nfirst\n->    \n```", "every later rejoin step"),
        ):
            with self.subTest(label):
                docs = {key: value.replace(REJOIN, replacement) for key, value in documents().items()}
                self.assert_invalid(docs, error)
        docs = {key: value.replace("-> multi-client attachment and protocol candidate", "-> replacement") for key, value in documents().items()}
        self.assertEqual([], checked(docs))


if __name__ == "__main__":
    unittest.main()
