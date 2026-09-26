# Documentation

Loopex documentation starts with the idea, expectation, or decision and links
to the exact technical depth needed to implement and verify it. Read the
Concept document first, then follow only the technical links relevant to the
work at hand.

New here? Running Loopex starts at the
[operator getting-started guide](operator/getting-started.md). Building on Loopex
or contributing to it starts at the
[developer getting-started guide](developer/getting-started.md#concept). This file
is the index of what exists.

## Directories

| Directory | Contents |
| --- | --- |
| [operator/](operator/README.md) | Runbooks for running Loopex: getting started, coding sessions and project skills, tools and policy, the daemon, the app server, observability, and how a run works. |
| [developer/](developer/README.md) | Building on Loopex and contributing to it: getting started, architecture, embedding, the agent loop, protocols, the daemon, observability, compatibility, and the development method. |
| [adr/](adr/README.md) | Numbered architecture decisions and their governance records. |
| [plans/](plans/README.md) | Milestone register, lifecycle, plan templates, and current status. |
| [evidence/](evidence/README.md) | Retained check-run and demonstration evidence, named by the revision it was taken at. |
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
| Developer getting started | [Getting started](developer/getting-started.md#concept) | [Getting started technical depth](developer/getting-started-technical.md#technical-depth) | Two tracks: building on Loopex (embedding a runtime, driving the session protocol) and contributing (toolchain, checks, milestones). |
| System architecture | [Architecture](developer/architecture.md#concept) | [Architecture technical depth](developer/architecture-technical.md#technical-depth) | Descriptive: applications, ports, truth planes, and invariants as implemented; accepted ADRs remain the deciding authority. |
| Development method | [Development charter](developer/development-charter.md#concept) | [Charter technical depth](developer/development-charter-technical.md#technical-depth) | Shared development form and review expectations. |
| Public session protocol | [App server protocol](developer/app-server-protocol.md#concept) | [Protocol technical depth](developer/app-server-protocol-technical.md#technical-depth) | The experimental wire generation; accepted ADR 0023 remains the deciding authority. |
| Daemon | [The daemon](developer/daemon.md#concept) | [Daemon technical depth](developer/daemon-technical.md#technical-depth) | The host that keeps a root's sessions alive between processes; ADRs 0031–0034 carry its decisions. |
| Observability | [Observability](developer/observability.md#concept) | [Observability technical depth](developer/observability-technical.md#technical-depth) | Trace sessions and the telemetry inventory as the diagnostics plane; accepted ADR 0030 fixes the inventory. |
| Verification | [Verification](developer/verification.md#concept) | [Verification technical depth](developer/verification-technical.md#technical-depth) | The rule book for checking work now that the milestone gates are retired: three stages, check selection by changed boundary, the honesty rules, and the measured speed plan. |
| Milestones | [Milestones](developer/milestones.md#concept) | [Milestones technical depth](developer/milestones-technical.md#technical-depth) | How to plan, run and close a milestone under the post-M4 structure, and the skills that carry the procedures. |

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
| 0019 — host-owned provider protection | [Decision](adr/0019-host-owned-provider-protection.md#concept) | [Technical depth](adr/0019-host-owned-provider-protection-technical.md#technical-depth) |
| 0020 — explicit prepared handoff | [Decision](adr/0020-explicit-prepared-handoff.md#concept) | [Technical depth](adr/0020-explicit-prepared-handoff-technical.md#technical-depth) |
| 0021 — compacted provider-accounting provenance | [Decision](adr/0021-compacted-provider-accounting-provenance.md#concept) | [Technical depth](adr/0021-compacted-provider-accounting-provenance-technical.md#technical-depth) |
| 0022 — local executor supervision shell | [Decision](adr/0022-local-executor-supervision-shell.md#concept) | [Technical depth](adr/0022-local-executor-supervision-shell-technical.md#technical-depth) |
| 0023 — experimental public session protocol | [Decision](adr/0023-experimental-public-session-protocol.md#concept) | [Technical depth](adr/0023-experimental-public-session-protocol-technical.md#technical-depth) |
| 0024 — durable interaction lifecycle and host-policy authority | [Decision](adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) | [Technical depth](adr/0024-durable-interaction-lifecycle-and-host-policy-authority-technical.md#technical-depth) |
| 0025 — resource packs and skill admission | [Decision](adr/0025-resource-packs-and-skill-admission.md#concept) | [Technical depth](adr/0025-resource-packs-and-skill-admission-technical.md#technical-depth) |
| 0026 — development floor refresh | [Decision](adr/0026-development-floor-refresh.md#concept) | [Technical depth](adr/0026-development-floor-refresh-technical.md#technical-depth) |
| 0027 — provider permit retirement | [Decision](adr/0027-provider-permit-retirement.md#concept) | [Technical depth](adr/0027-provider-permit-retirement-technical.md#technical-depth) |
| 0028 — bounded artifact retrieval | [Decision](adr/0028-bounded-artifact-retrieval.md#concept) | [Technical depth](adr/0028-bounded-artifact-retrieval-technical.md#technical-depth) |
| 0029 — bounded provider failure diagnostics | [Decision](adr/0029-bounded-provider-failure-diagnostics.md#concept) | [Technical depth](adr/0029-bounded-provider-failure-diagnostics-technical.md#technical-depth) |
| 0030 — observability: tracing and telemetry | [Decision](adr/0030-observability-tracing-and-telemetry.md#concept) | [Technical depth](adr/0030-observability-tracing-and-telemetry-technical.md#technical-depth) |
| 0031 — daemon store selection for `0.2.0` | [Decision](adr/0031-daemon-grade-store-selection-and-migration.md#concept) | [Technical depth](adr/0031-daemon-grade-store-selection-and-migration-technical.md#technical-depth) |
| 0032 — daemon attachment residency and replay | [Decision](adr/0032-daemon-attachment-residency-and-replay.md#concept) | [Technical depth](adr/0032-daemon-attachment-residency-and-replay-technical.md#technical-depth) |
| 0033 — collaboration: controller lease and takeover | [Decision](adr/0033-collaboration-controller-lease-and-takeover.md#concept) | [Technical depth](adr/0033-collaboration-controller-lease-and-takeover-technical.md#technical-depth) |
| 0034 — provider credential handoff over the bootstrap channel | [Decision](adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept) | [Technical depth](adr/0034-provider-credential-handoff-over-bootstrap-channel-technical.md#technical-depth) |
| 0035 — typed decision models as policy inputs | [Decision](adr/0035-typed-decision-models-as-policy-inputs.md#concept) | [Technical depth](adr/0035-typed-decision-models-as-policy-inputs-technical.md#technical-depth) |
| 0036 — daemon-grade store engine and migration | [Decision](adr/0036-daemon-grade-store-engine-and-migration.md#concept) | [Technical depth](adr/0036-daemon-grade-store-engine-and-migration-technical.md#technical-depth) |
| 0037 — host configuration and path discovery | [Decision](adr/0037-host-configuration-and-path-discovery.md#concept) | [Technical depth](adr/0037-host-configuration-and-path-discovery-technical.md#technical-depth) |
| 0038 — installed distribution and release artifact | [Decision](adr/0038-installed-distribution-and-release-artifact.md#concept) | [Technical depth](adr/0038-installed-distribution-and-release-artifact-technical.md#technical-depth) |

An ADR pair is one decision. Its status and governance record live in the
Concept file and bind both files when accepted.

Every active substantive pair appears in this index. The repository status
check rejects an unindexed pair, a missing companion, or a local Markdown link
whose path or explicit fragment does not resolve.

## Planning and Development

- [M3 foundations](plans/M3.md#concept) and [technical plan](plans/M3-technical.md#technical-depth) — project skills and core repairs; Closed with retained evidence in the plan.
- [M4 headless external consumption](plans/M4.md#concept) and [technical plan](plans/M4-technical.md#technical-depth) — durable interactions, artifact transfers, the floor refresh, observability, and the experimental session protocol driven by an independent Node consumer in plain JavaScript; Closed, with its runs in [M4 closure runs](evidence/M4-closure-runs.md).
- [M5 durable service](plans/M5.md#concept) and [technical plan](plans/M5-technical.md#technical-depth) — daemon-owned session lifetime on the ADR-selected local store within its documented limits, generation-2-only Unix-domain-socket transport, in-memory controller lease with observers and takeover, and at-least-once replay with residency limits over M4. The [plans register](plans/README.md) carries its current state.
- [M6 installed durable operator](plans/M6.md#concept) and [technical plan](plans/M6-technical.md#technical-depth) — the `0.3.0` candidate: one platform-specific release archive with the runtime bundled, saved and validated host configuration under a default home, a daemon-grade store with explicit migration, backup and restore, and the operator lifecycle commands, all proved from an installed artifact; Open beside the accepted M5 and not acceptable before M5 closes.

- [Development contract](../AGENTS.md) — canonical tool-neutral authority,
  autonomy, documentation, milestone, and enforcement rules.
- [Plans and current status](plans/README.md) — canonical milestone register,
  lifecycle, and plan templates. A milestone has a Concept plan and a Technical
  depth plan.
- [Development setup](../DEVELOPMENT.md) — local prerequisites and validation
  commands.
- [How a run works](operator/how-a-run-works.md#concept) — the flow of one run
  from the prompt to the answer with its diagram, the components and where each
  runs, what is durable at every step, and what a crash at each stage leaves
  behind.
- [Coding sessions](operator/coding-sessions.md#concept) — running, streaming,
  steering, resuming, and stopping a coding task with the `loopex` command, the
  project-resource trust decision, the configuration a resumed session recovers,
  and what stopping does and does not promise.
- [Tools and policy](operator/tools-and-policy.md#concept) — the four coding
  tools, what local execution reaches, host authority, artifacts and how to read
  one back, and what the local store keeps on disk.
- [Runtime operations](operator/runtime.md#concept) — the embedded runtime, a
  credential-free demonstration of the loop, lifecycle, credentials, and crash
  recovery.
- [Operator getting started](operator/getting-started.md) — build Loopex from
  source, run and observe a first coding session, stop it cleanly, and run it
  through a daemon.
- [The daemon](operator/daemon.md#concept) — running the durable local daemon,
  connecting clients, observing and taking over a session, stopping it, and its
  exit statuses.
- [App server operations](operator/app-server.md#concept) — running the
  foreground session-protocol server and driving it from a client.
- [Observability](operator/observability.md#concept) — starting a trace session
  and reading bounded, redacted telemetry.
- [Agent loop and tools](developer/agent-loop-and-tools.md#concept) — the
  multi-turn loop, tool contract and registry, bounds, stream domains, host
  authority, artifacts, and project resources.
- [Compatibility surfaces](developer/compatibility-surfaces.md#concept) — what
  each public surface promises today, what is experimental, and what that means
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
