# Archive

Part of the [documentation index](../README.md).

This directory contains materially distinct historical seed inputs retained for
provenance, and one milestone draft that is written but not yet opened.
Archived files are non-normative: none carries a lifecycle state, a register
row, or any authority, and current authority follows the root `AGENTS.md`. Do
not bulk-read them or use them as implementation guidance. Consult them for an
explicit provenance or historical-comparison task, or — for the unopened
milestone draft the last row names — when its milestone is opened.

Git history preserves byte-identical snapshots, so copies of current files do
not belong here. Keep historical seed material immutable. The unopened M4 draft may be revised
under an explicit maintainer planning request; its prior versions stay in Git.

| Files | Origin and reason retained |
| --- | --- |
| `loopex-plan-draft.md`, `loopex-vision-draft.md` | Pre-repository Loopex working drafts retained to explain the founding design's evolution. |
| `pilex-plan-01.md`, `pilex-plan-02.md` | Predecessor-name planning inputs retained for naming and architectural provenance. |
| `loopex-dotclaude-kit.md`, `loopex-dotclaude-settings.json`, `loopex-dotcodex-kit.md`, `loopex-dotgitignore.md`, `loopex-CLAUDE.md` | Original client-adapter seed material retained to compare installed adapters with their source kit. |
| `daemon-draft-M2*.md`, `daemon-draft-0008*.md`, `daemon-draft-0009*.md`, `daemon-draft-0010*.md` | A superseded multi-client daemon milestone draft, written against the pre-closure `M1` tree and never accepted. Retained as design input for the later durable-service milestone, whose questions it states well: session lifetime independent of clients, exact snapshot and cursor attachment, bounded slow-observer handling, one-controller many-observer policy, crash takeover, residency, and daemon-kill recovery evidence. Its sequencing, `M2` naming, ADR numbering, deferred stdio, and store and protocol dispositions do not carry forward. |
| `M4.md`, `M4-technical.md`, `M4-gate.md` | Unopened headless external-consumer draft, revised under the current maintainer request to use M3's skills, durable interactions and artifact foundations. It has no register row or implementation authority. Its previous debt/protocol split remains at `d0699b6dc636c7e74b95082d0d8241968381927d`. Opening requires the permitted predecessor base, moving the triple into docs/plans, complete executable readiness and fresh review. [ADR 0023](../adr/0023-experimental-public-session-protocol.md#concept) owns the protocol; [ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) now belongs to M3. |
