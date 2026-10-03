#!/usr/bin/env python3
"""Report the original M7 checklist and added subtasks separately from the implementation ledger."""

from pathlib import Path
import re
import sys


def task_counts(source):
    tasks = {}
    task = section = None
    for line in source.splitlines():
        heading = re.fullmatch(r"## (T\d{2}) — .+", line)
        if heading:
            task = heading[1]
            if task in tasks:
                raise ValueError(f"duplicate task heading: {task}")
            tasks[task] = {"original": [0, 0, 0], "added": [0, 0, 0]}
            section = None
        elif line.startswith("## "):
            task = section = None
        elif line.startswith("### "):
            section = {
                "### Original checklist": "original",
                "### Added implementation subtasks": "added",
            }.get(line)
        elif task and section:
            checkbox = re.fullmatch(r"- \[([ x-])\] .+", line)
            if checkbox:
                tasks[task][section][{"x": 0, " ": 1, "-": 2}[checkbox[1]]] += 1
            elif line.startswith("- ["):
                raise ValueError(f"unsupported checklist status: {line}")

    expected = [f"T{number:02d}" for number in range(20)]
    if list(tasks) != expected:
        raise ValueError("expected exactly T00–T19, in order")
    if any(sum(row["original"]) == 0 for row in tasks.values()):
        raise ValueError("each task requires its original checklist")
    if sum(sum(row["original"]) for row in tasks.values()) != 186:
        raise ValueError("the supplied original checklist must retain its 186 items")
    return tasks


def main():
    if len(sys.argv) != 1:
        raise ValueError("usage: python3 scripts/m7-task-status.py")
    ledger = Path(__file__).resolve().parent.parent / "docs/evidence/M7-implementation-tasks.md"
    tasks = task_counts(ledger.read_text(encoding="utf-8"))
    print("| Task | Original done / todo / retired | Added done / todo / retired |")
    print("|---|---:|---:|")
    for task, row in tasks.items():
        original, added = row["original"], row["added"]
        print(f"| {task} | {original[0]} / {original[1]} / {original[2]} | {added[0]} / {added[1]} / {added[2]} |")
    for section in ("original", "added"):
        done, todo, retired = (
            sum(row[section][index] for row in tasks.values()) for index in (0, 1, 2)
        )
        print(f"\n{section.capitalize()}: {done} done / {todo} todo / {retired} retired.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"m7-task-status: {error}", file=sys.stderr)
        sys.exit(1)
