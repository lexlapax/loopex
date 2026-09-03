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
| [operator/](operator/README.md) | Coding-session, tool, policy, runtime, shutdown, and recovery runbooks. |
| [developer/](developer/README.md) | Development method, routing, and retained client evidence. |
| [adr/](adr/README.md) | Numbered architecture decisions and their governance records. |
| [plans/](plans/README.md) | Milestone register, lifecycle, plan templates, and current status. |
| [evidence/](evidence/README.md) | Retained gate run evidence. |
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
| 0004 — plan amendment and supersession | [Decision](adr/0004-plan-amendment-supersession.md#concept) | [Technical depth](adr/0004-plan-amendment-supersession-technical.md#technical-depth) |
| 0005 — milestone supersession | [Decision](adr/0005-milestone-supersession.md#concept) | [Technical depth](adr/0005-milestone-supersession-technical.md#technical-depth) |
| 0006 — store transaction and owner epoch | [Decision](adr/0006-store-transaction-and-owner-epoch.md#concept) | [Technical depth](adr/0006-store-transaction-and-owner-epoch-technical.md#technical-depth) |
| 0007 — local executor grant, job, and receipt | [Decision](adr/0007-local-executor-grant-job-receipt.md#concept) | [Technical depth](adr/0007-local-executor-grant-job-receipt-technical.md#technical-depth) |
| 0008 — owner succession recovery and runtime placement | [Decision](adr/0008-owner-succession-recovery-and-runtime-placement.md#concept) | [Technical depth](adr/0008-owner-succession-recovery-and-runtime-placement-technical.md#technical-depth) |
| 0009 — tool, executor, and grant contracts | [Decision](adr/0009-tool-executor-and-grant-contracts.md#concept) | [Technical depth](adr/0009-tool-executor-and-grant-contracts-technical.md#technical-depth) |
| 0010 — provider continuation and exact context staging | [Decision](adr/0010-provider-continuation-and-context-staging.md#concept) | [Technical depth](adr/0010-provider-continuation-and-context-staging-technical.md#technical-depth) |
| 0011 — session input algebra and streaming progress | [Decision](adr/0011-session-input-algebra-and-streaming.md#concept) | [Technical depth](adr/0011-session-input-algebra-and-streaming-technical.md#technical-depth) |
| 0012 — executor cancellation capability | [Decision](adr/0012-executor-cancellation-capability.md#concept) | [Technical depth](adr/0012-executor-cancellation-capability-technical.md#technical-depth) |
| 0013 — run-deadline commitment at first request staging | [Decision](adr/0013-run-deadline-commitment-at-first-request-staging.md#concept) | [Technical depth](adr/0013-run-deadline-commitment-at-first-request-staging-technical.md#technical-depth) |
| 0014 — stream closure at owner loss | [Decision](adr/0014-stream-closure-at-owner-loss.md#concept) | [Technical depth](adr/0014-stream-closure-at-owner-loss-technical.md#technical-depth) |
| 0015 — artifact object and use identity | [Decision](adr/0015-artifact-object-and-use-identity.md#concept) | [Technical depth](adr/0015-artifact-object-and-use-identity-technical.md#technical-depth) |
| 0016 — configured cancellation observation | [Decision](adr/0016-configured-cancellation-observation.md#concept) | [Technical depth](adr/0016-configured-cancellation-observation-technical.md#technical-depth) |
| 0017 — durable context and record admission budgets | [Decision](adr/0017-durable-context-admission-budget.md#concept) | [Technical depth](adr/0017-durable-context-admission-budget-technical.md#technical-depth) |
| 0018 — provider attempt authority and recovery | [Decision](adr/0018-provider-attempt-authority-and-recovery.md#concept) | [Technical depth](adr/0018-provider-attempt-authority-and-recovery-technical.md#technical-depth) |

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
- [Coding sessions](operator/coding-sessions.md#concept) — running, streaming,
  steering, resuming, and stopping a coding task with the `loopex` command, the
  project-resource trust decision, the configuration a resumed session recovers,
  and what stopping does and does not promise.
- [Tools and policy](operator/tools-and-policy.md#concept) — the four coding
  tools, what local execution reaches, host authority, artifacts and how to read
  one back, and what the local store keeps on disk.
- [Runtime operations and first run](operator/runtime.md#concept) — current
  source-tree features, exact working-loop demonstrations, credentials, events,
  shutdown, and recovery.
- [Agent loop and tools](developer/agent-loop-and-tools.md#concept) — the
  multi-turn loop, tool contract and registry, bounds, stream domains, host
  authority, artifacts, and project resources.
- [Compatibility surfaces](developer/compatibility-surfaces.md#concept) — every
  surface M2 touches, all unstable, none labelled or frozen, and what that means
  for an embedder.
- [Runtime and embedding](developer/runtime-and-embedding.md#concept) —
  application shape, ports, composition, commit ordering, embedded API, and
  recovery mechanics.
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
