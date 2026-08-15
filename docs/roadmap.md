# Roadmap

**Status: non-normative capability guidance.** This file derives from
[docs/vision.md](vision.md) §20–§24 and §27. It helps plans and ADRs ask the
right questions in a sensible order; it creates no scope, authorizes no work,
and cannot weaken an invariant or resequence a serial barrier.

The canonical current status and actual milestone records live in
[docs/plans/README.md](plans/README.md). The lifecycle and authority rules live
in [AGENTS.md](../AGENTS.md) § Milestones and Gates. An accepted plan is the
commitment.

Candidate labels, capability contents, milestone boundaries, and release
allocation below the serial barriers remain revisable. An accepted plan may
split, combine, rename, resequence, or omit projected work while preserving the
founding boundaries. A milestone may cover part or all of one or more rungs;
its name does not grant release authority.

## The Ladder

Each rung asks one constitutional question from [vision §21](vision.md). The
working labels are navigation aids, not promised milestones or versions.

| Working label | Capability rung | Constitutional question | Candidate proof | Possible freeze |
| --- | --- | --- | --- | --- |
| **M0 candidate** | Contract experiments | Are session durability, effect truth, and VM-global trusted-code evolution feasible under the stated OTP semantics? | Journal write/replay, `commit_unknown` fencing and reconciliation across a restart, an isolated VM-code-loading/rollback feasibility spike that makes no extension-activation claim, and one real-provider slice. Experimental product code may be discarded; repository bootstrap mechanics may persist. | No product surface, by construction. |
| **v0.1 candidate** | Useful local kernel | Can one developer use a small, durable, truthful coding loop through the embedded API and reference client? | Seven-tool loop, durable sessions, embedded API, JSONL RPC, line-oriented terminal client, restart/replay continuity. | No public freeze; surfaces remain experimental. |
| **v0.2 candidate** | Durable service | Can independent clients attach, recover, and agree on one protocol candidate without owning session lifetime? | Reference daemon, race-free multi-client attachment, snapshots/cursors, ADR-selected durable store, protocol candidate. | No public freeze; the protocol remains experimental. |
| **v0.3 candidate** | Governed extension runtime | Can trusted behavior evolve without changing session truth, weakening authority, or pretending code is runtime-local? | Extension manifest and namespaces, quiescent activation, state upgrade/downgrade fixtures, exact rollback. | Public-protocol release candidate and extension contribution API, each only if separately accepted after activation proof. |
| **v0.4 candidate** | Isolated hands | Can generated and less-trusted work execute outside the brain through the same effects contract? | Executor gateway to an OS-isolated hand, promotion path, local and isolated conformance. | Executor protocol for proven local/isolated transports. |
| **v0.5 candidate** | Remote ecosystem | Can the contract span workers and materially different hosts without becoming a fleet or policy platform? | Broker, trusted-gateway distribution, ACP adapter, secured sample host, remote reconciliation. | Executor protocol for a proven remote transport; ACP mapping. |
| **1.0 candidate** | Compatibility baseline | Are public contracts proven by independent consumers, migrations, rollback, and packaged operation? | Materially different consumers, migration/rollback fixtures, exact packages and install smoke, protocol-v1 decision. | Only the surfaces whose independent freeze criteria pass. |

Compatibility surfaces do not freeze together
([vision §24.1](vision.md)): private journal schema, public protocol, executor
protocol, extension API, embedded Elixir API, and artifact formats each require
their own evidence and acceptance.

## The Enduring Rejoin Order

The ordering below is normative, but it is not defined here. It is the verbatim
rejoin order from [vision §22](vision.md), not the vision's complete capability,
compatibility, or freeze policy. The repository status check verifies the
complete fenced block inside both named sections.

<!-- loopex:rejoin-copy:start -->
```text
durable local session and operation truth
-> multi-client attachment and protocol candidate
-> extension namespaces plus VM-global activation proof
-> public protocol compatibility decision
-> isolated-hand conformance
-> remote-worker and multi-host compatibility evidence
```
<!-- loopex:rejoin-copy:end -->

Read vision §21–§22 and §24 for the other prerequisite evidence and freeze
criteria. Plans may move work below these barriers, never through them without
the decision required to amend the vision.

## ADR Agenda by Capability

The agenda derives from [vision §20.4](vision.md) and the decision triggers in
[vision §27](vision.md). “Before” names the earliest candidate capability that
cannot honestly proceed without the decision; it does not schedule a milestone.
For a capability rung, “before” means before implementation or claimed proof. A
plan candidate may identify unresolved ADR prerequisites and their acceptance
points, but every implementation-blocking prerequisite must be accepted before
the plan/gate can be accepted or product implementation can begin.

| Decision | Before | Why it blocks |
| --- | --- | --- |
| Repository and application layout | M0 gate | Dependency direction needs an accepted tree. Proposed ADR 0001 makes the first scaffold responsible for creating repository-owned enforcement and an adversarial illegal-reference fixture; the current Claude hook remains early feedback only. |
| Runtime floor and exact version pairs | M0 gate | The gate must name its Elixir/OTP pairs and toolchain before experiments can produce comparable evidence; M0 closure migrates repository checks and tested client-hook paths off the temporary Python/`jq` bridge. |
| Runtime instances and VM-global code ownership | Contract experiments | The code manager is the one deliberate VM-global exception; ownership precedes activation experiments. |
| Three durable transaction domains | Contract experiments | VM-code, runtime-control, and session truth have different identity, durability, and replay semantics. |
| Operation kinds and terminal semantics | Contract experiments | Attempt protocols, the closed outcome algebra, and reconciliation identity are what the experiments test. |
| Tool, executor, and grant contracts | Useful local kernel | The loop cannot dispatch effects before the job/receipt/grant shape exists. |
| Provider continuation and exact context staging | Useful local kernel | A model call dispatches only the exact canonical context committed with its intent. |
| Context pipeline contracts | Useful local kernel | The sole seam for memory, retrieval, and prompts includes provenance and budget rules. |
| Store selection and migrations | Durable service | A service makes operational and compatibility claims that the bootstrap adapters do not. |
| Public schemas and attachment delivery | Durable service | Snapshot-first attach and schemas precede a protocol release candidate. |
| Extension activation and rollback | Governed extension runtime | Quiescence, atomic module-set loading, and exact A→B→A rollback define the capability. |
| Isolated-hand threat model and sandbox backend | Isolated hands | Nothing may claim OS isolation before the backend is chosen and reviewed. |
| Remote-hand threat model and transport | Remote ecosystem | Distribution connects trusted gateways only; the transport gates remote claims. |
| ACP mapping and protocol-v1 criteria | Before compatibility baseline | ACP mapping precedes the protocol-v1 freeze decision. |
| Compatibility and deprecation policy | Compatibility baseline | Additive-field rules, unknown-value handling, deprecation, and upgrade span need explicit acceptance. |

Use the `adr` skill. ADRs decide among valid designs; they do not log reversible
implementation choices.

## Evidence Expectations

Evidence is claim-proportional under [vision §23](vision.md) and
[AGENTS.md](../AGENTS.md) § Milestones and Gates: properties for reducers,
conformance at replaceable boundaries, fault injection for durable transitions,
vectors for protocols, negative tests for trust, and real-path/package evidence
when those claims are made. Each accepted plan selects and locks its exact
evidence classes and commands.

## Open Questions Without a Milestone

These have triggers rather than dates. Listing them does not schedule them:

- Name, trademark, domain, and Hex clearance — before public packaging.
- Reference terminal richness and default active-tool profile — after measured
  prompt cost and task utility.
- Whether a reference memory extension belongs in-repo or in the ecosystem.
- Whether an always-in-context pinned-memory tier is core-supported or
  extension-simulated — before protocol-v1 freeze.
- Whether an official hands container or microVM image is a released artifact.
- Which future host first validates the security-rich embedding seam.
- What evidence would justify splitting an application or Hex package.

## What This File Is Not

It is not a backlog, commitment, release schedule, current-status record, or
source of authority. Keep it as a compact projection; git holds its history.
