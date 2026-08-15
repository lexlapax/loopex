# Documentation

Loopex documentation starts with the idea, expectation, or decision and links
to the exact technical depth needed to implement and verify it. Read the
Concept document first, then follow only the technical links relevant to the
work at hand.

New here? [Developer documentation](developer/README.md) carries the reading
order. This file is the index of what exists.

## Directories

| Directory | Contents |
| --- | --- |
| [developer/](developer/README.md) | Development method, routing, and retained client evidence. |
| [adr/](adr/README.md) | Numbered architecture decisions and their governance records. |
| [plans/](plans/README.md) | Milestone register, lifecycle, plan templates, and current status. |
| [archive/](archive/README.md) | Non-normative historical inputs, retained for provenance. |

Every directory under `docs/` carries a `README.md` describing its contents and
linking back here; this file links back to the
[root README](../README.md). The repository status check enforces that chain, so
a new document cannot be reachable only by knowing it exists.

The [development charter](developer/development-charter.md#concept) explains this
structure. Its
[technical companion](developer/development-charter-technical.md#technical-depth) defines the
pairing, link, review, code-documentation, and enforcement contracts.

## Founding Direction

| Area | Concept | Technical depth | Role |
| --- | --- | --- | --- |
| Product vision | [Vision](vision.md#concept) | [Vision technical depth](vision-technical.md#technical-depth) | Founding authority; the pair is one source. |
| Capability guidance | [Roadmap](roadmap.md#concept) | [Roadmap technical depth](roadmap-technical.md#technical-depth) | Non-normative projection; accepted plans authorize work. |
| Development method | [Development charter](developer/development-charter.md#concept) | [Charter technical depth](developer/development-charter-technical.md#technical-depth) | Shared development form and review expectations. |

## Decisions

| Decision | Concept | Technical depth |
| --- | --- | --- |
| 0001 — repository and application layout | [Decision](adr/0001-repository-and-application-layout.md#concept) | [Technical depth](adr/0001-repository-and-application-layout-technical.md#technical-depth) |
| 0002 — bootstrap runtime floor | [Decision](adr/0002-bootstrap-runtime-floor.md#concept) | [Technical depth](adr/0002-bootstrap-runtime-floor-technical.md#technical-depth) |
| 0003 — extension contract boundary | [Decision](adr/0003-extension-contract-boundary.md#concept) | [Technical depth](adr/0003-extension-contract-boundary-technical.md#technical-depth) |

An ADR pair is one decision. Its status and governance record live in the
Concept file and bind both files when accepted.

Every active substantive pair appears in this index. The repository status
check rejects an unindexed pair, a missing companion, or a local Markdown link
whose path or explicit fragment does not resolve.

## Planning and Development

- [Development contract](../AGENTS.md) — canonical tool-neutral authority,
  autonomy, documentation, milestone, and enforcement rules.
- [Plans and current status](plans/README.md) — canonical milestone register,
  lifecycle, and plan templates. A future milestone has a Concept plan,
  Technical depth plan, and executable gate.
- [Development setup](../DEVELOPMENT.md) — local prerequisites and validation
  commands.
- [Context map](developer/agent-context-map.md) — task-oriented routing into
  Concept first and exact Technical depth second.
- [Adapter smoke evidence](developer/agent-adapter-smoke.md) — retained
  client-loading and parity evidence.
- [Changelog](../CHANGELOG.md) — notable repository and release changes.

These are indexes, runbooks, status records, evidence logs, or canonical
development entrypoints. They are deliberately unpaired and may link both
depths.

## Historical Material

[The archive](archive/README.md) preserves non-normative historical inputs.
Archived bytes are not rewritten or paired; current decisions and guidance live
in the active documents above.
