# Archive

Part of the [documentation index](../README.md).

This directory contains materially distinct historical seed inputs retained
only for provenance. Archived files are non-normative; current authority follows
the root `AGENTS.md`. Do not bulk-read or use them as implementation guidance.
Consult them only for an explicit provenance or historical-comparison task.

Git history preserves byte-identical snapshots, so copies of current files do
not belong here. Keep retained material immutable.

| Files | Origin and reason retained |
| --- | --- |
| `loopex-plan-draft.md`, `loopex-vision-draft.md` | Pre-repository Loopex working drafts retained to explain the founding design's evolution. |
| `pilex-plan-01.md`, `pilex-plan-02.md` | Predecessor-name planning inputs retained for naming and architectural provenance. |
| `loopex-dotclaude-kit.md`, `loopex-dotclaude-settings.json`, `loopex-dotcodex-kit.md`, `loopex-dotgitignore.md`, `loopex-CLAUDE.md` | Original client-adapter seed material retained to compare installed adapters with their source kit. |
| `daemon-draft-M2*.md`, `daemon-draft-0008*.md`, `daemon-draft-0009*.md`, `daemon-draft-0010*.md` | A superseded multi-client daemon milestone draft, written against the pre-closure `M1` tree and never accepted. Retained as design input for the later durable-service milestone, whose questions it states well: session lifetime independent of clients, exact snapshot and cursor attachment, bounded slow-observer handling, one-controller many-observer policy, crash takeover, residency, and daemon-kill recovery evidence. Its sequencing, `M2` naming, ADR numbering, deferred stdio, and store and protocol dispositions do not carry forward. |
