#!/usr/bin/env python3
"""Adversarial controls for the temporary status checker."""

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
| Blockers | [ADR 0001](../adr/0001-repository-and-application-layout.md) and [ADR 0002](../adr/0002-bootstrap-runtime-floor.md) must be accepted before M0 opens; a replacement requires a governed guard change |
| Authorized work | Explicitly authorized planning, ADR, bootstrap, and review work only; no product implementation |
| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |
| Next transition | After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first |
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
ENVELOPE = """<!-- loopex:plan-envelope:start -->
## Normative Envelope

### Purpose

Prove one bounded behavior.

### Outcomes

| # | Outcome | Evidence class | Gate selector |
| --- | --- | --- | --- |
| 1 | One bounded outcome | focused test | `test/example_test.exs` |

### Scope

Only the bounded outcome.

### Non-Goals

No public freeze.

### Prerequisites and Acceptance Points

Prerequisites are accepted before plan acceptance.

### Ownership, Decision Owners, and Rejoin Barriers

The maintainer owns decisions; there is one serial rejoin.

### Evidence Obligations and Mapping

Outcome 1 maps to the named focused test.

### Compatibility

No compatibility claim.

### Migration and Rollback

Rollback removes the candidate.

### Packaging

No package or release.

### Proportional Minimalism Budget

Use direct code; add no abstraction without two concrete examples.
<!-- loopex:plan-envelope:end -->"""

ADR_PATHS = (
    "docs/adr/0001-repository-and-application-layout.md",
    "docs/adr/0002-bootstrap-runtime-floor.md",
)


def adr(number: int, accepted: bool = False) -> str:
    path = ADR_PATHS[number - 1]
    proposal = f"""# 000{number}. Decision {number}

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
    digest = hashlib.sha256(proposal.encode()).hexdigest()
    return proposal.replace("- **Status:** Proposed", "- **Status:** Accepted").replace(
        "| Acceptance | — | — | — |",
        "| Acceptance | Maintainer | [disposition](decision.md#accept) | "
        f"candidate `{candidate}`; document `sha256:{digest}` |",
    )


def documents() -> dict[str, str]:
    result = {
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
    result.update({path: adr(index) for index, path in enumerate(ADR_PATHS, 1)})
    return result


def plan(
    governed: bool = False,
    closed: bool = False,
    gate: str = GATE,
    progress: str | None = None,
) -> str:
    digest = hashlib.sha256(gate.encode()).hexdigest()
    acceptance_bound = f"candidate `{'a' * 40}`; gate `sha256:{digest}`"
    closure_bound = f"candidate `{'c' * 40}`; gate `sha256:{digest}`"
    acceptance = f"Maintainer | [disposition](decision.md#accept) | {acceptance_bound}" if governed else "— | — | —"
    closure = f"Maintainer | [disposition](decision.md#close) | {closure_bound}" if closed else "— | — | —"
    progress_state = progress or ("Proved" if closed else "Open")
    return f"""{ENVELOPE}

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


def checked(
    docs: dict[str, str],
    historical_gate: str = GATE,
    plan_history: tuple[tuple[str, dict[str, str]], ...] = (),
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
        if path.endswith("M0.md"):
            if sha in {"a" * 40, "b" * 40}:
                return plan(False)
            if sha == "c" * 40:
                return plan(True, progress="Proved")
        if path == ADR_PATHS[0] and sha == "d" * 40:
            return adr(1)
        if path == ADR_PATHS[1] and sha == "e" * 40:
            return adr(2)
        return None

    return validate(
        docs,
        resolve,
        lambda: (parent, tuple(snapshots)),
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
            "[ADR 0001](../adr/0001-repository-and-application-layout.md) and "
            "[ADR 0002](../adr/0002-bootstrap-runtime-floor.md) must be accepted before "
            "M0 opens; a replacement requires a governed guard change",
            f"[ADR 000{number}](../adr/{filename}) must be accepted before M0 opens; "
            "a replacement requires a governed guard change",
        ).replace(
            "Disposition ADR 0001 and ADR 0002", f"Disposition ADR 000{number}"
        )
    elif not unresolved:
        docs["docs/plans/README.md"] = docs["docs/plans/README.md"].replace(
            "[ADR 0001](../adr/0001-repository-and-application-layout.md) and "
            "[ADR 0002](../adr/0002-bootstrap-runtime-floor.md) must be accepted before "
            "M0 opens; a replacement requires a governed guard change",
            "M0 has not been explicitly opened gate-first",
        ).replace(
            "Disposition ADR 0001 and ADR 0002", "Explicitly open or defer M0"
        ).replace(
            "After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first",
            "Create the branch-only M0 plan and red gate, install lifecycle-specific status checks, and move M0 to Open",
        )
    return docs


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

    def test_plan_envelope_and_candidate_shapes_are_locked(self) -> None:
        resolve = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else plan(False)
            if sha == "a" * 40
            else plan(True, progress="Proved")
            if sha == "c" * 40
            else None
        )
        _governance(plan(True), GATE, "M0", "Accepted", resolve)
        _governance(plan(True, True), GATE, "M0", "Closed", resolve)

        mutable = plan(True).replace("One direct workstream.", "Two direct workstreams.").replace(
            "| 1 | Open | — |", "| 1 | Proved | [run](evidence.md) |"
        )
        _governance(mutable, GATE, "M0", "Accepted", resolve)

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
                changed = plan(True).replace(heading, heading + " changed", 1)
                with self.assertRaisesRegex(Exception, "headings"):
                    _governance(changed, GATE, "M0", "Accepted", resolve)

        for label, changed in (
            (
                "missing marker",
                plan(True).replace("<!-- loopex:plan-envelope:start -->\n", "", 1),
            ),
            (
                "duplicate marker",
                plan(True) + "\n<!-- loopex:plan-envelope:start -->\n",
            ),
            (
                "hidden marker",
                plan(True).replace(
                    "<!-- loopex:plan-envelope:start -->",
                    "<!--\n<!-- loopex:plan-envelope:start -->\n-->",
                    1,
                ),
            ),
            (
                "empty section",
                plan(True).replace(
                    "### Compatibility\n\nNo compatibility claim.",
                    "### Compatibility\n",
                    1,
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
        ):
            with self.subTest(label=label):
                with self.assertRaises(Exception):
                    _governance(changed, GATE, "M0", "Accepted", resolve)

        candidate_with_completed_acceptance = lambda sha, path: (
            GATE if path.endswith("M0-gate.md") else plan(True)
        )
        with self.assertRaisesRegex(Exception, "candidate.*governance"):
            _governance(
                plan(True), GATE, "M0", "Accepted", candidate_with_completed_acceptance
            )

        candidate_without_progress = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else plan(False).replace("## Progress and Evidence", "## Progress")
        )
        with self.assertRaisesRegex(Exception, "plan document|Progress and Evidence"):
            _governance(plan(True), GATE, "M0", "Accepted", candidate_without_progress)

        closure_without_acceptance = lambda sha, path: (
            GATE if path.endswith("M0-gate.md") else plan(False, progress="Proved")
        )
        with self.assertRaisesRegex(Exception, "closure candidate"):
            _governance(
                plan(True, True), GATE, "M0", "Closed", closure_without_acceptance
            )

        closure_with_open_progress = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else plan(False)
            if sha == "a" * 40
            else plan(True)
        )
        with self.assertRaisesRegex(Exception, "no Open"):
            _governance(
                plan(True, True), GATE, "M0", "Closed", closure_with_open_progress
            )

        different_candidate = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else plan(False).replace("Only the bounded outcome.", "Different scope.")
        )
        with self.assertRaisesRegex(Exception, "differs from its candidate"):
            _governance(plan(True), GATE, "M0", "Accepted", different_candidate)

        different_closure = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else plan(False)
            if sha == "a" * 40
            else plan(True, progress="Proved").replace(
                "Only the bounded outcome.", "Different scope."
            )
        )
        with self.assertRaisesRegex(Exception, "closure candidate changed"):
            _governance(plan(True, True), GATE, "M0", "Closed", different_closure)

    def test_progress_table_is_total_and_lifecycle_aware(self) -> None:
        def invalid(text: str, state: str, fragment: str) -> None:
            with self.assertRaisesRegex(Exception, fragment):
                _governance(text, GATE, "M0", state, lambda sha, path: None)

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
                    "<!-- loopex:plan-envelope:end -->\n\n## Workstreams",
                    "<!-- loopex:plan-envelope:end -->\n\nScope override.\n\n## Workstreams",
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
                _governance(text, GATE, "M0", "Open", lambda sha, path: None)

        bad_candidate = lambda sha, path: (
            GATE
            if path.endswith("M0-gate.md")
            else plan(False).replace(
                "<!-- loopex:plan-envelope:end -->\n\n## Workstreams",
                "<!-- loopex:plan-envelope:end -->\n\nScope override.\n\n## Workstreams",
            )
        )
        with self.assertRaisesRegex(Exception, "Workstreams"):
            _governance(plan(True), GATE, "M0", "Accepted", bad_candidate)

        path = "docs/plans/M0.md"
        original = plan(True)
        bad_history = original.replace(
            "## Workstreams", "## Scope Override\n\nBroader work.\n\n## Workstreams"
        )
        history = (
            "accepted",
            (("root", (), {}), ("accepted", ("root",), {path: original})),
        )
        with self.assertRaisesRegex(Exception, "headings"):
            _governance_history({path: bad_history}, history)

    def test_plan_envelope_is_anchored_with_acceptance_history(self) -> None:
        path = "docs/plans/M0.md"
        original = plan(True)
        changed = original.replace("Only the bounded outcome.", "A larger scope.")
        history = (
            "accepted",
            (("root", (), {}), ("accepted", ("root",), {path: original})),
        )
        progress_changed = original.replace(
            "| 1 | Open | — |", "| 1 | Proved | [run](evidence.md) |"
        )
        _governance_history({path: progress_changed}, history)
        with self.assertRaisesRegex(Exception, "normative envelope"):
            _governance_history({path: changed}, history)

        merge = (
            "merge",
            (
                ("root", (), {}),
                ("accepted", ("root",), {path: original}),
                ("main", ("root",), {}),
                ("merge", ("main", "accepted"), {path: changed}),
            ),
        )
        with self.assertRaisesRegex(Exception, "normative envelope"):
            _governance_history({path: changed}, merge)

    def test_accepted_adr_history_is_anchored_through_merges(self) -> None:
        path = ADR_PATHS[0]
        proposal = adr(1)
        accepted = adr(1, True)
        legacy = proposal.split("## Governance Record", 1)[0] + "## Context\n\nLegacy.\n"
        history = (
            "accepted",
            (
                ("legacy", (), {path: legacy}),
                ("proposal", ("legacy",), {path: proposal}),
                ("accepted", ("proposal",), {path: accepted}),
            ),
        )
        _governance_history({path: accepted}, history)

        changed = accepted.replace(
            "Choose the bounded decision.", "Rewrite the accepted decision."
        )
        with self.assertRaisesRegex(Exception, "accepted document"):
            _governance_history({path: changed}, history)

        deleted = (
            "deleted",
            (*history[1], ("deleted", ("accepted",), {})),
        )
        with self.assertRaisesRegex(Exception, "disappeared"):
            _governance_history({path: accepted}, deleted)

        merge = (
            "merge",
            (
                ("root", (), {}),
                ("accepted", ("root",), {path: accepted}),
                ("main", ("root",), {}),
                ("merge", ("main", "accepted"), {path: changed}),
            ),
        )
        with self.assertRaisesRegex(Exception, "accepted document"):
            _governance_history({path: changed}, merge)

        docs = documents()
        del docs[ADR_PATHS[1]]
        self.assert_invalid(docs, "missing")

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
            self.assert_invalid(docs, "must replace this seed guard")

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
                self.assert_invalid(docs, "exact blocked-M0 status capsule")

        for label, row, summary in (
            (
                "renamed M0",
                "| `m0` | Blocked | — | — |",
                "**Revision status:** Pre-implementation planning; no milestone is active; next candidate `m0` is blocked.",
            ),
            (
                "removed M0",
                "",
                "**Revision status:** Pre-implementation planning; no milestone is active; no next candidate is recorded.",
            ),
        ):
            with self.subTest(label):
                source_row = "| `M0` | Blocked | — | — |"
                docs = {}
                for path, text in documents().items():
                    replacement = text.replace(source_row, row) if row else text.replace(source_row + "\n", "")
                    docs[path] = (
                        replacement.replace(SUMMARY, summary)
                        .replace("no product implementation", "product implementation is authorized")
                    )
                self.assert_invalid(docs, "bootstrap permits only Blocked M0")

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
        def resolve(sha: str, path: str, historical_gate: str = GATE) -> str | None:
            if path.endswith("M0-gate.md"):
                return historical_gate
            if path.endswith("M0.md") and sha in {"a" * 40, "b" * 40}:
                return plan(False)
            if path.endswith("M0.md") and sha == "c" * 40:
                return plan(True, progress="Proved")
            return None

        def invalid(text: str, state: str, fragment: str, gate: str = GATE) -> None:
            with self.assertRaisesRegex(Exception, fragment):
                _governance(text, gate, "M0", state, resolve)

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
            "malformed table",
        )
        invalid(plan(True) + "\n---\n\nignored extra\n", "Accepted", "malformed table")
        invalid(
            plan(True).replace(hashlib.sha256(GATE.encode()).hexdigest(), "b" * 64),
            "Accepted",
            "does not match",
        )
        changed_gate = "# Changed gate\n"
        with self.assertRaisesRegex(Exception, "historical"):
            _governance(
                plan(True, gate=changed_gate),
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
                        GATE,
                        "M0",
                        "Accepted",
                        lambda sha, path: resolve(sha, path, historical_gate),
                    )
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
                ("first-completion", ("root",), {path: original}),
            ),
        )
        _governance_history({path: current}, anchored)

        mutations = (
            ("authority", "Maintainer", "Delegate: Reviewer"),
            ("evidence", "decision.md#accept", "decision.md#different"),
            ("candidate", "a" * 40, "b" * 40),
        )
        for label, old, new in mutations:
            with self.subTest(label):
                changed = original.replace(old, new, 1)
                with self.assertRaisesRegex(Exception, "completed Acceptance"):
                    _governance_history({path: changed}, anchored)

        changed_gate = "# Changed gate\n"
        changed = plan(True, gate=changed_gate).replace(
            "Maintainer | [disposition](decision.md#accept)",
            "Delegate: Reviewer | [disposition](decision.md#different)",
        )
        with self.assertRaisesRegex(Exception, "completed Acceptance"):
            _governance_history({path: changed}, anchored)

        for label, intermediate in (
            ("mutate then restore", original.replace("Maintainer", "Delegate: Reviewer", 1)),
            ("clear then restore", plan(False)),
        ):
            with self.subTest(label):
                history = (
                    "later",
                    (
                        ("root", (), {}),
                        ("first-completion", ("root",), {path: original}),
                        ("later", ("first-completion",), {path: intermediate}),
                    ),
                )
                with self.assertRaisesRegex(Exception, "completed Acceptance"):
                    _governance_history({path: original}, history)

        deleted = (
            "deleted",
            (
                ("root", (), {}),
                ("first-completion", ("root",), {path: original}),
                ("deleted", ("first-completion",), {}),
            ),
        )
        with self.assertRaisesRegex(Exception, "disappeared"):
            _governance_history({path: original}, deleted)
        with self.assertRaisesRegex(Exception, "disappeared"):
            _governance_history({}, anchored)

        closed_original = plan(True, True)
        closure_history = (
            "closure",
            (
                ("root", (), {}),
                ("closure", ("root",), {path: closed_original}),
            ),
        )
        with self.assertRaisesRegex(Exception, "completed Closure"):
            _governance_history(
                {path: closed_original.replace("decision.md#close", "decision.md#new-close")},
                closure_history,
            )
        with self.assertRaisesRegex(Exception, "history is unavailable"):
            _governance_history({path: original}, None)

        merged = original.replace("Maintainer", "Delegate: Reviewer", 1)
        history = (
            "merge",
            (
                ("root", (), {}),
                ("accepted-topic", ("root",), {path: original}),
                ("main-work", ("root",), {}),
                ("merge", ("main-work", "accepted-topic"), {path: merged}),
            ),
        )
        with self.assertRaisesRegex(Exception, "completed Acceptance"):
            _governance_history({path: merged}, history)

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
                    {plan_path: accepted, gate_path: GATE},
                ),
            ),
        )
        _governance_history({plan_path: accepted, gate_path: GATE}, history)

        changed_gate = "# Changed gate\n"
        with self.assertRaisesRegex(Exception, "accepted gate"):
            _governance_history(
                {plan_path: accepted, gate_path: changed_gate}, history
            )

        for label, later in (
            (
                "mutate then restore",
                {plan_path: accepted, gate_path: changed_gate},
            ),
            ("delete then restore", {plan_path: accepted}),
        ):
            with self.subTest(label=label):
                traversed = (
                    "later",
                    (*history[1], ("later", ("accepted",), later)),
                )
                with self.assertRaisesRegex(Exception, "accepted gate|gate is missing"):
                    _governance_history(
                        {plan_path: accepted, gate_path: GATE}, traversed
                    )

        merged = (
            "merge",
            (
                ("root", (), {}),
                (
                    "accepted",
                    ("root",),
                    {plan_path: accepted, gate_path: GATE},
                ),
                (
                    "main",
                    ("root",),
                    {plan_path: plan(False), gate_path: changed_gate},
                ),
                (
                    "merge",
                    ("main", "accepted"),
                    {plan_path: accepted, gate_path: changed_gate},
                ),
            ),
        )
        with self.assertRaisesRegex(Exception, "accepted gate"):
            _governance_history(
                {plan_path: accepted, gate_path: changed_gate}, merged
            )

        open_history = (
            "open",
            (
                ("root", (), {}),
                (
                    "open",
                    ("root",),
                    {plan_path: plan(False), gate_path: GATE},
                ),
            ),
        )
        _governance_history(
            {plan_path: plan(False), gate_path: changed_gate}, open_history
        )

        noncanonical = "# Gate\r\n"
        with self.assertRaisesRegex(Exception, "UTF-8/LF"):
            _governance_history(
                {plan_path: accepted, gate_path: noncanonical},
                (
                    "accepted",
                    (
                        ("root", (), {}),
                        (
                            "accepted",
                            ("root",),
                            {plan_path: accepted, gate_path: noncanonical},
                        ),
                    ),
                ),
            )


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
