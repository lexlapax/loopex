# Loopex — Founding Vision

<a id="concept"></a>
## Concept

Technical depth: [Founding vision technical depth](vision-technical.md#technical-depth)

Status: **standalone repository seed — founding document**

Date: **2026-08-14**

Project: **Loopex — “the loop, in Elixir”**

Repository: **[github.com/lexlapax/loopex](https://github.com/lexlapax/loopex)**

License: **Apache-2.0**

Public name: **provisional pending trademark, domain, package, and repository clearance**

Loopex is an OTP-native, embeddable runtime for durable coding sessions and
controlled effects. It makes a small model loop supervised, recoverable,
attachable, and useful without turning the loop into a framework of its own.
Its doctrine is **“the runtime is the framework.”**

This file explains the product boundary and the guarantees visible at that
boundary. Its companion carries the exact contracts and evidence behind those
guarantees. The two files are one founding authority; neither can be accepted,
amended, or interpreted in isolation.

<a id="concept-vision-purpose-authority"></a>
### 1. Purpose and authority

The founding vision defines Loopex’s durable product boundary, principles,
language, correctness expectations, ecosystem posture, and delivery sequence.
It is not a frozen wire schema, release contract, operational runbook, or
permission to build every described capability at once.

Technical depth: [Authority order and amendment rules](vision-technical.md#technical-vision-purpose-authority)

A current maintainer decision, or a decision made under recorded delegated scope, leads.
Released contracts and accepted security or
architecture decisions follow, then accepted active plans, this vision pair,
and historical material. Later records may refine or select from the vision,
but a founding boundary or invariant changes only through an explicit decision
that covers evidence, compatibility, and migration.

<a id="concept-vision-executive-thesis"></a>
### 2. Executive thesis

Loopex turns a model loop into a supervised, durable Elixir service. One
session can continue while clients disconnect, coordinate concurrent work while
serializing truth, place effects on local or remote hands, and report uncertain
outcomes honestly.

Technical depth: [OTP mechanisms and the additional contracts they require](vision-technical.md#technical-vision-executive-thesis)

OTP supplies process isolation, supervision, concurrency, distribution, and
code-loading mechanisms. Loopex adds identity, durable intent, receipts,
fencing, reconciliation, versioned protocols, backpressure, and trust
boundaries where the runtime alone cannot supply the product guarantee.

<a id="concept-vision-product-definition"></a>
### 3. Product definition

Loopex is a coding-session runtime, an effects runtime, an embeddable OTP
service, a versioned client boundary, a host for reviewed extensions and
context pipelines, and a deliberately small reference coding product. Its
architecture should also remain understandable from the OTP primitives and
contracts that implement it.

Technical depth: [Product roles, exclusions, and north-star scenario](vision-technical.md#technical-vision-product-definition)

It is not a workflow or objective engine, identity or policy system, memory
product, fleet control plane, isolation boundary, exactly-once effects system,
marketplace, generic protocol implementation, or application UI. Those
concerns can surround Loopex without entering the session kernel.

The north-star experience is a durable repository session that accepts a
request, streams progress, performs controlled coding work, survives client
disconnects, supports another authorized attachment, moves work across
eligible hands without changing semantics, and retains truthful state through
recovery or extension activation.

<a id="concept-vision-product-principles"></a>
### 4. Product principles

Use OTP directly and add abstractions only at durable or genuinely replaceable
boundaries. Keep the runtime headless, give each session one serial owner,
commit intent before effects and facts before publication, and distinguish
uncertainty from failure or permission to retry.

Technical depth: [The complete founding principle set](vision-technical.md#technical-vision-product-principles)

Keep runtime instances independent while acknowledging that executable code is
VM-global. Keep coordination in the brain and OS effects in hands. Hosts own
identity, policy, credentials, tenancy, quotas, placement, retention, and user
experience. Metadata and generated content are data, never authority.

Use plain bounded data at public and executor boundaries. Keep recovery,
public events, snapshots, progress, and diagnostics distinct. Admit generated
code only through reviewed promotion, treat same-VM extensions as trusted, and
prove local durability before distribution or compatibility promises. Every
kernel concept must justify why it cannot remain at an edge.

<a id="concept-vision-domain-language"></a>
### 5. Stable domain language

The project uses precise names for runtimes, hosts, sessions, coordinators,
runs, turns, commands, operations, attempts, epochs, fences, journals,
transactions, outboxes, events, snapshots, attachments, interactions, tools,
jobs, receipts, reconciliation, executors, brains, workspaces, artifacts,
grants, brokers, extensions, resources, and projections.

Technical depth: [Normative glossary and state qualifiers](vision-technical.md#technical-vision-domain-language)

These words identify different owners and guarantees. In particular, private
journal state, public projection state, provider continuation state, extension
state, and host policy state must never be compressed into an ambiguous claim
about “session” or “agent” state.

<a id="concept-vision-ownership-trust"></a>
### 6. Ownership and trust boundaries

Loopex owns session and effect mechanics. Hosts own product authority and
governance. Executors own workspaces, OS processes, local resource enforcement,
and retained execution evidence. Presentation and diagnostics observe these
systems but do not become authority channels.

Technical depth: [Ownership matrix, planes, grants, and policy port](vision-technical.md#technical-vision-ownership-trust)

An effect proceeds only with a scoped, expiring host grant bound to the intended
operation, request, workspace, executor, effect class, and fence. The executor
validates that grant before starting. Policy may allow, deny, or suspend for a
later decision; failure or malformed input never falls through to allow.

<a id="concept-vision-dependency-doctrine"></a>
### 7. Stack and dependency doctrine

The stack has a transport-neutral protocol, a pure session core, an OTP runtime,
and replaceable edges. Dependencies point inward: hosts and adapters depend on
Loopex; the core does not import provider, store, executor, transport, client,
or host implementations.

Technical depth: [Layers, dependency budget, and direct-OTP rules](vision-technical.md#technical-vision-dependency-doctrine)

The initial core depends only on Elixir and Erlang. Repository or package
splits require demonstrated pressure and a decision. Processes, supervision,
messages, and behaviours remain visible rather than being hidden behind a
private agent DSL.

<a id="concept-vision-runtime-supervision"></a>
### 8. Runtime instances and supervision

Multiple independently configured runtimes can coexist in one BEAM. Runtime
references are explicit, session transition logic is pure, and state-bearing
processes exist only where ownership or concurrency requires them.

Technical depth: [Instance API, supervision topology, reducer, and epochs](vision-technical.md#technical-vision-runtime-supervision)

Each live session coordinator is a recoverable owner and cache over durable
truth. A monotonic session epoch rejects stale work from an earlier owner.
Executable code remains the deliberate VM-global exception and therefore has a
separate authority and failure domain.

<a id="concept-vision-recovery-truth"></a>
### 9. Transaction, operation, and recovery truth

VM code, runtime control, and session journals are separate durable transaction
domains. Commands are idempotent within their owning scope, and asynchronous
work has stable operation identity plus kind-specific attempt rules.

Technical depth: [Transactions, idempotency, outcomes, reconciliation, and cancellation](vision-technical.md#technical-vision-recovery-truth)

Intent commits before dispatch. A commit whose result is unknown fences its
mutation domain until resolved. A completion is admitted only when all current
identity, epoch, digest, and fence evidence matches. Prior receipts enter only
through a solicited current reconciliation. If an effect cannot be proven,
Loopex records an immutable unknown outcome and does not blindly retry it.

Cancellation stops owned work and reports what was observed; it does not claim
to undo an external effect.

<a id="concept-vision-loop-semantics"></a>
### 10. Loop semantics

One run is active per session in 0.x. A run alternates between exact committed
model input, model output, ordered tool calls, complete tool results, and a
single terminal outcome. Steering affects the active run; follow-up work waits
in durable order.

Technical depth: [State machine, queues, ordering, concurrency, and payload rules](vision-technical.md#technical-vision-loop-semantics)

Tools execute serially by default. Any later concurrency must preserve source
order, effect truth, cancellation, and deterministic replay. Partial or
malformed calls never execute. Model-facing payloads and client-facing
rendering remain separate so presentation concerns cannot shape durable loop
truth.

<a id="concept-vision-public-protocol"></a>
### 11. Public protocol and channel semantics

Embedded callers, terminals, daemons, IDEs, and future transports share one
semantic contract for commands, admissions, events, snapshots, interactions,
and outcomes. Transports adapt that contract rather than creating alternate
loops.

Technical depth: [Envelopes, event taxonomy, attachment, delivery, and schemas](vision-technical.md#technical-vision-public-protocol)

Stable events come from committed facts. Attachments begin from an
authoritative snapshot and cursor, have explicit replacement semantics, and
cannot control session lifetime merely by connecting or disconnecting. Slow
attachments are bounded and cannot block coordinator progress. Unknown fields
and versions follow declared compatibility rules.

<a id="concept-vision-sessions-storage"></a>
### 12. Durable sessions, context, and storage

A session’s durable history, queues, lineage, operation state, and projections
survive process and client lifetimes. Store implementations satisfy private
ports; none defines the public data model by accident.

Technical depth: [Store ports, canonical history, forks, compaction, artifacts, and sensitive content](vision-technical.md#technical-vision-sessions-storage)

Branches and compaction retain lineage and replay meaning. Large outputs become
content-addressed artifacts. Credentials remain host-owned references, and
sensitive material is excluded from journals, public events, diagnostics, and
fixtures unless a narrowly approved ephemeral hand requires it.

<a id="concept-vision-model-boundary"></a>
### 13. Model and context boundary

Core uses provider-neutral Loopex data. A model adapter translates that data
and may retain compatibility-bound continuation information without allowing a
provider library to shape public or durable contracts.

Technical depth: [Canonical types, model contract, reference adapter, continuation, and context pipeline](vision-technical.md#technical-vision-model-boundary)

The context pipeline is the sole seam for memory, retrieval, prompts, and
other injected context. Every staged block carries provenance, trust, lineage,
and budget information. The exact staged context and model request digest
commit before dispatch, so recovery cannot silently rebuild a different input.

<a id="concept-vision-tools"></a>
### 14. Tools and the coding surface

A tool is a versioned capability description plus mechanics, effect class, and
executor requirements. Its presence does not grant permission. The reference
product proves a deliberately small coding surface rather than placing every
possible action in the kernel.

Technical depth: [Tool contract, seven-tool surface, registry, and resolution](vision-technical.md#technical-vision-tools)

The reference distribution supplies seven conformance-tested implementations;
the active default profile is selected from prompt-cost, safety, and task
evidence. Tools remain ordinary behaviours resolved through explicit
registries.

<a id="concept-vision-executor-protocol"></a>
### 15. Executor protocol and brain/hand topology

The brain owns session coordination and durable effect truth. A hand interprets
an opaque workspace reference, owns OS processes, enforces resource limits, and
returns bounded evidence. Placement can change without changing the operation
contract.

Technical depth: [Job contract, broker, trust classes, transport security, and output handling](vision-technical.md#technical-vision-executor-protocol)

Local native, OS-isolated, and trusted remote execution implement the same job,
receipt, cancellation, and reconciliation semantics. Native distribution is
for mutually trusted gateways, not isolation. Output is bounded and spills to
artifacts where necessary.

<a id="concept-vision-sensitive-data"></a>
### 16. Trust, sensitive data, and project resources

Runtime code, reviewed extensions, project resources, generated code, model
content, workspace content, and remote peers have explicit trust classes.
Admission into context or execution never implies permission to perform an
effect.

Technical depth: [Trust classes, resource admission, tenancy, and redaction](vision-technical.md#technical-vision-sensitive-data)

Project resources are canonicalized, bounded, provenance-typed, and admitted
under host policy. Multi-tenant brains do not load tenant code. Observability
uses references and redaction rather than capturing secrets or unrestricted
payloads.

<a id="concept-vision-extensions"></a>
### 17. Trusted extensions and generated code

Reviewed extensions are retained trusted OTP artifacts with full authority in
their VM. Resource packs are data-only in the code-loading sense, not
automatically safe. Generated code remains isolated unless a separate reviewed
promotion creates a trusted artifact.

Technical depth: [Packages, manifests, contributions, activation, rollback, state, and generation](vision-technical.md#technical-vision-extensions)

Extension activation is VM-global, versioned, quiescent, and durable. It drains
every affected runtime, loads a sealed module set, migrates externalized state,
checks health, and either commits the generation or restores the exact previous
generation. If exact rollback cannot be completed in place, the code domain
restarts on retained artifacts and reconstructs runtimes from durable truth.

Production runtime and compiler-bearing builder artifacts can be separated;
core release hot upgrades remain later work with their own proof.

<a id="concept-vision-api-transports"></a>
### 18. Embedded API, transports, and clients

The embedded Elixir API is the reference semantic surface. JSONL RPC, a daemon,
a terminal client, ACP, and later transports map to it without gaining special
authority or owning session lifetime.

Technical depth: [Embedded operations and transport/client mappings](vision-technical.md#technical-vision-api-transports)

The first terminal is intentionally line-oriented and useful. Print mode and
event mode serve different automation needs. Protocol mappings are proven only
to the subset they can represent faithfully; naming an ecosystem protocol does
not claim compatibility.

<a id="concept-vision-hosts"></a>
### 19. Hosts and ecosystem posture

Loopex can support a reference CLI, CI harness, secured personal host, team
coding service, remote worker fleet, and specialized tooling while remaining a
session-and-effects runtime. Each host supplies its own identity, governance,
placement, retention, and presentation.

Technical depth: [Expected consumers, secured-host seam, product boundary, and conformance](vision-technical.md#technical-vision-hosts)

An equivalent operation should eventually produce equivalent durable identity,
outcome, event order, snapshot, cancellation, receipt, and fencing semantics
through materially different hosts and placements. Integration into another
repository remains separately authorized and is not Loopex release acceptance.

<a id="concept-vision-repository-seed"></a>
### 20. Repository seed

The repository begins as one version train whose layout makes the core’s inward
dependency direction visible. Application, package, or repository splits wait
for demonstrated consumer, deployment, ownership, or release pressure.

Technical depth: [Seed layout, runtime floor, derived documents, ADR agenda, and documentation expectations](vision-technical.md#technical-vision-repository-seed)

The bootstrap compatibility target is Erlang/OTP 26+ and Elixir 1.17+, subject
to the runtime-floor decision and evidence before a compatibility claim. The
founding documents derive operational guides, plans, ADRs, specifications,
examples, and conformance material without substituting for them.

Documentation is part of the product: process ownership, public behaviours,
examples, conformance suites, and architecture claims remain traceable to
working code and explicit OTP mechanisms.

Project explanations follow clarity before mechanism. A substantive concept
document gives purpose, constraints, observable behavior, and decisions in a
directly readable form, then links exact implementation and evidence depth in
its paired companion. The pair is one authority: neither depth may hide a
decision or contradict the other. Public code and important boundaries explain
their concept before technical depth; private commentary is reserved for
non-obvious invariants, effects, failure modes, and decisions. The
[development charter](developer/development-charter.md#concept) owns the shared
form and proportional exceptions.

<a id="concept-vision-delivery-strategy"></a>
### 21. Delivery strategy

Delivery is vertical and useful. A bounded experiment may test risky claims
without freezing a product surface. Later milestones make the local loop useful,
deepen durability, add governed extensions and isolated hands, prove remote
ecosystem use, and establish compatibility only as evidence permits.

Technical depth: [Capability questions, prerequisites, and planning rule](vision-technical.md#technical-vision-delivery-strategy)

The capability ladder guides decomposition, not version scope. Every milestone
has its own accepted plan and can split, combine, rename, resequence, or omit
projected work beneath the enduring barriers. Plans own exact scope, evidence,
migration, rollback, packaging, and deferrals.

<a id="concept-vision-serial-barriers"></a>
### 22. Ownership and serial barriers

Parallel work rejoins only after shared contracts are explicit. No workstream
may create an alternate session loop, authority path, or durability truth to
avoid a prerequisite.

Technical depth: [Normative rejoin order and proportional rejoin evidence](vision-technical.md#technical-vision-serial-barriers)

The enduring order is durable local session and operation truth, multi-client
attachment and a protocol candidate, extension namespaces and VM-global
activation proof, a public-protocol compatibility decision, isolated-hand
conformance, then remote-worker and multi-host compatibility evidence.

<a id="concept-vision-verification"></a>
### 23. Verification and acceptance

Tests prove contracts and demonstrations prove usability. Evidence is bound to
the exact source and artifacts, reproducible from documented commands, explicit
about environment and limits, isolated from real project state, and honest
about unavailable real paths.

Technical depth: [Evidence hierarchy, test layers, invariants, budgets, performance, and release-plan duties](vision-technical.md#technical-vision-verification)

Reducers use properties; replaceable boundaries use conformance; durability
uses process and storage fault injection; protocols use language-neutral
vectors; trust uses negative tests; claimed integrations and packages use their
real paths. Fakes do not replace evidence for a claimed provider, store,
isolation boundary, or package.

Minimalism is enforced through concrete exclusions and accepted-plan budgets,
not a universal line count. The core has no external runtime dependency, one
semantic contract, a small public surface, and no built-in product governance
or orchestration. Performance budgets follow measurement.

<a id="concept-vision-compatibility"></a>
### 24. Compatibility and release governance

Journal schema, public protocol, executor protocol, extension API, embedded API,
and artifact formats are separate compatibility surfaces. They freeze only when
their own consumers, schemas, vectors, migration, rollback, and operational
evidence justify the claim.

Technical depth: [Surface states, 0.x policy, migration, rollback, and publication](vision-technical.md#technical-vision-compatibility)

During 0.x, every public surface is experimental, release-candidate, or stable
with explicit rules. A binary or package release records its exact source,
artifact, toolchain, platform, contents, install proof, and rollback procedure.
A previous binary is not a rollback plan when storage has changed irreversibly.

<a id="concept-vision-risks"></a>
### 25. Risks and countermeasures

The design actively resists kernel scope growth, hidden framework layers,
global-state coupling, provider leakage, accidental public storage formats,
duplicate or uncertain effects, client control races, premature protocol
freezes, overstated isolation or hot loading, supply-chain compromise, secret
capture, context poisoning, premature packaging, and planning that outruns
working software.

Technical depth: [Risk-to-countermeasure register](vision-technical.md#technical-vision-risks)

Countermeasures are architectural contracts and evidence obligations: explicit
ownership, pure transitions, scoped runtimes, canonical data, durable intent,
fencing and reconciliation, bounded queues, negative tests, exact activation
and rollback, isolated hands, redaction, provenance, measured budgets, and
decision gates.

<a id="concept-vision-founding-decisions"></a>
### 26. Current founding decisions

The project is an independent greenfield implementation of a multi-instance,
host-neutral OTP coding-session and effects runtime. It uses direct OTP, small
edge behaviours, a standard-runtime-only core, a provider-neutral model port,
seven reference tool implementations, serial tool execution by default, and
separate durable truth planes.

Technical depth: [Complete numbered founding-decision record](vision-technical.md#technical-vision-founding-decisions)

Hosts retain identity, policy, credentials, tenancy, placement, memory,
objectives, channels, and presentation. Workspaces remain opaque. Native
execution and distribution are not sandboxes. Effects use kind-specific
identity, fencing, receipts, reconciliation, and immutable unknown outcomes.
Trusted extensions use VM-global exact activation and rollback; less-trusted
code stays in isolated hands.

Local durability precedes multi-client protocol; extension activation precedes
public compatibility; isolated hands precede remote workers; ACP mapping
precedes protocol v1. Restart and replay precede production release hot
upgrades. Store, package, tool-profile, and context implementation choices
follow evidence while the kernel boundaries remain fixed. The working name is
Loopex and the license is Apache-2.0.

<a id="concept-vision-open-questions"></a>
### 27. Open questions and decision triggers

Open decisions have evidence triggers rather than implied dates. They cover
name clearance, terminal richness, the default tool profile, durable store,
public schema subset, continuation retention, isolation and remote transports,
published hand images, ACP scope, compatibility consumers, package splits,
release hot upgrades, secured-host proof, context examples and storage, request
artifact boundaries, pinned memory, and the lasting runtime floor.

Technical depth: [Question-by-trigger register](vision-technical.md#technical-vision-open-questions)

Listing a question does not authorize work or assign it to a milestone.

<a id="concept-vision-name-license"></a>
### 28. Name and license

Loopex means “the loop, in Elixir.” It remains a working name until trademark,
package, repository, domain, and search clearance support public use. Rename
before compatibility-bearing publication if clearance is weak.

Technical depth: [Clearance actions, license, provenance, and reuse constraints](vision-technical.md#technical-vision-name-license)

Apache License 2.0 is the founding license. Later copied or adapted material
requires explicit license, provenance, attribution, security, coupling, and
maintainer review.

<a id="concept-vision-sources"></a>
### 29. Informative design sources

Primary runtime documentation, coding harnesses, server architectures, model
adapters, ecosystem protocols, context research, and prior-system operating
lessons inform this design. They do not create compatibility promises or
replace Loopex’s own reasoning.

Technical depth: [Complete dated source bibliography and provenance notes](vision-technical.md#technical-vision-sources)

<a id="concept-vision-closing-thesis"></a>
### 30. Closing thesis

Elixir provides the middle ground between a disposable loop and a feature-heavy
platform: durable actors, independent clients, concurrent IO with serialized
truth, governed trusted-code evolution, location-transparent hands, and
observable failure.

Technical depth: [Closing architectural synthesis](vision-technical.md#technical-vision-closing-thesis)

Loopex exposes those properties through the smallest sufficient durable
session-and-effects boundary. That boundary allows many products and clients to
share the same core without forcing the core to become any one of them.
