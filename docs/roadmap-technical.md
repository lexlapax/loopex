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
| <a id="technical-roadmap-useful-local-kernel"></a>[Useful local kernel — v0.1 candidate](roadmap.md#concept-roadmap-useful-local-kernel) | Three milestones over the durable single-machine kernel M1 delivered: a loop a developer uses through the embedded API and reference client, a consolidation milestone that closes that loop's recorded debt and locks its post-closure regressions before another surface is built on it, then the language-neutral boundary an independent program drives. Restart and replay remain the continuity mechanism across all three. | No public freeze; surfaces remain experimental. |
| <a id="technical-roadmap-foreground-harness"></a>[Foreground coding harness — M2 candidate](roadmap.md#concept-roadmap-foreground-harness) | Multi-turn loop over committed conversation history with real tool results returned to the model; runtime-scoped tool registry with recorded definition generations; the `read`, `write`, `edit`, and `bash` bootstrap profile under one shared conformance suite; host policy that refuses before any process starts; truthful same-process cancellation; streaming progress; session discovery and resume; a one-page embedded composition; a `loopex` terminal command; an attended real-provider coding demonstration. | None. No version is tagged and no surface is published. |
| <a id="technical-roadmap-kernel-consolidation"></a>[Kernel consolidation — M3 candidate](roadmap.md#concept-roadmap-kernel-consolidation) | Every regression the post-closure hotfix overrides added locked in a gate; ADR 0017 evaluation step 5 implemented; Store I/O removed from the event dispatcher's call handler; spent provider-attempt retention bounded; a structurally verified closed-gate aggregate; the frozen test-honesty weaknesses two independent audits recorded, repaired; and the bootstrap runtime floor raised by amendment to ADR 0002 across three gate generations. | None. No new surface, no version tagged, nothing published. |
| <a id="technical-roadmap-session-protocol"></a>[Headless session protocol — M4 candidate](roadmap.md#concept-roadmap-session-protocol) | Long-lived stdio JSONL boundary; exact versioned JSON Schema-compatible DTO bundle with golden vectors; initialization and capability negotiation; session, prompt, steer, follow-up, abort, interaction, snapshot, and cursor methods; command admission separated from asynchronous completion; transient streaming mapped from the harness input and progress algebra; durable interaction identity distinct from transport request ID; sample clients. | No public freeze; the protocol remains experimental, and the projected `0.1.0` tag is a source-tree version rather than a compatibility claim. |
| <a id="technical-roadmap-durable-service"></a>[Durable service — v0.2 candidate](roadmap.md#concept-roadmap-durable-service) | M5: daemon-owned session lifetime, Unix-domain-socket transport, concurrent independent clients, one-controller/many-observer collaboration with stale-controller fencing and crash takeover, race-free snapshot and cursor replay, backpressure, residency and eviction, an ADR-selected daemon-grade store with migration, cross-process cancellation. | No public freeze; the protocol remains experimental. |
| <a id="technical-roadmap-governed-extension-runtime"></a>[Governed extension runtime — v0.3 candidate](roadmap.md#concept-roadmap-governed-extension-runtime) | Extension manifest and namespaces, quiescent activation, state upgrade/downgrade fixtures, exact rollback. | Public-protocol release candidate and extension contribution API, each only if separately accepted after activation proof. |
| <a id="technical-roadmap-isolated-hands"></a>[Isolated hands — v0.4 candidate](roadmap.md#concept-roadmap-isolated-hands) | Executor gateway to an OS-isolated hand, promotion path, local and isolated conformance. | Executor protocol for proven local/isolated transports. |
| <a id="technical-roadmap-remote-ecosystem"></a>[Remote ecosystem — v0.5 candidate](roadmap.md#concept-roadmap-remote-ecosystem) | Broker, trusted-gateway distribution, ACP adapter, secured sample host, remote reconciliation. | Executor protocol for a proven remote transport; ACP mapping. |
| <a id="technical-roadmap-compatibility-baseline"></a>[Compatibility baseline — 1.0 candidate](roadmap.md#concept-roadmap-compatibility-baseline) | Materially different consumers, migration/rollback fixtures, exact packages and install smoke, protocol-v1 decision. | Only the surfaces whose independent freeze criteria pass. |

Freeze mechanics: [Compatibility and release governance](vision-technical.md#technical-vision-compatibility)

Transport order: [Embedded API, transports, and clients](vision-technical.md#technical-vision-api-transports)
places §18.2 JSONL RPC before §18.3 Reference daemon, and the paired
[concept section](vision.md#concept-vision-api-transports) names JSONL RPC, a
daemon, and a terminal client in that order. A daemon built first would
standardize attachment, cursor, and transport semantics around a loop no
operator has driven. Proving the boundary against a working harness first leaves
the daemon what the vision says it is: an adapter and reference host.

Tool profile: the bootstrap profile is the four tools the
[tools section](vision-technical.md#technical-vision-tools) names — `read`,
`write`, `edit`, and `bash`. `grep`, `find`, and `ls` stay in the reference
seven, and activating them by default remains evidence-selected against measured
prompt cost, shell avoidance, safety, and task utility. No rung here promises a
seven-tool default.

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
| Tool, executor, and grant contracts | `M2` acceptance | The loop cannot dispatch effects before the job/receipt/grant shape exists. ADR 0009 carries it. |
| Provider continuation and exact context staging | `M2` acceptance | A model call dispatches only the exact canonical context committed with its intent, and a multi-turn loop restages that context on every turn. ADR 0010 carries it. |
| Session input algebra and streaming progress | `M2` acceptance | Prompt, steer, follow-up, and abort form one closed admission algebra, and transient progress must stay outside durable truth before any transport projects it. ADR 0011 carries it. |
| Context pipeline contracts | The first milestone that stages retrieved or remembered context | The sole seam for memory, retrieval, and prompts includes provenance and budget rules; exact staging alone does not settle what may enter the seam. |
| Public DTO and schema bundle, versioning, and capability negotiation | `M4` | A published wire boundary needs its exact schema bytes, version identity, unknown-field rule, and negotiation handshake before independent clients depend on it. |
| Durable interaction identity | `M4` | An interaction outlives the transport request that carried it, so its identity cannot be a transport request ID. |
| Store selection and migrations | `M5` | A service makes operational and compatibility claims that the bootstrap adapters do not. |
| Attachment delivery, cursor replay, and residency | `M5` | Snapshot-first attach, replay position, and eviction decide what a reconnecting client is owed, and they precede a protocol release candidate. |
| Collaboration policy: controller leases, observers, and takeover | `M5` | Concurrent clients need one fencing and takeover rule before a daemon claims multi-client truth. |
| Extension activation and rollback | Governed extension runtime | Quiescence, atomic module-set loading, and exact A→B→A rollback define the capability. |
| Extension packaging, acquisition, and installation | Whichever comes first: the first out-of-repository extension, or the first published package | Distinct from activation. [ADR 0003](adr/0003-extension-contract-boundary.md#concept) fixes the contributor-facing boundary and defers the installation pipeline, closure conflict resolution, signing and provenance formats, host configuration schema, and registry acquisition until a runtime and manifest implementation supply the evidence. |
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
- Reference terminal richness, and whether `grep`, `find`, and `ls` join the
  default active-tool profile beside the four bootstrap tools — after measured
  prompt cost, shell avoidance, safety, and task utility.
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
