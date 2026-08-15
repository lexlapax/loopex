# Roadmap: Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Roadmap](roadmap.md#concept)

**Status: technical companion to non-normative capability guidance.** This file
retains candidate proof and freeze mechanics, the checked rejoin copy, decision
prerequisites, evidence sources, and unscheduled technical triggers.

Authority details: [Roadmap boundary](roadmap.md#concept-roadmap-boundary)

<a id="technical-roadmap-ladder"></a>
## The Ladder

Concept: [Capability ladder](roadmap.md#concept-roadmap-ladder)

| Concept link | Candidate proof | Possible freeze |
| --- | --- | --- |
| <a id="technical-roadmap-m0"></a>[Contract experiments — M0 candidate](roadmap.md#concept-roadmap-m0) | Journal write/replay, `commit_unknown` fencing and reconciliation across a restart, an isolated VM-code-loading/rollback feasibility spike that makes no extension-activation claim, and one real-provider slice. Experimental product code may be discarded; repository bootstrap mechanics may persist. | No product surface, by construction. |
| <a id="technical-roadmap-useful-local-kernel"></a>[Useful local kernel — v0.1 candidate](roadmap.md#concept-roadmap-useful-local-kernel) | Seven-tool loop, durable sessions, embedded API, JSONL RPC, line-oriented terminal client, restart/replay continuity. | No public freeze; surfaces remain experimental. |
| <a id="technical-roadmap-durable-service"></a>[Durable service — v0.2 candidate](roadmap.md#concept-roadmap-durable-service) | Reference daemon, race-free multi-client attachment, snapshots/cursors, ADR-selected durable store, protocol candidate. | No public freeze; the protocol remains experimental. |
| <a id="technical-roadmap-governed-extension-runtime"></a>[Governed extension runtime — v0.3 candidate](roadmap.md#concept-roadmap-governed-extension-runtime) | Extension manifest and namespaces, quiescent activation, state upgrade/downgrade fixtures, exact rollback. | Public-protocol release candidate and extension contribution API, each only if separately accepted after activation proof. |
| <a id="technical-roadmap-isolated-hands"></a>[Isolated hands — v0.4 candidate](roadmap.md#concept-roadmap-isolated-hands) | Executor gateway to an OS-isolated hand, promotion path, local and isolated conformance. | Executor protocol for proven local/isolated transports. |
| <a id="technical-roadmap-remote-ecosystem"></a>[Remote ecosystem — v0.5 candidate](roadmap.md#concept-roadmap-remote-ecosystem) | Broker, trusted-gateway distribution, ACP adapter, secured sample host, remote reconciliation. | Executor protocol for a proven remote transport; ACP mapping. |
| <a id="technical-roadmap-compatibility-baseline"></a>[Compatibility baseline — 1.0 candidate](roadmap.md#concept-roadmap-compatibility-baseline) | Materially different consumers, migration/rollback fixtures, exact packages and install smoke, protocol-v1 decision. | Only the surfaces whose independent freeze criteria pass. |

Freeze mechanics: [Compatibility and release governance](vision-technical.md#technical-vision-compatibility)

<a id="technical-roadmap-rejoin-order"></a>
## The Enduring Rejoin Order

Concept: [Enduring rejoin order](roadmap.md#concept-roadmap-rejoin-order)

Normative source: [Vision serial barriers](vision-technical.md#technical-vision-serial-barriers)

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

<a id="technical-roadmap-adr-agenda"></a>
## ADR Agenda by Capability

Concept: [Decision agenda](roadmap.md#concept-roadmap-adr-agenda)

Decision sources: [Repository seed agenda](vision-technical.md#technical-vision-repository-seed)
and [decision triggers](vision-technical.md#technical-vision-open-questions)

“Before” means before implementation or claimed proof: a plan candidate may
name an unresolved prerequisite and its acceptance point, but every
implementation-blocking prerequisite must be accepted before the plan and gate
can be accepted or product implementation can begin.

| Decision | Before | Why it blocks |
| --- | --- | --- |
| Repository and application layout | M0 gate | Dependency direction needs an accepted tree. ADR 0001 makes the first scaffold responsible for creating repository-owned enforcement and an adversarial illegal-reference fixture; the current Claude hook remains early feedback only. |
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

<a id="technical-roadmap-evidence"></a>
## Evidence Expectations

Concept: [Evidence expectations](roadmap.md#concept-roadmap-evidence)

Exact requirements: [Vision verification](vision-technical.md#technical-vision-verification)
and [AGENTS.md](../AGENTS.md) § Milestones and Gates. Each accepted plan selects
and locks its evidence classes and commands.

<a id="technical-roadmap-open-questions"></a>
## Open Questions Without a Milestone

Concept: [Open questions without a milestone](roadmap.md#concept-roadmap-open-questions)

The complete unscheduled trigger list is:

- Name, trademark, domain, and Hex clearance — before public packaging.
- Reference terminal richness and default active-tool profile — after measured
  prompt cost and task utility.
- Whether a reference memory extension belongs in-repo or in the ecosystem.
- Whether an always-in-context pinned-memory tier is core-supported or
  extension-simulated — before protocol-v1 freeze.
- Whether an official hands container or microVM image is a released artifact.
- Which future host first validates the security-rich embedding seam.
- What evidence would justify splitting an application or Hex package.

<a id="technical-roadmap-boundary"></a>
## What This File Is Not

Concept: [Boundary](roadmap.md#concept-roadmap-boundary)

Canonical milestone status and records live in
[docs/plans/README.md](plans/README.md); lifecycle authority lives in
[AGENTS.md](../AGENTS.md) § Milestones and Gates. This companion creates no
scope or authority.
