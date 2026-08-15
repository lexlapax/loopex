#!/usr/bin/env python3
"""Adversarial controls for the temporary status checker."""

from __future__ import annotations

import copy
import hashlib
import subprocess
import unittest
from pathlib import Path

from check_status import _git_resolver, validate


SUMMARY = "**Revision status:** Pre-implementation planning; no milestone is active; next candidate `M0` is blocked."
CURRENT = f"""<!-- loopex:current-status:start -->
## Current Status

{SUMMARY}

| Field | Value |
| --- | --- |
| Integrated phase | Pre-implementation planning |
| Last integrated checkpoint | Seed bootstrap — 2026-08-15 |
| Blockers | Decisions remain |
| Authorized work | Planning only |
| Next maintainer decision | Disposition decisions |
| Next transition | Explicitly open `M0` |
| Validation | `bash scripts/check-bootstrap.sh` |
<!-- loopex:current-status:end -->"""
REGISTER = """<!-- loopex:milestone-register:start -->
## Milestone Register

| Milestone | State | Plan | Gate |
| --- | --- | --- | --- |
| `M0` | Blocked | — | — |
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


def documents() -> dict[str, str]:
    return {
        "README.md": README,
        "docs/plans/README.md": f"# Plans\n\n{CURRENT}\n\n{REGISTER}\n",
        "docs/vision.md": (
            "# Vision\n\n## 22. Ownership and serial barriers\n\n"
            f"<!-- loopex:rejoin-source:start -->\n{REJOIN}\n<!-- loopex:rejoin-source:end -->\n"
        ),
        "docs/roadmap.md": (
            "# Roadmap\n\n## The Enduring Rejoin Order\n\n"
            f"<!-- loopex:rejoin-copy:start -->\n{REJOIN}\n<!-- loopex:rejoin-copy:end -->\n"
        ),
    }


def plan(governed: bool = False, closed: bool = False, gate: str = GATE) -> str:
    digest = hashlib.sha256(gate.encode()).hexdigest()
    acceptance_bound = f"candidate `{'a' * 40}`; gate `sha256:{digest}`"
    closure_bound = f"candidate `{'c' * 40}`; gate `sha256:{digest}`"
    acceptance = f"Maintainer | [disposition](decision.md#accept) | {acceptance_bound}" if governed else "— | — | —"
    closure = f"Maintainer | [disposition](decision.md#close) | {closure_bound}" if closed else "— | — | —"
    return f"""# M0

## Governance Records

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | {acceptance} |
| Closure | {closure} |
"""


def checked(docs: dict[str, str]) -> list[str]:
    return validate(
        docs,
        lambda sha, path: GATE
        if sha in {"a" * 40, "c" * 40} and path.endswith("M0-gate.md")
        else None,
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

    def test_git_resolver_requires_a_commit_object(self) -> None:
        root = Path(__file__).resolve().parents[1]
        tree = subprocess.check_output(
            ["git", "rev-parse", "HEAD^{tree}"], cwd=root, text=True
        ).strip()
        self.assertIsNone(_git_resolver(root)(tree, "README.md"))

    def test_open_and_closed_plans(self) -> None:
        for state, governed, closed in (("Open", False, False), ("Closed", True, True)):
            docs = documents()
            old_row = "| `M0` | Blocked | — | — |"
            new_row = f"| `M0` | {state} | [plan](M0.md) | [gate](M0-gate.md) |"
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
            docs["docs/plans/M0-gate.md"] = GATE
            self.assertEqual([], checked(docs))

    def test_status_shape_mutations_fail(self) -> None:
        cases = (
            ("summary drift", SUMMARY, SUMMARY.replace("blocked", "open")),
            ("field removed", "| Blockers | Decisions remain |\n", ""),
            ("field reordered", "| Blockers | Decisions remain |\n| Authorized work | Planning only |", "| Authorized work | Planning only |\n| Blockers | Decisions remain |"),
            ("empty value", "| Blockers | Decisions remain |", "| Blockers |  |"),
            ("whitespace value", "| Blockers | Decisions remain |", "| Blockers |    |"),
            ("validation drift", "| Validation | `bash scripts/check-bootstrap.sh` |", "| Validation | true |"),
            ("wrong link", "[Canonical milestone status and plan records](docs/plans/)", "[Canonical milestone status and plan records](docs/roadmap.md)"),
        )
        for label, old, new in cases:
            with self.subTest(label):
                docs = documents()
                target = "README.md" if "link" in label else "docs/plans/README.md"
                docs[target] = docs[target].replace(old, new)
                self.assert_invalid(docs)

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
            ("wrong links", "| `M0` | Blocked | — | — |", "| `M0` | Open | [M0](M0.md) | [gate](M0-gate.md) |"),
            ("second blocked", "| `M0` | Blocked | — | — |", "| `M0` | Blocked | — | — |\n| `M1` | Blocked | — | — |"),
            ("case collision", "| `M0` | Blocked | — | — |", "| `M0` | Blocked | — | — |\n| `m0` | Closed | [plan](m0.md) | [gate](m0-gate.md) |"),
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
        docs = documents()
        row = "| `M0` | Accepted | [plan](M0.md) | [gate](M0-gate.md) |"
        active = "**Revision status:** Pre-implementation planning; active milestone `M0` is accepted; no next candidate is recorded."
        docs = {key: value.replace("| `M0` | Blocked | — | — |", row).replace(SUMMARY, active) for key, value in docs.items()}
        docs["docs/plans/M0.md"] = plan(False)
        docs["docs/plans/M0-gate.md"] = GATE
        self.assert_invalid(docs, "lifecycle state")
        docs["docs/plans/M0.md"] = plan(True).replace(
            "| Closure | — | — | — |", "| Closure | — | — | — |\n| Acceptance | x | x | x |"
        )
        self.assert_invalid(docs, "governance rows")
        docs["docs/plans/M0.md"] = plan(True).replace(
            "| --- | --- | --- | --- |", "| --- | --- | --- | --- |\n```text\ndecoy\n````"
        )
        self.assert_invalid(docs, "malformed table")
        docs["docs/plans/M0.md"] = plan(True) + "\n---\n\nignored extra\n"
        self.assert_invalid(docs, "malformed table")
        docs["docs/plans/M0.md"] = plan(True).replace(
            hashlib.sha256(GATE.encode()).hexdigest(), "b" * 64
        )
        self.assert_invalid(docs, "does not match")
        changed_gate = "# Changed gate\n"
        docs["docs/plans/M0.md"] = plan(True, gate=changed_gate)
        docs["docs/plans/M0-gate.md"] = changed_gate
        self.assert_invalid(docs, "historical")
        docs["docs/plans/M0.md"] = plan(True) + "\n## Milestone Status\n"
        docs["docs/plans/M0-gate.md"] = GATE
        self.assert_invalid(docs, "lifecycle state")
        closed_docs = documents()
        closed_summary = "**Revision status:** Pre-implementation planning; no milestone is active; no next candidate is recorded."
        closed_docs = {
            key: value.replace("| `M0` | Blocked | — | — |", "| `M0` | Closed | [plan](M0.md) | [gate](M0-gate.md) |").replace(SUMMARY, closed_summary)
            for key, value in closed_docs.items()
        }
        closed_docs["docs/plans/README.md"] = closed_docs["docs/plans/README.md"].replace(
            "Seed bootstrap — 2026-08-15", "`M0` — 2026-99-99"
        )
        closed_docs["docs/plans/M0.md"] = plan(True, True)
        closed_docs["docs/plans/M0-gate.md"] = GATE
        self.assert_invalid(closed_docs, "Last integrated checkpoint")
        open_docs = documents()
        open_summary = "**Revision status:** Pre-implementation planning; active milestone `M0` is open; no next candidate is recorded."
        open_docs = {
            key: value.replace("| `M0` | Blocked | — | — |", "| `M0` | Open | [plan](M0.md) | [gate](M0-gate.md) |").replace(SUMMARY, open_summary)
            for key, value in open_docs.items()
        }
        open_docs["docs/plans/M0.md"] = plan().replace("| Acceptance | — | — | — |", "| Acceptance | Maintainer | — | junk |")
        open_docs["docs/plans/M0-gate.md"] = GATE
        self.assert_invalid(open_docs, "exactly empty")


    def test_barrier_mutations_fail_and_matching_change_passes(self) -> None:
        mutations = (
            ("source append", "docs/vision.md", "-> multi-client attachment and protocol candidate", "-> multi-client attachment and protocol candidate\n-> extra"),
            ("renamed heading", "docs/vision.md", "## 22. Ownership and serial barriers", "## 22. Barriers"),
            ("different section", "docs/vision.md", "<!-- loopex:rejoin-source:start -->", "# Different section\n\n<!-- loopex:rejoin-source:start -->"),
            ("setext h1", "docs/vision.md", "<!-- loopex:rejoin-source:start -->", "Different\n=========\n\n<!-- loopex:rejoin-source:start -->"),
            ("setext h2", "docs/vision.md", "<!-- loopex:rejoin-source:start -->", "Different\n---------\n\n<!-- loopex:rejoin-source:start -->"),
            ("hidden", "docs/roadmap.md", "<!-- loopex:rejoin-copy:start -->", "<!--\n<!-- loopex:rejoin-copy:start -->"),
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
