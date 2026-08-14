# Loopex — Founding Vision and Architecture

Status: **standalone repository seed — founding document**

Date: **2026-08-14**

Project: **Loopex — “the loop, in Elixir”**

Repository: **[github.com/lexlapax/loopex](https://github.com/lexlapax/loopex)** (to be created from this document)

License: **Apache-2.0**

Public name: **provisional pending trademark, domain, package, and repository clearance**

## 1. Purpose and authority

This document is the founding vision for the Loopex repository, to be created
at [github.com/lexlapax/loopex](https://github.com/lexlapax/loopex). It defines
the durable product boundary, architectural doctrine, domain language,
non-negotiable correctness properties, ecosystem posture, and intended release
sequence. It is deliberately complete enough to seed:

- the repository `README.md`;
- a compact `AGENTS.md`;
- architectural decision records;
- public protocol and conformance documentation;
- bounded contract-experiment and capability-stage plans;
- contributor, operator, extension-author, and executor-author guides.

This is a north-star and boundary document. It is not itself a frozen wire
schema, a versioned release contract, an operational runbook, or permission to
ship every feature described here in one release. Those artifacts must be
created separately and must remain consistent with this vision.

When later project sources disagree, use this authority order:

1. the current maintainer decision, or a project operator decision made under
   authority explicitly delegated by the maintainer;
2. accepted security and architecture ADRs plus already released public
   contracts;
3. the active versioned plan and its acceptance evidence;
4. this founding vision;
5. historical plans and archived design material.

An ADR may refine this vision. A release plan may select a subset of it. Neither
may silently reverse a core boundary or correctness invariant. A deliberate
reversal must identify the affected principle, evidence, compatibility impact,
and migration path.

## 2. Executive thesis

> **Loopex is an OTP-native, multi-instance, embeddable runtime for durable
> coding-agent sessions and controlled effects. It combines a small,
> provider-neutral model loop with truthful recovery, versioned client
> contracts, location-transparent tool execution, and governed live
> extensions.**

An agent is a loop around an LLM. Loopex makes that loop a supervised,
durable, attachable Elixir service. It should be useful as a minimal terminal
coding harness on its own and small enough to disappear inside a larger host.

The architectural brief comes from José Valim’s observation that Elixir is an
unusually strong substrate for a coding harness:

- hot code facilities can support live extension evolution without discarding
  durable session state;
- the actor model makes a client/server architecture a natural process
  topology;
- IO and CPU work can proceed concurrently while one actor serializes session
  truth;
- built-in distribution can separate a session “brain” from local or remote
  “hands”; and
- **“You don’t need an external framework for this. The runtime is the
  framework.”**

Loopex takes that statement literally. It does not hide OTP behind an agent
framework, workflow DSL, actor abstraction, or macro-heavy plugin system. It
uses ordinary Elixir and Erlang:

- `Supervisor`, `DynamicSupervisor`, and explicit failure domains;
- `GenServer` only where a process must own serial state;
- pure transitions over plain data for the core loop;
- tasks, monitors, links, messages, registries, and process groups;
- the BEAM code server for governed trusted-code evolution;
- ports, sockets, containers, and microVMs for real OS isolation;
- Erlang distribution only among mutually trusted runtimes;
- explicit behaviours where durability, trust, persistence, transport, or
  compatibility crosses a boundary.

OTP supplies mechanisms, not the complete product contract. Supervision does
not make effects transactional. Distribution does not create authorization or
exactly-once execution. A registry is not a durable event stream. Hot loading
does not make arbitrary generated code safe. Loopex therefore adds stable IDs,
transactions, receipts, fencing, reconciliation, protocol versions,
backpressure, and trust boundaries exactly where those properties are needed.

The desired result is not merely “Pi rewritten in Elixir.” It is a reusable
session-and-effects substrate from which all of these can be built without
forking the loop:

- a small reference CLI;
- an IDE coding agent through the Agent Client Protocol;
- a CI or headless coding harness;
- a security-rich personal assistant host;
- a multi-tenant team coding service;
- a remote executor fleet;
- specialized debugging, migration, documentation, incident-response, or
  data-development tools.

## 3. Product definition

### 3.1 What Loopex is

Loopex is simultaneously:

1. **A coding-session runtime.** It turns admitted inputs into ordered model
   turns, validated tool operations, durable messages, and typed outcomes.
2. **An effects runtime.** It records intent before dispatch, owns operation
   identity, distinguishes retry from reconciliation, and tells the truth when
   an external effect cannot be proven.
3. **An embeddable OTP service.** Multiple independently configured Loopex
   runtimes can coexist in one BEAM, each hosting many durable sessions.
4. **A versioned client boundary.** Embedded callers, terminal clients,
   daemons, IDEs, and web hosts consume the same command, event, snapshot, and
   interaction semantics.
5. **A trusted extension host.** Reviewed OTP applications can contribute
   tools, adapters, projectors, commands, and supervised children through a
   governed generation lifecycle.
6. **A context-pipeline host.** Memory, retrieval, and prompt systems plug in
   as governed extensions through one context pipeline (§13.5) without
   entering the kernel.
7. **A reference coding product.** The repository ships a deliberately small
   CLI that proves the core is pleasant and useful rather than merely
   theoretically embeddable.
8. **Practical Elixir-and-AI learning material.** Every architectural promise
   should be traceable to the OTP primitive and contract that implements it.

### 3.2 What Loopex is not

Loopex is not:

- a generic autonomous-agent framework;
- a workflow DAG, objective engine, durable goal system, or built-in sub-agent
  scheduler;
- a user, organization, tenant, role, identity, authentication, or billing
  system;
- an enterprise policy engine, secret vault, or confirmation database;
- a memory product, retrieval/RAG framework, or embedded vector database;
- a learned prompt store or prompt-optimization engine in its kernel;
- an IDE, web workspace, collaboration dashboard, social-channel framework,
  or delivery outbox;
- a Kubernetes abstraction, cloud control plane, autoscaler, or general job
  scheduler;
- a security sandbox merely because it uses processes, supervisors,
  distribution, or `:peer`;
- an exactly-once remote-effects system;
- a model-driven package installer or extension marketplace;
- a compatibility implementation of Pi’s APIs or session files;
- an MCP, ACP, A2A, Agent Skills, or AG-UI implementation at its core;
- a Jido Agent/Action/Signal runtime under another name;
- a Phoenix or LiveView application with a hidden loop inside it.

These capabilities may exist in hosts, adapters, extensions, examples, or later
projects. They do not belong in the session kernel merely because an eventual
product needs them.

### 3.3 The north-star experience

A developer starts a Loopex runtime for a repository and attaches a terminal.
They request a change. The session streams model output, reads code, edits
files, runs tests, accepts steering while active, queues follow-up work, and
records branchable durable history. The terminal may disconnect without
terminating the session. Another authorized client can attach as an observer
and reconstruct the same state from a snapshot plus subsequent events.

The same brain can dispatch a compiler or test suite to a local process, an
isolated container, a microVM, or a remote worker. The brain owns the session
and durable operation ledger. The hand owns the workspace and OS processes.
The tool contract does not change when placement changes.

During a session, a trusted extension candidate may be validated in a
disposable VM. Loopex creates an activation barrier, drains every affected
extension entry point, atomically changes the trusted module generation,
migrates or restores externalized state, verifies health, and resumes queued
work. A failed activation restores the retained previous generation or restarts
the complete VM code domain on that generation, then reconstructs every member
runtime from its ledgers and journals. A dedicated extension-host VM is the
preferred restart scope; a shared in-brain code domain may require restarting
that BEAM. Session history remains intact.

If a worker disappears after an effect may have started, Loopex does not invent
success, failure, or safety. It reconciles a retained receipt when possible and
otherwise commits `outcome_unknown`. An unknown effect is never blindly
repeated.

## 4. Product principles

These principles are intended to become the compact non-negotiables in the
future `AGENTS.md`.

1. **The runtime is the framework.** Use OTP directly. Add an abstraction only
   where it creates a durable boundary or allows a genuinely replaceable edge.
2. **Session before surface.** The runtime is headless. CLI, IDE, daemon, web,
   and embedded callers are peers over one semantic contract.
3. **One serial owner per session.** One coordinator commits durable session
   decisions. Concurrent work reports back; it does not mutate session truth.
4. **Durable intent precedes effects.** No provider or executor operation is
   dispatched before its durable intent and identity are committed.
5. **Durable facts precede publication.** Stable public events come only from a
   committed outbox. Notifications are never truth.
6. **Commit ambiguity is explicit.** A timeout is not proof of non-commit.
   Unknown commit status fences the coordinator until the store resolves it.
7. **Unknown outcomes are honest.** Uncertain external effects become terminal
   unknown attempts, not optimistic retries.
8. **Recovery never trusts stale work.** Live completions require current
   epochs and fences. Prior evidence enters only through current,
   fully-validated reconciliation.
9. **Runtime instances are isolated.** Core APIs and process names never assume
   a global singleton or use global application environment for instance state.
10. **Brains and hands are different trust roles.** The brain coordinates; the
    hand performs effects. Workspace location and execution placement remain
    opaque to the core.
11. **Mechanics in Loopex; governance in the host.** Loopex supplies suspension,
    interactions, grants, receipts, and enforcement hooks. Hosts own identity,
    policy, credentials, tenancy, quotas, placement, retention, and UX.
12. **Metadata never grants authority.** Model output, tool declarations,
    extension manifests, resource metadata, IDs, writer epochs, traces, and UI
    answers are data until a host authority makes a decision.
13. **Plain data crosses boundaries.** Public and executor contracts never carry
    PIDs, ports, functions, monitors, arbitrary Erlang terms, or atoms created
    from untrusted input.
14. **Events are a public contract, not a recovery log.** Private journal,
    durable events, authoritative snapshots, transient progress, and
    administrative diagnostics have different guarantees.
15. **Generated code is a candidate, not authority.** It runs in an isolated
    hand unless an explicit reviewed promotion creates a trusted retained
    artifact.
16. **Extensions are trusted generations.** Same-VM code has full VM authority.
    Activation is quiescent, versioned, bounded, rollback-tested, and never an
    implicit sandbox.
17. **Local correctness precedes distribution.** A useful single-machine loop
    ships before extension, sandbox, and remote-worker complexity.
18. **Restart and replay precede production release hot upgrades.** Extension
    reload is an early feature; `.appup`/`.relup` release evolution is later,
    separately proven operations work.
19. **Compatibility is behavioral.** Public claims require schemas, golden
    vectors, multiple consumers, migrations, and upgrade/rollback evidence.
20. **Every core concept pays rent.** If a concern can be a host policy,
    adapter, extension, executor, or client feature, it stays out of core.
21. **Injected context is provenance-typed, budgeted data.** Whatever enters
    the model's context — memory recalls, retrieved documents, prompt
    fragments, resource files — carries its source, trust class, and digest;
    is bounded by budget; is journaled by receipt; and never grants
    authority.

## 5. Stable domain language

| Term | Meaning |
| --- | --- |
| **Runtime** | One independently supervised and configured Loopex instance. A runtime owns its control-ledger namespace, stores, registries, sessions, adapters, extension selection, dispatchers, and host ports. Executable code loading remains VM-global. |
| **Host** | The application embedding or operating a runtime. It owns product authority and governance. |
| **Session** | Durable coding conversation, configuration, history, lineage, queues, and operation state identified by `session_id`. The live process is an owner/cache, not truth. |
| **Coordinator** | Sole serial writer of one active session’s durable decisions. |
| **Run** | Work caused by one prompt or queued follow-up, from durable admission to one terminal outcome. One run is active per session in 0.x. |
| **Turn** | One model response and the ordered tool batch it requests. A run can contain many turns. |
| **VM code command** | Versioned request whose durable owner is the VM code-generation ledger, such as install, activate, rollback, or retire a trusted extension closure. |
| **Runtime command** | Versioned request whose durable owner is the runtime control ledger, such as create, fork, stop, or runtime configuration. |
| **Session command** | Versioned request durably serialized by one session coordinator, such as prompt, steer, follow-up, abort, compact, set model, or respond to interaction. |
| **Attachment request** | Ephemeral transport/control request such as attach, detach, or subscribe. It uses request correlation and explicit replacement semantics, not session-command replay. |
| **Operation** | Durable generic intent for asynchronous work, bound to canonical request bytes or an immutable request reference. Kind-specific protocols refine provider requests, executor effects, deterministic internal work, and trusted-code activation. |
| **Attempt** | One execution of an operation under the evidence required by that operation kind. Another attempt is allowed only when policy and durable evidence make it safe. |
| **Epoch** | Monotonic ownership generation used to reject work from an earlier session or executor incarnation. |
| **Fencing token** | Attempt-specific evidence that prevents a stale executor from authoritatively starting or completing work. |
| **Journal record** | Private durable transition required for recovery or reconciliation. Not a client API. |
| **Transaction** | Atomic store change in a VM-code, runtime-control, or session-journal namespace, covering that namespace's records, idempotency rows, outbox rows where applicable, and allocated sequence numbers. |
| **Outbox** | Durable records ready to become stable public events after transaction commit. |
| **Public event** | Immutable, versioned observation of committed session state for clients. |
| **Snapshot** | Authoritative public projection anchored to an event sequence, or private recovery projection anchored to a journal version. The two forms are distinct. |
| **Progress** | Best-effort token, reasoning, stdout, stderr, or activity delta. Never canonical and never replay-required. |
| **Diagnostic** | Operational or administrative information for maintainers. Not product session history. |
| **Attachment** | Logical client subscription identified by an attachment ID and incarnation, with a snapshot/cursor and optional command capability. A reattach creates or explicitly replaces an incarnation; a stale handle cannot detach or authorize a current one. |
| **Interaction** | Generic suspended input or decision request resumed only by the exact `interaction_id`. |
| **Tool** | Versioned model-visible capability description, schema, mechanics, effect class, and executor requirements. A tool definition grants no permission. |
| **Tool call** | One model-requested invocation identified by `tool_call_id`. |
| **Job** | Typed request sent to an executor for one operation attempt. |
| **Receipt** | Kind-specific retained evidence about an attempt. An executor receipt attests what a trusted hand observed; it is not infallible proof of external reality. |
| **Reconciliation** | Current, fenced inquiry that evaluates retained evidence from a possibly stale prior attempt. |
| **Executor / hand** | Component that interprets a workspace reference, owns OS processes, performs effects, enforces local budgets, and retains receipts. |
| **Brain** | Runtime side that owns model coordination, durable session truth, operation state, context projection, and scheduling. |
| **Workspace** | Opaque executor-owned repository or filesystem reference. It is not necessarily a brain-local path. |
| **Artifact** | Content-addressed output carried by digest, metadata, and opaque retrieval reference rather than inline bytes. |
| **Grant** | Opaque, scoped, expiring host-issued authority evidence validated by an executor. |
| **Broker** | Replaceable selector of an eligible executor. It is not a fleet control plane. |
| **Extension** | Trusted retained OTP artifact contributing versioned behaviours. It has full authority in its VM. |
| **Extension selection** | Runtime-local set of enabled extension contributions. Two same-VM runtimes may differ only where their selected artifacts and module revisions do not conflict. |
| **Code generation** | VM-global immutable set of loaded trusted extension artifacts and module revisions, coordinated across every affected runtime in that VM. |
| **Resource pack** | Prompts, context, skills, templates, and static assets. “Data-only” means no direct code loading, not inherently safe instructions. |
| **Projection** | Rebuildable view derived from durable records: model context, public snapshot, search index, or client rendering state. |

Use precise qualifiers when saying “agent state.” Session state, private
journal state, public projection state, provider-native continuation state,
extension state, and host policy state have different owners and guarantees.

## 6. Ownership and trust boundaries

### 6.1 Normative ownership map

| Concern | Loopex | Host | Executor |
| --- | --- | --- | --- |
| Runtime and session lifecycle | Owns durable mechanics and separate runtime/session transaction domains | Chooses configuration and lifecycle policy | Observes jobs only |
| VM trusted-code ledger | Owns one authoritative activation record per BEAM code domain | Owns admission/signing and decides which runtimes may share that domain | No access |
| Runtime control ledger | Owns create/fork/stop mappings and runtime configuration | Supplies or selects store and retention | No access |
| Session ordering and journal | Owns per-session command and operation truth | Supplies or selects store | No access unless explicitly granted |
| Model/provider conversion | Defines adapter contract | Selects model and credential reference | None |
| Credential custody | Stores references only | Owns encryption, resolution, rotation | Receives only scoped ephemeral values when required |
| User/tenant identity | Carries bounded opaque references | Owns | Validates scoped grant audience only |
| Authorization and confirmation | Suspends and transports results | Owns decisions and grants | Validates grant fail-closed |
| Tool mechanics | Defines schema and effect metadata | Approves exposure | Performs declared effect |
| Workspace meaning | Treats reference as opaque | Creates or leases | Interprets and enforces it |
| Sandbox policy | Defines transport contract only | Chooses isolation requirements | Implements actual boundary |
| Placement | Requests capabilities through broker | Owns locality, priority, quotas, cost, fleet | Advertises capabilities |
| Public events | Owns committed semantic facts | Projects into product vocabulary | Emits bounded progress and receipts |
| Rendering and channels | Supplies renderer-neutral payloads | Owns UI and delivery | Optional progress only |
| Context assembly | Owns pipeline stages, budgets, provenance typing, receipts | Owns trust policy; extensions supply providers/transformers/selectors | None |
| Long-term memory/knowledge | Owns the pipeline seam and public-event substrate only | Owns memory truth, review, retention, deletion; extensions own recall and stores | None |
| Objectives/orchestration | Does not own | Owns and composes sessions | None |
| Trusted code and extension selection | VM-global manager owns executable generations; runtimes own non-conflicting contribution selection | Owns admission/signing and trust-domain placement | May validate hand packages |
| Audit/retention | Supplies facts and references | Owns obligations and storage policy | Supplies receipts and diagnostics |

### 6.2 Planes

Loopex is easiest to reason about as four planes:

1. **Data plane.** VM-code and runtime-control ledgers, session reducer and
   journal, command admission, operations, dispatch, receipts, fencing,
   reconciliation, public outbox, and replay.
2. **Host control plane.** Identity, authorization, confirmation, grants,
   credentials, tenancy, quotas, repository governance, placement, extension
   trust, retention, and fleet operations.
3. **Presentation plane.** Reference CLI, IDE, daemon client, web UI, channel,
   dashboards, and generated SDKs.
4. **Diagnostics plane.** Metrics, traces, crash detail, health, extension
   activation diagnostics, backpressure state, and operator evidence.

Only the data plane is Loopex’s architectural center. The other planes connect
through explicit ports and protocols. Presentation and diagnostics never become
authority channels.

### 6.3 Authority grants

The host may issue an opaque capability grant after its policy process allows an
operation. A grant is bound at least to:

```text
operation_id / attempt
canonical_request_digest
tool_id / tool_version
workspace_lease
executor audience
effect class
expiry
fencing token
optional bounded policy context
```

Loopex transports and binds this evidence but does not interpret a host’s user,
role, policy, or approval semantics. The executor validates the grant
fail-closed before starting an effectful job. An expired, wrong-audience,
wrong-attempt, or wrong-fence grant is rejected.

For an executor effect, `canonical_request_digest` is also the canonical job
digest: the host grant, durable operation attempt, `JobRequest`, and retained
receipt all bind the same recorded value. Its protocol-versioned
canonicalization covers the immutable semantic job fields, including operation
and attempt identity, validated arguments, workspace lease, executor audience,
effect class, budgets, fence, and output policy. It represents the opaque grant
by its durable binding metadata or reference rather than by secret grant bytes.
There is no second independently computed digest that can drift at the executor
boundary; any mismatch fails closed.

A grant cannot bypass the host’s own capability registry, confirmation,
security, or audit boundaries. An interaction response alone is not a grant.
Extension metadata and tool declarations cannot create one.

### 6.4 Host policy port

`Loopex.Policy` is a mechanics seam, not a policy language. It supports:

```text
allow(grant_reference)
deny(reason_category)
defer(interaction_request)
```

A synchronous policy callback must be pure or bounded local work. Policy that
needs user input, durable host storage, or an external service returns `defer`;
the session commits a suspended interaction and resumes only after the host
makes a durable decision. Timeout, host failure, or malformed response fails
closed into denial or continued suspension. It never falls through to allow.

The reference CLI may deliberately use an `AllowAll` host policy for a trusted
single developer. That convenience is documented as permissive local authority,
not a security model for other products.

## 7. The Loopex stack and dependency doctrine

### 7.1 Four layers

The project uses this vocabulary:

- **Loopex Protocol (`Loopex.Protocol`)** — transport-neutral, versioned
  commands, admissions, events, snapshots, interactions, content blocks, and
  compatibility negotiation.
- **Loopex Core (`Loopex.Core`)** — pure session reducer, run/turn semantics,
  queue semantics, outcomes, and context projection rules.
- **Loopex Runtime (`Loopex.Runtime`)** — runtime instances, supervision,
  runtime/session transaction coordination, dispatch, event delivery, runtime
  extension selection, executor broker, recovery, and host ports.
- **Loopex edges** — model, store, policy, artifact, executor, transport,
  observability, and client adapters.

```mermaid
flowchart TB
    subgraph Hosts["Hosts and clients"]
      CLI["Reference CLI"]
      IDE["IDE / ACP client"]
      CI["CI / headless host"]
      SECURE["Security-rich host"]
      TEAM["Team coding service"]
    end

    subgraph Runtime["One Loopex runtime instance"]
      PROTOCOL["Protocol"]
      CORE["Pure session core"]
      OTP["OTP session runtime"]
      STORE["Runtime control + session journal + outbox"]
      EXT["Runtime extension selection"]
      BROKER["Executor broker"]
    end

    subgraph VMCode["One trusted-code authority per BEAM"]
      CODEGEN["VM code-generation manager"]
    end

    subgraph Edges["Replaceable edges"]
      LLM["Model adapter"]
      STORES["Store adapters"]
      LOCAL["Local hand"]
      SANDBOX["Sandbox gateway"]
      REMOTE["Trusted remote gateway"]
    end

    Hosts --> PROTOCOL
    PROTOCOL --> OTP
    OTP --> CORE
    OTP --> STORE
    OTP --> EXT
    EXT --> CODEGEN
    OTP --> BROKER
    OTP --> LLM
    STORE --> STORES
    BROKER --> LOCAL
    BROKER --> SANDBOX
    BROKER --> REMOTE
```

Dependency direction is one-way. Hosts depend on Loopex. Core does not import
host authority models or host implementations; product concepts map explicitly
at adapter edges.

### 7.2 Core dependency budget

The initial `loopex` OTP application depends only on the Elixir/Erlang runtime.
The core has no compile-time dependency on:

- ReqLLM or another provider library;
- Jido Agent, Action, Signal, or AI loop packages;
- JSON codecs;
- SQLite, Ecto, or another database;
- Phoenix, LiveView, or an HTTP server;
- a terminal library;
- Docker, Kubernetes, FLAME, or a cloud SDK;
- OpenTelemetry or an external pub/sub system.

Those dependencies belong in adapters or reference applications. CI enforces
namespace and dependency direction with `mix xref`, compile-time checks, and
tests that build the core against only fake edge implementations.

Use one repository and one release version through 0.x. Physical application
or Hex-package splits require demonstrated compile, runtime, ownership,
deployment, or external-consumer pressure and an ADR. Folder structure alone is
not evidence for a package boundary.

### 7.3 No hidden framework

No macro should disguise `GenServer`, `Supervisor`, messages, or behaviours as
a proprietary agent DSL. Tools and extensions implement ordinary behaviours.
Session transitions remain inspectable plain functions. Each state-bearing
process documents:

- the state it owns;
- why it is a process rather than a pure value;
- its supervisor and restart policy;
- its durable recovery source;
- what messages it accepts;
- how stale messages are rejected.

This is both architecture discipline and educational product value.

## 8. Runtime instances and supervision

### 8.1 Multi-instance API

Loopex is never a global singleton. A runtime is an opaque supervised instance:

```elixir
{:ok, runtime} = Loopex.start_link(runtime_options)

{:ok, session_id} =
  Loopex.create_session(runtime, session_options,
    command_id: Loopex.ID.command()
  )
```

The runtime owns its control-ledger namespace, stores, registries, adapter
configuration, non-conflicting extension selection, executor broker, event
dispatcher, and host ports. The reference CLI may create one hidden default
runtime, but public core APIs always accept an explicit runtime reference.

Instance-specific values do not live in global application environment. Global
registered names are forbidden for instance-owned services. Acceptance must
prove two runtimes with distinct stores, models, policies, non-conflicting
extension selections, and executors can coexist in one BEAM without collisions
or data leakage.

A runtime is not itself a tenant model. A host may choose one runtime per trust
domain, many tenants per isolated deployment, or another arrangement. Identity,
quotas, retention, and tenancy remain host policy.

**VM-global code boundary.** A runtime is independently configured and
supervised, but BEAM module loading, code paths, and current/old module versions
are VM-global. Same-VM runtimes may share one coordinated trusted-code
generation or select disjoint verified module namespaces. Runtimes that require
conflicting revisions, independently activated generations, or separate code
trust domains use separate extension-host VMs or separate Loopex nodes behind a
versioned portable protocol.

One VM-global code-generation manager serializes trusted module loading,
code-path policy, and old-code reclamation. Runtime extension managers own
catalogs, contribution routing, and leases but cannot load code directly. A
same-name activation acquires a VM-wide write lease and quiesces every affected
runtime; a runtime-local catalog entry never makes a module revision
runtime-local.

### 8.2 Conceptual supervision topology

```text
Loopex.VMCodeGenerationManager (one per BEAM)
└── VMCodeGenerationLedger

Loopex.Runtime.Supervisor[runtime_ref]
├── StoreSupervisor
├── RuntimeControlLedger
├── RuntimeRegistry
├── ModelAdapterRegistry
├── ExecutorBrokerSupervisor
├── RuntimeExtensionManagerSupervisor
├── EventDispatcherSupervisor
├── SessionSupervisor (DynamicSupervisor)
│   ├── SessionTree[session_id]
│   │   ├── SessionKernelSupervisor (:one_for_all initially)
│   │   │   ├── SessionCoordinator
│   │   │   ├── ModelWorkerSupervisor
│   │   │   └── ExecutionWorkerSupervisor
│   │   ├── ProjectionWorker
│   │   └── SessionEventHub
│   └── ...
└── TransportSupervisor
    ├── Embedded adapter
    ├── JSONL RPC adapter
    └── later daemon / WebSocket / trusted-BEAM adapters
```

Each session tree is an independent failure domain. `:one_for_all` is confined
to the session-kernel children that share coordinator epoch and fencing
invariants. Event hubs and projections are separately restartable from the
durable outbox; losing either cannot terminate the coordinator or discard
durable work. An individual model or tool task exit becomes an operation result
and does not take down the session unless its owning supervisor violates a
documented epoch invariant.

The session coordinator is the sole serial owner of canonical active state.
Provider calls, model streams, filesystem work, shell commands, compiler work,
context compaction, event fan-out, policy work that can block, extension
callbacks, and network calls occur in supervised work outside coordinator
callbacks.

The session event hub delivers from a durable public outbox. It is not a source
of truth. `Registry` and `:pg` may assist local or trusted-cluster discovery;
they do not supply persistence, ordering, replay, authorization, or
backpressure. Each attachment has bounded delivery. A slow or dead client can
never block the coordinator or another attachment.

### 8.3 Pure reducer

The coordinator is a serialization shell around a pure transition:

```text
{new_state, private_records, public_outbox_events, requested_operations}
  = Loopex.Core.Session.reduce(state, admitted_input)
```

The transition does not perform IO. The coordinator’s only permitted
synchronous external barrier is a bounded local journal transaction. Only
after a confirmed commit may it update its in-memory cache, notify the event
dispatcher, or dispatch requested operations.

Durable state contains plain serializable data: no PIDs, ports, monitors,
anonymous functions, open streams, task references, or extension-owned process
state. Restart loads a compatible private snapshot, replays later private
records, advances the session epoch, rebuilds projections, and reconciles active
operations before admitting new effects.

### 8.4 Session ownership and epochs

Coordinator or owned-work supervisor loss terminates the session’s supervised
work before reconstruction. A new session epoch is durably committed before
admission resumes. Every asynchronous result carries operation identity,
attempt, origin session epoch, and its kind-specific dispatch identity. An
executor effect additionally carries origin executor epoch, executor identity,
and fencing token; model, maintenance, and activation results carry their own
adapter/request, input/version, or code-domain/phase evidence instead.

An unsolicited live completion is accepted only when it matches the current
dispatch tuple. Old work cannot complete against reconstructed state. Retained
prior evidence is still usable, but only through the solicited reconciliation
protocol defined below.

## 9. Transaction, operation, and recovery truth

### 9.1 Durable transaction domains

Loopex has three durable mutation domains. A VM-code transaction owns one
BEAM code domain's trusted-artifact and activation truth. A runtime-control
transaction owns runtime lifecycle mappings, runtime-scoped idempotency, and
configuration. A session-journal transaction owns one session's serial history
and atomically persists:

- private session transition records;
- command and operation idempotency rows;
- operation attempt and receipt state;
- stable public-event outbox rows;
- allocated private journal version and public event sequence values.

The store contract has three outcomes:

| Store result | Meaning | Required domain-owner behavior |
| --- | --- | --- |
| `committed(tx_id)` | The transaction is durably visible. | Update cached state, publish its outbox records, acknowledge as appropriate, and dispatch requested work. |
| `not_committed(reason)` | The store proves no durable transaction exists. | Retain prior state; publish and dispatch nothing; return or record a non-admission result. |
| `commit_unknown(tx_id)` | Timeout, disconnect, crash, or reply loss prevents knowing whether commit occurred. | Fence the mutation domain, stop new dispatch, and resolve by transaction ID before choosing either branch. |

A timeout is never evidence of failure. During `commit_unknown`, Loopex does
not speculate: it does not acknowledge acceptance, publish an event, or launch
an effect. A recovered commit is processed exactly once as if its original
reply had arrived.

`commit_unknown(tx_id)` enters a fenced `commit_resolution_pending(tx_id)`
mode. Resolution runs as restart-safe supervised work with bounded backoff; it
never blocks a coordinator callback. New mutations are rejected or reported
temporarily unavailable while the relevant domain is fenced. If the store
remains unavailable, Loopex remains unavailable rather than speculating.
Transaction IDs are allocated before the store call, are bound to the expected
domain version and canonical mutation digest, and are recoverable from the
owning command or operation identity. Repeating the same transaction ID is a
query/idempotent resolution, never a second logical mutation.

### 9.2 Command and lifecycle idempotency

Every durable lifecycle or state-changing request carries a stable
`command_id`, but the key is scoped to its mutation domain:

| Domain | Examples | Durable owner and key |
| --- | --- | --- |
| VM code | trusted extension install, activation, rollback, retirement | VM code-generation ledger, `(code_domain_id, command_id)`; every affected runtime joins the same activation decision. |
| Runtime control | create, runtime stop/configuration | Runtime control ledger, `(runtime_id, command_id)`; create atomically records the new session genesis and returns the same `session_id` on repetition. |
| Session | prompt, steer, follow-up, abort, compact, session configuration, interaction response | Session journal, `(session_id, command_id)`. |
| Attachment | attach, detach, renew subscription | Event dispatcher/transport request correlation; not a journaled command and never replayed as an obsolete capability. |

Fork is one logical runtime command whose transaction records the new session
genesis and immutable source lineage. Read-only lookup/open requests need
correlation and snapshot consistency but do not become durable mutations merely
to fit the command vocabulary.

The durable owner persists a canonical parsed-command digest and admission
result before acknowledging a mutation. Canonicalization is protocol-versioned
and makes defaults, absent values, content order, map ordering, unknown-field
treatment, and byte encoding deterministic. It includes every semantic field
that can change durable behavior and excludes transport framing, whitespace,
trace correlation, and ephemeral attachment handles.

| Repetition | Result |
| --- | --- |
| Same scoped `command_id`, same canonical digest | Return the original durable admission response and terminal reference when available. |
| Same `command_id`, different canonical command | Reject with `idempotency_conflict`. |
| New `command_id` | Process through normal durable admission. |

Idempotency rows record the digest algorithm/canonicalization version, creation
time, result reference, and explicit retention policy. Client IDs define a
bounded namespace where a transport needs one; they are not authority.

Attachment requests use a `request_id`, stable attachment key where negotiated,
and an attachment incarnation. A repeated attach returns the still-live
incarnation or explicitly replaces it at a negotiated cursor; after expiry or
disconnect it returns a new attachment and snapshot/cursor response. Detach is
idempotent success. Attachment identity and lifetime are not durable session
truth.

Host metadata is bounded and typed. It may include an opaque `external_ref`,
writer epoch, trace correlation, and client correlation. It is never an
arbitrary map and never grants authority merely because it is present.

### 9.3 Durable operation lifecycle

Command deduplication alone cannot prevent asynchronous work from running
twice. Every operation therefore has a durable `operation_id`, kind, canonical
request digest or immutable request reference, attempt, applicable
session/run/turn/tool-call identity, origin session epoch, deadlines, budgets,
idempotency class, intent record, and one initial terminal disposition.

The common lifecycle is:

```text
intent_committed -> attempt_committed -> evidence_or_completion_committed
```

Its dispatch and evidence contract is selected by kind:

- **Model call.** Binds the exact staged canonical request, adapter/model
  compatibility identity, continuation reference, cancellation class, and
  normalized completion/error evidence. A provider retry is a new recorded
  attempt; an incomplete stream never becomes an assistant message.
- **Executor effect.** Adds executor identity/epoch, workspace lease, host
  grant, fencing token, durable deduplication, retained receipt, and the full
  reconciliation contract below. Only effect attempts become
  `outcome_unknown` because an executor cannot prove whether an external effect
  occurred.
- **Deterministic maintenance.** Binds input range, algorithm/version, and
  output digest so compaction or projection work can restart deterministically.
- **Trusted-code activation.** Uses the VM-global durable phase machine in
  §17. It is not disguised as an executor receipt, although validation in an
  isolated hand may itself be a separate effect operation.

All kinds commit intent before dispatch and facts before publication. They do
not share fictitious executor fields merely to reuse one struct.

The journal normally persists a capability-grant reference plus the binding
metadata needed for recovery. The host resolves the actual short-lived opaque
grant just in time for dispatch. If a host must retain encrypted opaque grant
evidence for renewal or audit, its protected store adapter owns that decision;
the value never appears in public events, progress, diagnostics, or ordinary
session content.

### 9.4 Executor-effect crash and reconciliation

| Evidence at recovery | Required behavior |
| --- | --- |
| Intent committed; no dispatch recorded | Dispatch the same operation ID, subject to current policy and placement. |
| Dispatch recorded; acceptance unknown | Issue a new `reconciliation_query_id` under the current session epoch. |
| Executor proves it never started | Policy may record a new attempt. |
| Executor proves a terminal result | Commit that exact retained result once. |
| Executor cannot prove start or result of an effectful job | Commit `outcome_unknown`; do not blindly repeat. |
| Old executor sends an unsolicited completion | Reject it as stale. |

Prior-epoch evidence is admissible only through a current solicited
reconciliation query. The outer response must match the current
`reconciliation_query_id`, current coordinator/session epoch, expected executor
identity, and current recovery contract. The embedded retained receipt must
match:

- journaled `operation_id`;
- original attempt;
- journaled `canonical_request_digest`;
- original session epoch;
- original executor epoch;
- executor identity;
- fencing token.

After validation, the coordinator commits the evidence under the current
recovery epoch. It never treats an old receipt as a current live completion.
The executor ledger is authoritative for its authenticated retained
observation; it is not infallible proof of external reality. Insufficient proof
remains `outcome_unknown`.

### 9.5 Closed outcome algebra

Attempts, logical tool calls, operations, and runs are distinct layers. A
retryable failed attempt may lead to another attempt without emitting a public
terminal tool event. One logical `tool_call_id` receives at most one initial
`tool.finished`; one admitted run receives exactly one initial `run.finished`.
Pre-dispatch denial can finish a logical tool call without creating an executor
attempt.

Logical tool calls and runs use this closed initial algebra:

```text
completed
cancelled
denied
failed(category, retryable?)
unavailable(category)
outcome_unknown(reconciliation_ref)
```

`needs_interaction` is a suspended state, not a successful or terminal
outcome.

`outcome_unknown` is immutable and terminal for its operation attempt and the
affected logical operation. Later
evidence never rewrites the original terminal event or silently resumes the
model loop. It creates a separate durable reconciliation fact that references
the original operation and attempt. A session-visible resolution may project a
new `operation.reconciled` public fact, but it does not replace the original
`tool.finished` or `run.finished` event. A host or user must explicitly decide
whether a new operation should proceed. New work receives a new operation ID.

Public `tool.started` and `tool.finished` describe the logical tool call, not
its private dispatch retries. `tool.finished(outcome_unknown)` leads to the
affected `run.finished(outcome_unknown)` unless an explicit later command
starts new work. Reconciliation supplements both facts and changes neither.

### 9.6 Cancellation

Cancellation is an acknowledged protocol:

```text
cancellation requested and durably recorded
  -> stop scheduling new work
  -> cooperative cancel to provider or executor
  -> bounded grace period
  -> trusted gateway terminates owned process tree or container
  -> cleanup and kind-specific evidence resolution
  -> operation: preserve validated kind-specific terminal fact
                | cancelled when cancellation caused termination
                | outcome_unknown when effect evidence is insufficient
  -> run: cancelled | outcome_unknown
```

An executor captures sufficient process/container ownership and kill identity
before it accepts an effectful job. Cancellation, lease expiry, worker loss, and
control-channel loss all exercise descendant cleanup. `cancelled` is committed
only when cleanup is confirmed. If a remote or external effect cannot be
reconciled, the attempt ends `outcome_unknown`.

No cancellation result claims to undo a side effect that already committed.

The coordinator's committed journal order decides a completion/cancellation
race. If validated completion commits before abort admission, the later abort
is acknowledged as `already_terminal` or a no-op. If abort admission commits
first, no new work is scheduled; later evidence is handled only through that
operation kind's cancellation and reconciliation rules. `cancelled` commits
only after the relevant cleanup evidence. If later validated evidence proves an
effect completed, the operation and logical tool call remain truthfully
`completed`; the affected run finishes `cancelled`, does not feed that result
back into the model, and starts no new work. The same preservation rule applies
to any other validated terminal fact: for example, a proven executor failure
leaves the operation and logical tool call `failed` while the affected run is
`cancelled`. `cancelled` describes an operation only when cancellation and
confirmed cleanup caused its termination; it never overwrites a previously or
subsequently validated `completed`, `failed`, `denied`, or `unavailable` fact.
If the effect remains unprovable, both tool and run expose `outcome_unknown`.
If an aborted model call later completes or fails, its attempt evidence is
retained truthfully, but its response does not become a canonical assistant
message and the run remains `cancelled`. Cancellation never erases a proven
side effect or terminal failure. The same ordering rule applies to every
operation kind using its own completion evidence.

## 10. Agent-loop semantics

### 10.1 Minimal state machine

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> preparing: prompt admitted
    preparing --> awaiting_model: model intent committed
    awaiting_model --> awaiting_tools: complete valid tool calls
    awaiting_model --> run_terminal: complete answer without tools
    awaiting_model --> run_terminal: error / abort / budget exhausted
    awaiting_tools --> awaiting_tools: next serial call or safe batch
    awaiting_tools --> preparing: ordered results committed
    awaiting_tools --> suspended: host interaction required
    awaiting_tools --> run_terminal: cancellation / unrecoverable failure
    suspended --> awaiting_tools: exact interaction resolved
    suspended --> run_terminal: denied / expired / aborted
    run_terminal --> preparing: follow-up queued
    run_terminal --> idle: no queued work
```

One active run per session is an intentional 0.x constraint. It makes context,
tool ordering, steering, durable recovery, and human expectations tractable.
Hosts that need concurrency create multiple sessions and coordinate them outside
the core.

### 10.2 One run

1. A client submits a prompt with a unique `command_id`.
2. The coordinator durably admits or rejects it and returns one correlated
   admission response.
3. The context pipeline builds and stages exact provider-neutral input from the
   selected session lineage, active model capabilities, active tool set,
   retained continuation sidecar, context policy, and code generation.
4. The coordinator atomically commits the staged request reference and digest,
   model-operation intent, and `run.started` outbox fact. Only after confirmed
   commit does supervised model work receive those exact bytes.
5. Model text, reasoning, and tool-call fragments are transient progress. A
   complete assistant message becomes durable before its stable public event.
6. A complete assistant message without tool calls finishes the run. A
   malformed, incomplete, or truncated tool call never executes.
7. Each requested tool is resolved against the active versioned definition,
   validated, offered to host policy, and classified as allowed, denied, or
   deferred.
8. A deferred decision creates a durable generic interaction. Only the exact
   matching response can resume it, and only a host policy decision can create
   a grant.
9. Each allowed tool-operation intent commits before executor placement and
   dispatch. The job carries the full identity, epochs, fence, opaque workspace
   lease, opaque grant, deadlines, budgets, and output policy.
10. Progress may arrive in execution order. Complete results and model-facing
    tool messages commit in the assistant’s original tool-call order.
11. Pending steering is applied before the next model request. The loop repeats
    until a terminal condition.
12. One typed terminal outcome and one `run.finished` public event commit.
13. If follow-up work is queued, the next run starts. Otherwise
    `session.settled` becomes observable.

`run.finished` and `session.settled` remain distinct. A run may be finished
while retries, reconciliation, compaction, or queued follow-up work keep the
session from being settled.

### 10.3 Input queues

0.x defines four explicit input paths:

- **`prompt`** starts a run only while settled.
- **`steer`** belongs to the active run and is injected after the current tool
  batch finishes but before the next model request. It does not pretend to
  reverse an effect already started.
- **`follow_up`** creates a new run after the current run and steering settle.
- **`respond_interaction`** answers exactly one pending `interaction_id` with
  host decision context.

If a run is active, Loopex never guesses whether new user input is steering or
a follow-up. A stale, duplicate, expired, or mismatched interaction response is
rejected. `abort` is a separate durable cancellation request.

Queue mode is one-at-a-time initially. Deliver-all or other batching semantics
require a later explicit session option and ordering proof.

### 10.4 Tool ordering and concurrency

Tools execute serially by default. Filesystem mutations, shells, compilers, and
external writes generally do not commute. Parallel-by-default execution is a
worktree-corruption feature disguised as performance.

Later, a tool may declare `parallel_safe: true` and a complete resource scope.
A batch may run concurrently only when:

- every call is explicitly parallel-safe;
- the complete conflict set is known and non-overlapping;
- per-call and per-batch cancellation/deadline semantics are defined;
- result persistence remains in assistant source order;
- one serial call serializes the batch; and
- host or extension policy has not forced serial execution.

Parallel execution is a deferred feature with its own evidence, not an
implementation shortcut in the initial local kernel.

### 10.5 Split payload rule

Model-facing content and client-facing rendering are separate values.

- Model content is bounded, provider-portable input for the next turn.
- Client details may include richer diagnostics, structured diffs, progress,
  controls, and artifact references.
- Operator diagnostics may include private crash or adapter details unavailable
  to either the model or ordinary client.

Renderers, terminal escape sequences, UI components, provider structs, and raw
exceptions never enter canonical model history merely because a client wants to
display them.

## 11. Public protocol and channel semantics

### 11.1 One semantic contract

Embedded Elixir, JSONL RPC, daemon sockets, WebSockets, ACP adapters, and future
SDKs implement the same semantic operations. A local caller gets no privileged
access to coordinator state, PIDs, internal messages, or private journal
records.

The public protocol is transport-neutral and composed of:

- feature/version negotiation;
- session lifecycle commands;
- command admission responses;
- durable public events;
- authoritative snapshots;
- transient progress;
- generic interaction requests and responses;
- bounded host metadata and correlation.

Exact schemas belong in versioned protocol files and conformance vectors. This
vision fixes their semantics and boundaries.

### 11.2 Four stream planes

| Plane | Guarantee |
| --- | --- |
| **Durable public events** | Immutable, versioned observations of committed facts; at-least-once delivery; ordered only within one session. |
| **Authoritative snapshots** | Replaceable compatible public projection anchored to a public event sequence. |
| **Transient progress** | Best-effort deltas with offsets and a base sequence; may be dropped and need not replay. |
| **Administrative diagnostics** | Access-controlled operational state; not user-visible session history and not a business-behavior input. |

A reconnecting client is owed the complete durable assistant message and stable
terminal outcomes, not every token or stdout fragment it missed.

### 11.3 Command envelope

An illustrative pre-v1 command envelope:

```json
{
  "protocol_version": "0.x",
  "command_id": "cmd_...",
  "session_id": "ses_...",
  "client_id": "client_...",
  "type": "prompt",
  "metadata": {
    "external_ref": "opaque-host-ref",
    "writer_epoch": 4,
    "traceparent": "optional-correlation-only"
  },
  "payload": {
    "content": [{"type": "text", "text": "Fix the failing test"}]
  }
}
```

`command_id` is the idempotency key inside the command's VM-code, runtime, or
session scope. VM-code commands target a code domain; runtime commands carry
`runtime_id` and may have no `session_id`; session commands require both.
Attachments use their separate request and incarnation envelope rather than
pretending to be durable commands.
`client_id`, writer epoch, external reference, and trace context are
correlation or host-fencing inputs, not proof of authorization. Host transport
admission and write authority are decided before core invocation.

Admission is a correlated durable response, not a public event. Acceptance
means the command is durably admitted. Later work reports asynchronously. The
same command never receives contradictory admission responses.

### 11.4 Event envelope

An illustrative pre-v1 event envelope:

```json
{
  "schema_version": "0.x",
  "event_id": "evt_...",
  "session_id": "ses_...",
  "event_sequence": 42,
  "run_id": "run_...",
  "turn_id": "turn_...",
  "tool_call_id": null,
  "operation_id": null,
  "attempt": null,
  "correlation_id": "cmd_...",
  "causation": {"kind": "command", "id": "cmd_..."},
  "occurred_at": "2026-08-14T12:00:00.000000Z",
  "type": "assistant.message_completed",
  "payload": {}
}
```

Rules:

- `event_sequence` is total only inside one session’s public stream.
- Public events are immutable and durable before publication.
- Delivery is at least once; clients deduplicate by event ID and sequence.
- No order is promised across sessions.
- Unknown event types are ignored or surfaced according to negotiated
  compatibility; they never convey authority.
- Payloads contain no PIDs, module atoms, stack traces, raw Erlang terms,
  credential values, or unredacted provider internals.
- `run.finished` and `tool.finished` each carry one closed outcome.
- Relevant terminal payloads carry `operation_id` and `attempt` when an
  operation attempt exists. Pre-dispatch denial is explicitly identified as a
  tool-call decision without an executor attempt.
- Causation is nullable for roots and is a typed command, event, or operation
  reference; consumers never assume it is an event ID.
- A later reconciliation fact never rewrites a previous terminal event.

### 11.5 Initial durable taxonomy

The first public vocabulary is deliberately smaller than the recovery machine:

```text
session.created | session.configured | session.forked | session.settled
run.started | run.finished
user.message_appended | assistant.message_completed
tool.started | tool.finished
interaction.requested | interaction.resolved | interaction.expired
context.compacted | branch.summarized
operation.reconciled
```

`operation.reconciled` is emitted only when later stable evidence is materially
session-visible. It references, rather than replaces, the original unknown
`operation_id`, attempt, and terminal event.

`tool.started` and `tool.finished` represent one logical `tool_call_id`.
Dispatch retries and executor attempts remain private or progress-only. A
pre-dispatch policy denial may emit `tool.finished(denied)` without an executor
operation. An executor-backed unknown emits `tool.finished(outcome_unknown)`
and the affected `run.finished(outcome_unknown)`; later reconciliation changes
neither.

`session.configured` records model, reasoning-level, and active-tool-set
changes. Snapshots carry current configuration, but a live observer between
snapshots must not render a stale model identity.

Transient progress begins with:

```text
model.text_delta | model.reasoning_delta | model.tool_call_delta
tool.stdout_delta | tool.stderr_delta | tool.progress
retry.scheduled | context.compaction_progress | extension.reload_progress
```

Retry decisions, model attempts, dispatch attempts, leases, epochs, receipts,
fences, recovery queries, and extension activation details are private or
administrative. `retry.scheduled` is a replaceable progress view; the durable
retry decision remains private.

Extension-contributed public values use reserved namespaced envelopes with
explicit extension ID, contribution ID, schema version, and payload schema.
Extensions cannot invent a core event type, alter core event ordering, or
change terminal uniqueness. The same rule applies to extension commands.

### 11.6 Race-free attachment

Attach is one runtime-owned cursor transaction:

```text
negotiate protocol and features
-> host authorizes transport and write/read capability
-> dispatcher establishes an attachment barrier at committed sequence N
-> obtain an authoritative snapshot anchored at exactly N
-> buffer only durable events after N for that attachment
-> deliver snapshot, then the buffered and live stream contiguously
-> deduplicate by session, event sequence, and event ID
```

The runtime closes the subscribe/snapshot race. Clients do not separately read
state and subscribe. At-least-once duplicates are permitted; gaps are not.
Progress follows its durable base sequence and may be coalesced or dropped. A
cursor older than retained history returns explicit `cursor_expired` plus a
fresh snapshot/cursor instead of silently truncating history.

The core does not mandate a controller lease. It serializes all durably admitted
commands. A reference daemon implements one-controller/many-observer policy,
crash takeover, and stale-writer fencing above the core. Another host may use a
different collaboration policy. A read-only attachment never acquires command
authority.

### 11.7 Delivery and backpressure

The coordinator commits outbox records and sends a bounded notification to the
event dispatcher. It never synchronously fans out to arbitrary subscribers.
The dispatcher reads durable events, maintains bounded per-attachment queues,
and applies a documented slow-consumer policy such as coalescing progress,
disconnecting an attachment with a resume cursor, or requiring replay.

Within one attachment, the dispatcher preserves contiguous per-session public
event order. No ordering is promised between durable events and transient
progress beyond the progress item's declared base sequence.

A slow client cannot grow coordinator memory without bound, delay journal
transactions, change session behavior, or block another client.

### 11.8 Schema posture

Public DTOs and tool schemas use a documented JSON Schema 2020-12-compatible
subset wherever practical. The subset, content-block vocabulary, extension
namespace envelope, and compatibility rules are versioned and backed by
language-neutral golden vectors.

W3C trace context may propagate as optional correlation. It is never an
authority token. An OpenTelemetry edge may map model, tool, and runtime spans;
model content, tool arguments, and tool results are capture-off by default
because they may be sensitive.

## 12. Durable sessions, context, and storage

### 12.1 Private durable-store ports

`Loopex.CodeStore`, `Loopex.RuntimeStore`, and `Loopex.JournalStore` are private
recovery machinery. They may be logical namespaces of one adapter or separate
implementations behind explicit ownership and atomicity contracts. None is the
public protocol or the session interchange format.

The VM-code surface owns:

- retained trusted-artifact identities, digests, and closure metadata;
- VM-global activation commands, phases, selected code generation, and
  rollback evidence;
- the code-domain membership of every affected runtime;
- transaction-ID resolution and migration state for that code domain.

The runtime-control surface owns:

- runtime-scoped command idempotency and configuration;
- session identity allocation, source/fork mapping, genesis, and tombstones;
- transaction-ID resolution and migration state.

Creating or forking a session cannot acknowledge until the runtime mapping and
new session genesis are atomically committed or a recoverable protocol proves
their single outcome.

The session-journal surface must:

- transact at an expected private journal version;
- atomically append private records, idempotency rows, operation state, and
  public outbox rows;
- allocate independent private journal versions and public event sequences;
- resolve a transaction ID after commit ambiguity;
- load private records after a journal version;
- load public events after an event sequence;
- store and load compatible private and public snapshots;
- store committed receipt projections and reconciliation decisions;
- expose corruption and migration failures explicitly.

### 12.2 Store posture

The founding vision freezes the store contract, not a database engine. The core
remains standard-runtime-only; store adapters are selected by evidence rather
than implementation-language purity. An in-memory adapter supports tests and
simple embedding. A human-readable local adapter may be useful for the
reference CLI, but its representation remains private and experimental.

A durable adapter is evaluated on atomicity, commit-ambiguity resolution,
writer ownership, crash and torn-write repair, corruption visibility, bounded
replay, indexes, migration and rollback, backup and restore, supported
platforms, operational burden, and packaging risk. BEAM-native and NIF-backed
candidates run the same conformance and fault-injection suite. A buggy NIF can
block or crash a VM and adds packaging cost; that is a risk to evaluate, not a
categorical veto.

Any file-backed local format must prove transaction framing, integrity checks,
tail repair, flush/fsync and lock semantics, writer fencing, transaction-ID
resolution, bounded records/artifact spill, and deterministic replay. Any
selected durable store defines supported migration pairs, interrupted-migration
recovery, backup/restore or downgrade behavior, and the oldest binary that may
safely reopen a migrated store.

A PostgreSQL or hosted store may be supplied later without changing session
semantics. Stable archive/export/import is a separate future public format with
its own compatibility promise.

### 12.3 Canonical history

The private journal preserves everything required to recover and project:

- admitted user content;
- complete assistant messages and provider usage;
- complete tool calls, results, outcomes, and validated receipt facts;
- selected model, reasoning configuration, and active tool changes;
- steering, follow-up, cancellation, and interaction state;
- compaction checkpoints and branch summaries;
- fork and branch lineage;
- runtime extension selection, VM code generation, and provenance references;
- operation attempts, recovery decisions, and unknown outcomes;
- compatible opaque provider-continuation sidecars or their references.

Model context, client snapshots, search indexes, and renderings are projections.
They may be rebuilt or replaced. They never rewrite the facts they summarize.

### 12.4 Branches and forks

Branch navigation selects another leaf in one session history. Fork creates a
new session whose origin records source session, source event/journal position,
and lineage. Context projection follows the selected lineage.

Abandoned-branch summarization and context-window compaction are separate
operations. They solve different problems and retain different provenance.

### 12.5 Compaction

A compaction checkpoint records:

- exact input lineage and range;
- summary and structured carry-forward fields;
- compaction strategy and extension revision;
- model/provider identity and usage when an LLM produced it;
- first later raw record kept verbatim;
- integrity digest over summarized record identities.

Raw records remain in durable history. Context projection may substitute a
checkpoint. A summary cannot alter tool receipts, effect outcomes, authority,
or historical facts.

### 12.6 Artifacts

Large patches, images, test logs, generated bundles, and oversized tool output
use an `ArtifactStore` port. Durable events carry content digest, media type,
size, logical role, and opaque retrieval reference. The host and adapter own
location, encryption, access control, retention, and garbage collection.

Tool results are byte-bounded toward the model. Overflow becomes an artifact
that a suitable tool can read back. Files and artifacts are state; the context
window is not a durable object store.

### 12.7 Credentials and sensitive content

The host owns credential custody. Loopex persists credential references, never
resolved API keys, access tokens, private keys, cookies, or vault values.
Resolution occurs just in time at the approved model or executor boundary and
uses the narrowest possible lifetime and audience.

Host-resolved known credential material is structurally excluded from:

- private journal records;
- public events or snapshots;
- progress or diagnostics;
- executor jobs except an explicitly scoped ephemeral hand secret;
- artifacts, test fixtures, crash reports, or sandbox logs.

User prompts and tool output can themselves contain sensitive data, and Loopex
cannot guarantee detection of every unknown secret. Hosts therefore supply a
bounded pre-persistence content-protection port whose declared policy rejects,
redacts, tokenizes/references, or requires encrypted storage for detected
content. Classifier coverage and failure posture are testable configuration,
not an absolute promise. Public projection uses explicit field allowlists and
deterministic sanitization before the journal/outbox transaction, not only at
the final transport.

The permissive local CLI file store is plaintext unless separately encrypted
and must say so clearly. It must never imply that a local file is a secret
vault.

## 13. Model/provider boundary

### 13.1 Canonical Loopex types

Loopex owns provider-neutral types for:

- exact model identity and capabilities;
- system, user, assistant, and tool messages;
- text, image, reasoning, and artifact-reference content blocks;
- tool definitions, calls, and streamed call deltas;
- complete streamed messages;
- stop and finish reasons;
- token, cache, reasoning, and usage accounting;
- optional cost estimates;
- retryable, unavailable, and terminal provider errors;
- cancellation and timeout.

No provider struct crosses into core, store, or public protocol. Provider
diagnostics may exist in a versioned opaque administrative value after
sanitization.

### 13.2 `Loopex.LLM` contract

`Loopex.LLM` accepts a canonical request and emits canonical stream items from
supervised work. It does not own:

- sessions or queues;
- retry decisions;
- tools or executor dispatch;
- compaction policy;
- persistence or public events;
- authorization or credentials.

Provider retries are session decisions. A model request may be retried before a
complete assistant message is committed when the adapter and policy classify it
safe, but the attempt uses the same staged request digest. Usage, latency, and
possible provider-side duplication remain observable. Different context or a
repeat after a complete assistant message commits is a new explicit operation,
not a hidden retry.

Capability negotiation happens before request admission. The provider
conformance suite proves:

- text streaming and complete-message reconstruction;
- reasoning content/effort where supported;
- tool-call delta reconstruction and schema round-trip;
- cancellation and timeouts;
- system/user/assistant/tool conversion;
- usage and stop-reason normalization;
- malformed or truncated calls remain non-executable;
- provider error classification;
- portability of the supported canonical content subset.

### 13.3 Direct ReqLLM reference adapter

The reference adapter is `loopex_llm_reqllm`, built directly on
[ReqLLM](https://github.com/agentjido/req_llm). ReqLLM owns provider transport
and normalization on Req/Finch. Loopex owns the session, loop, operation model,
tools, context, durability, and events.

```text
loopex core -> Loopex.LLM behaviour
loopex_llm_reqllm -> ReqLLM
```

The core must compile and test with a fake adapter and no provider dependency.
The reference adapter pins and tests a supported ReqLLM version range. Provider
catalog counts are informative, not a Loopex compatibility promise.

A host may implement another adapter using a raw provider SDK, a Jido-based
component, a local OpenAI-compatible endpoint, or another library without
changing the core. No Jido framework dependency belongs in `loopex` itself.

### 13.4 Provider-native continuation sidecar

Portable canonical history is necessary but may not preserve response IDs,
reasoning signatures, provider tool-call metadata, or other model-affine state
required for correct continuation.

The adapter may therefore maintain an opaque private continuation sidecar:

- explicitly bound to provider, model family, exact compatibility rules, and
  source message range;
- never interpreted by core;
- encrypted or protected with the private store when sensitive;
- retained only for a declared lifetime;
- stripped, lowered, or invalidated on incompatible model/provider change.

Conformance tests cover same-model continuation, compatible-model continuation,
mid-session model switching, cross-provider conversion, and tool-call ID
normalization.

Model roles such as `fast`, `capable`, or `thinking`, along with a unified
reasoning-control UI, belong in host or reference-client configuration. Core
uses exact model identity and declared capabilities.

### 13.5 The context pipeline

Everything the model sees passes through one governed pipeline. Loopex owns the
mechanics that every host needs: canonical lineage projection, typed content
blocks, provenance and trust labels, budget accounting, exact request staging,
and durable receipts. Memory truth, retrieval intelligence, prompt selection,
retention, and deletion belong to extensions and hosts.

The pipeline has five stages:

1. **Lineage projection.** Durable history becomes canonical messages while
   honoring branch selection and compaction checkpoints (§12).
2. **Candidate providers.** Project resources and optional registered providers
   contribute typed blocks such as recalls, documents, repository maps, or
   prompt fragments. Every block carries a source reference, content digest,
   trust class, and byte/token cost. Providers run as bounded supervised work,
   never inside coordinator callbacks.
3. **Transform and selection.** Versioned transformers and selectors may prune,
   reorder, or derive blocks within declared deterministic contracts. A derived
   block receives its own digest plus parent digests, transformation kind, and
   transformer identity/revision; provenance and policy-relevant typing cannot
   be forged or stripped.
4. **Budgeted assembly.** Per-source and total declared limits bound the final
   request. Typed delimiters help distinguish retrieved data from instructions,
   but they are an input-structure mitigation rather than a security boundary;
   grants and executor policy remain the authority boundary.
5. **Exact staging and receipt.** Before model dispatch, the coordinator
   normalizes the complete provider-neutral request and commits a private
   `context_prepared` fact in the same transaction as the model-call intent.
   It records ordered final block descriptors, exact bounded inline content or
   immutable artifact references, provider/transformer/selector identities and
   revisions, provenance/trust classes, digests, budgets, model and continuation
   bindings, and the canonical request digest.

Only after that transaction commits may the adapter receive the request. On
recovery, Loopex dispatches the same staged payload; it never silently reruns
retrieval or selection for an already-intended model call. A provider retry is
a new recorded attempt against the same staged bytes. Preparing different
context creates a new explicit model operation. A receipt is always an
auditable provenance record and is exactly reconstructable only while its
inline bytes or immutable referenced artifacts remain retained. Inline bytes
and referenced artifacts are pinned through the
operation's retry and recovery window. Missing staged bytes fail closed as
`unavailable(staged_context_missing)`; Loopex never recomputes different input
under the same operation ID.

The initial local kernel needs only canonical history, a fixed reference
project-resource stage, trust admission, total budget enforcement, and exact
receipts. Pluggable providers, transformers, selectors, observers, recall
stores, and prompt libraries belong to the governed extension surface. This
sequencing protects the small loop without weakening the permanent seam.

Failure semantics are explicit. An optional provider failure omits its blocks
and emits a private diagnostic. A transformer failure retains its input or
omits only declared optional output. A selector failure uses the versioned base
prompt. A host-declared required context or policy prerequisite defers or fails
closed before model dispatch. Injected context never grants authority or
changes tool policy (§6.4, §16.2).

The write path is the mirror image: memory observers consume public events to
build external stores (§17.3). Those stores are rebuildable projections, never
a second session truth. The reference code-retrieval posture begins with
agentic search through ordinary tools; lexical indexes, embeddings, and other
retrieval systems remain evidence-driven extensions rather than kernel
dependencies. Their stores follow the same contract-first selection posture as
other adapters.

## 14. Tools and the coding surface

### 14.1 Tool definition

A tool definition contains:

- stable `tool_id`, semantic version, model-visible name, and description;
- JSON Schema-compatible parameter schema;
- normalized model result and optional output/content schema;
- effect class: `read_only`, `workspace_write`, `process`, or
  `external_effect`;
- idempotency class: `safe_retry`, `reconcile_then_retry`, or
  `never_blind_retry`;
- required executor capabilities and platform labels;
- default wall-time, CPU, memory, process, disk, network, output, and artifact
  budgets where meaningful;
- concurrency/resource scope;
- optional prompt snippet and renderer hint.

Metadata describes mechanics. It does not expose the tool to a user, select an
executor, grant authority, or relax host policy.

### 14.2 The seven-tool coding surface

A coding agent needs five verbs: read, search, navigate, mutate, and execute.
The Loopex reference distribution supplies seven conformance-tested
implementations:

- `read` — bounded, chunked, text/binary-aware reads;
- `write` — explicit creation or replacement;
- `edit` — checked exact-match edits with useful mismatch diagnostics;
- `bash` — argv or explicit raw-shell execution through the selected hand;
- `grep` — content search;
- `find` — file/name matching;
- `ls` — bounded directory listing.

The intended bootstrap profile enables `read`, `write`, `edit`, and `bash`;
`grep`, `find`, and `ls` form an opt-in `coding_search` profile. Early evidence
measures prompt/schema cost, shell avoidance, safety, and task utility before an
ADR fixes the reference default. Hosts always choose their own active set
through policy and extensions.

The reference CLI targets a base system prompt plus active built-in tool
definitions under 1,000 tokens before project context. That is a measured
reference-product usability budget, not a universal kernel constraint. The core
enforces declared per-request and per-model limits; hosts may choose different
profiles and context budgets.

The local implementations share conformance for bounded output, workspace-root
resolution, symlink and path-scope behavior, exact edit preconditions, clear
mismatch diagnostics, explicit shell-vs-argv semantics, process ownership, and
artifact spill. Host policy decides the allowed workspace and effect; path
metadata alone never grants access.

Language servers, source control hosts, browsers, databases, cloud APIs, and
specialized development tools remain progressively disclosed extensions.

### 14.3 Registry and resolution

Tool IDs and versions resolve through a runtime-scoped registry with explicit
conflict rules. A request records the exact definition generation used for
validation and dispatch. Tool replacement is possible only through a trusted,
namespaced extension contribution and cannot silently change an in-flight
operation’s semantics.

The model selecting a tool produces a typed intent, not direct shell authority.
Host policy and executor validation remain mandatory for effectful execution.

## 15. Executor protocol and brain/hand topology

### 15.1 Transport-neutral job

The executor boundary is a versioned job/receipt protocol, not anonymous remote
functions or model-selected RPC.

```text
JobRequest
  protocol_version
  job_id
  operation_id / attempt
  session_id / run_id / turn_id / tool_call_id
  origin_session_epoch / origin_executor_epoch
  executor_identity and required capabilities
  tool_id / tool_version
  validated_arguments
  canonical_request_digest
  workspace_ref / workspace_lease
  capability_grant
  deadline and resource budgets
  idempotency class
  fencing token
  artifact and output policy
```

Every executor event echoes the complete identity and fence:

```text
accepted -> started -> progress/stdout/stderr* ->
completed | failed | cancelled | indeterminate_evidence
```

The terminal receipt includes executor identity, attempt identity, the same
canonical request digest bound by the grant and job, lifecycle evidence,
structured outcome, artifacts, usage, and the complete origin tuple required
for recovery validation. Executor deduplication rejects reuse of an
operation/attempt identity with different canonical bytes.

`indeterminate_evidence` is an executor statement about what it can prove, not
the durable Loopex outcome. Only the brain’s reconciliation state machine may
commit `outcome_unknown(reconciliation_ref)` after validating the receipt and
all other available evidence.

Schemas and golden vectors are language-neutral from the first conformance
contract. Elixir structs are one codec, not the protocol definition.

### 15.2 Opaque workspace

`workspace_ref` is opaque to core. A local hand may resolve it to a directory.
A remote hand may resolve it to a checkout, volume, snapshot, worktree, or
repository lease. Core conformance never assumes POSIX paths, shared disks, or
brain-local filesystem access.

### 15.3 Executor broker

The runtime asks a replaceable broker for an executor satisfying tool,
platform, protocol, trust, workspace, and resource requirements. Loopex owns
operation identity, lease, dispatch, fencing, and reconciliation.

The host owns:

- tenant and repository placement policy;
- quotas, cost, locality, priority, and fairness;
- worker provisioning, certificate lifecycle, and autoscaling;
- fleet health and capacity planning.

The broker seam enables “one brain, many hands” without making Loopex a cloud
scheduler.

### 15.4 Three execution trust classes

1. **Local native hand.** Executes with the invoking user’s OS authority. It is
   fast and appropriate for the trusted reference CLI. It is not a sandbox.
2. **Isolated-hand gateway.** A narrow framed stdio, Unix-socket, or network
   protocol to a trusted gateway controlling a process sandbox, container, or
   microVM. Generated and tenant code remains outside the brain and never joins
   its Erlang distribution cluster.
3. **Trusted remote gateway.** A mutually trusted compatible Loopex release may
   use native Erlang distribution for discovery, monitoring, and typed job
   routing. The gateway, not generated code, owns OS processes and sandboxes.

`:peer` may help launch disposable Loopex-built trusted worker nodes, including
over stdio, but it is not a hostile-code security boundary. It is an
implementation option, not the normative sandbox design. Local peers receive a
scrubbed explicit environment and working directory; they do not inherit brain
secrets and never execute tenant or generated code in the trusted node.

### 15.5 Distribution security

Connected Erlang nodes are one trusted security domain. Distribution cookies
primarily prevent accidental cluster mixing; they are not security-grade
authentication against hostile peers.

Before native distribution operates over an untrusted network, require:

- mutual TLS distribution with client and server peer verification, including
  server-side rejection of clients without certificates;
- certificate issuance, rotation, expiry, and revocation procedures;
- explicit peer/node allowlists and compatibility negotiation;
- controlled/fixed ports where practical;
- hardened, isolated, or replaced EPMD discovery;
- documented acceptance that compromising one connected trusted node threatens
  the cluster.

A less-trusted worker uses the portable gateway protocol rather than joining
distribution.

### 15.6 Resource controls and output

The hand enforces host-selected limits for wall time, CPU, memory, process
count, disk, network, environment, mounts, output, and artifact size. Output is
bounded and backpressured. Truncation creates an artifact reference rather than
silently losing the complete result.

Before acceptance, the hand records enough process/container identity to kill
descendants if cancellation, lease expiry, worker shutdown, or control-channel
loss occurs.

## 16. Trust, sensitive data, and project resources

### 16.1 Trust classes

Loopex distinguishes at least these trust classes:

| Class | Examples | Meaning |
| --- | --- | --- |
| **Host-owned trusted brain code** | Loopex core, reviewed adapters, approved extensions | Full authority in its VM and under its OS user. |
| **Trusted gateway code** | Local executor daemon, remote Loopex gateway, sandbox manager | Trusted to enforce grants, fences, resource policy, receipts, and cleanup. |
| **User workspace content** | Source files, tests, configuration, repository instructions | Data that tools may read or mutate; never automatically brain code. |
| **Project resources** | Context files, skills, templates, package declarations | Behavior-shaping data requiring explicit admission; not authority. |
| **Generated or tenant code** | Model-written scripts, candidate tools, build output | Untrusted until isolated and explicitly promoted through review. |
| **External clients and workers** | IDE, web client, non-BEAM hand | Authenticated and authorized by host/transport; protocol input remains untrusted data. |

BEAM process isolation is a reliability boundary, not an OS security boundary.
Loaded code is trusted code. A connected distributed node is a trusted peer. A
container or microVM is a security boundary only to the degree its concrete
runtime, mounts, network, credentials, kernel, and resource policy make it one.

### 16.2 Project-resource admission

Resource packs contain prompts, context files, skill instructions, templates,
and static assets. “Data-only” means they do not directly load code. They can
still instruct a model to run dangerous tools, disclose information, or install
software.

Project-local resources therefore require an explicit deterministic admission
decision:

- the interactive reference CLI shows provenance and requests trust before
  enabling project-local behavior-changing resources;
- headless mode defaults fail-closed unless the host supplies a positive trust
  decision;
- the admitted content remains subject to normal tool policy and grants;
- a positive decision binds canonical workspace/project identity, repository
  origin and revision where available, resolved resource-set manifest and
  digests, trust scope, decision source, issuance/expiry, and revocation state;
- changing the workspace root, checkout/ref, resolved resource set, or any
  admitted digest invalidates prior admission and triggers re-review.

A previously trusted directory name is not a grant for newly resolved content.
Headless operation fails closed unless the host supplies a positive decision
matching the complete current binding.

Scripts, executable hooks, package-manager commands, installers, and network
fetches are not ordinary resource-pack content. They are hand-package effects
and go through executor policy. `allowed-tools`, manifest capability lists, or
model claims are advisory metadata, never authorization.

There is no model-directed auto-install, auto-update, compile, or load path.

The same admission logic extends to dynamically retrieved content. Memory
recalls, retrieved documents, and selected prompt fragments are untrusted
data by default — retrieved memory turns a one-shot prompt injection into a
persistent one — so provenance is recorded at write time, injected blocks
are typed and delimited toward the model (§13.5), and tool policy is
unchanged by anything a recall says. An always-in-context memory tier
(pinned blocks) requires a stricter write gate than retrieval tiers: what is
always seen must be hardest to write.

### 16.3 Multi-tenant rule

Tenant-supplied code, arbitrary project Elixir, generated extensions, and
unreviewed packages never load into a shared brain VM. A multi-tenant host uses:

- isolated hands;
- a separate runtime or deployment for a stronger trust boundary;
- separately supervised extension-host VMs behind a versioned protocol;
- host-owned signing, review, admission, and tenancy controls.

An extension process inside a shared VM is not tenant isolation. A compromised
trusted extension can compromise that VM.

### 16.4 Observability and redaction

Observability is an edge, not a hidden public protocol. The runtime emits
structured low-cardinality lifecycle telemetry and correlation IDs. An
OpenTelemetry adapter may map them to spans and metrics.

Content capture is opt-in and defaults off for:

- prompts and assistant content;
- provider request/response bodies;
- tool arguments and results;
- stdout/stderr;
- extension state and diagnostics;
- grants and credential references.

Errors are categorized for public/model use and preserve private operator detail
only through the diagnostics plane. Stack traces and raw exceptions do not leak
into model history or ordinary public events.

## 17. Trusted extensions and generated code

### 17.1 Three package classes

Loopex keeps three classes separate:

1. **Resource packs.** Prompts, skills, context, templates, and static assets.
   They cannot register processes or directly perform effects.
2. **Trusted brain extensions.** Retained compiled OTP applications loaded into
   a brain or dedicated extension-host VM. They have full authority in that VM.
3. **Hand/tool packages.** Executor-side tools, runtime images, scripts, or
   services behind the job protocol and host policy.

The package class is part of the trust decision. Renaming executable content as
a “skill” or “resource” cannot evade the hand boundary.

### 17.2 Extension manifest

A trusted extension manifest declares:

- globally unique extension ID and semantic version;
- manifest schema version and supported Loopex extension-API range;
- immutable content digest, provenance, and host-supplied trust/signing
  evidence;
- OTP application and entry module from already validated trusted bytes;
- namespaced contribution IDs, schemas, and contribution classes;
- brain, extension-host, or hand placement;
- declared supervised children and health checks;
- state schema version and upgrade/downgrade callbacks when stateful;
- required features and protocol capabilities;
- reload/unload support;
- dependencies, deterministic order, conflicts, protected namespaces, and
  replacement declarations;
- module and atom budget.

Untrusted strings never become atoms or module names. Installation resolves a
reviewed package into trusted retained metadata. Runtime activation consumes
that trusted resolution; it does not fetch or compile arbitrary source.

A trusted extension is a sealed immutable closure. Validation resolves its
declared OTP applications, extension-owned BEAM modules, non-core dependencies,
`priv` assets, and module digests before activation. The VM-global manager loads
only prepared retained bytes. Shared-VM activation rejects undeclared modules,
extension-controlled code-path mutation, runtime compilation, and dynamic
loading from unvalidated paths. If that closure cannot be enforced, the package
runs in a separate extension-host VM or as a hand package.

### 17.3 Contribution classes

Extension contributions are explicit and versioned:

- tools and executor adapters;
- model adapters;
- commands and optional shortcuts;
- context providers (memory recall, document/knowledge retrieval, repository
  maps, playbook fragments — injected as provenance-typed candidate blocks,
  §13.5);
- context transformers and compaction strategies (prune, reorder, or mold
  context within declared contracts);
- prompt libraries and selectors (versioned, digest-addressed prompt
  fragments with extension-owned relationships; selection routes the
  system prompt per task and is recorded in the context receipt);
- memory observers (consume public events to build external stores — the
  write path of memory);
- observers and event projectors;
- interceptors;
- client renderers and generic interaction UI hints;
- supervised extension children.

Their semantics differ:

- **Observers/projectors** (memory observers included) cannot alter durable
  decisions. Failure becomes bounded administrative diagnostics; their
  stores are rebuildable projections, never a second session truth.
- **Context providers** contribute bounded, provenance-typed candidate
  blocks only. They are read-only toward their stores during a turn, run
  under deadlines and budgets, and degrade to omission on failure.
- **Context transformers and prompt selectors** run in deterministic order
  within declared contracts. They cannot forge provenance, strip trust
  typing, or turn a selection into authority; every selection is journaled
  in the context receipt.
- **Interceptors** may transform within a declared contract, constrain, defer,
  or deny. Ordering and timeout behavior are deterministic. They cannot grant
  authority over a host denial or directly perform an effect.
- **Effect providers** act through the normal operation, grant, executor,
  receipt, and reconciliation protocol.
- **Renderers/UI contributions** never own terminal state, credentials, or
  interactions. The host renders generic requests.

Extensions cannot change core event meaning, per-session ordering, terminal
uniqueness, commit-before-publication, effect fencing, or authority semantics.
They publish namespaced extension commands/events through reserved envelopes.

Core modules and protected namespaces cannot be overridden. Same-name tool or
client contribution replacement requires an explicit manifest conflict rule
and activation evidence.

Every contribution hook ships with conformance tests proving the hook is
load-bearing. A seam that exists in the API but is silently ignored by the
runtime is a defect class, not a version gap.

### 17.4 Selection and code-generation leases

Each runtime has an immutable extension selection, while executable module
revision is part of the VM-global code generation. Every contribution dispatch
acquires the relevant runtime-selection lease and VM code-generation read
lease, including:

- command admission hooks;
- policy/interceptor callbacks;
- context and event projection;
- model adapter callbacks;
- snapshot and compaction work;
- tool resolution and execution callbacks;
- renderer metadata;
- extension-owned child work.

An activation write barrier blocks new affected leases across every runtime in
the VM and drains existing ones. “No new runs” alone is insufficient because
extensions execute outside run starts.

### 17.5 Quiescent activation and recovery

Same-name modules cannot route revision A to one process and revision B to
another merely through a pointer. The BEAM keeps current and old versions, and
loading a third version consumes or purges the oldest slot. Atomic module-set
loading is also not an atomic transaction with durable selection, external
state migration, child startup, or health checks.

Activation therefore has a private durable VM-code record:

```text
prepared(A, B, artifact digests, state snapshot)
  -> quiescing
  -> code_loaded
  -> state_migrated
  -> candidate_healthy
  -> generation_committed
  -> released
```

Preparation validates the sealed artifact, provenance, API range, dependency
and reverse-dependency closure, namespace conflicts, migration fixtures, and
resource budgets. Compilation, tests, linting, scanning, and candidate trials
occur outside the target brain VM. The exact previous artifact and immutable
pre-migration state remain retained.

Quiescence blocks new affected leases across all same-VM runtimes, drains
callbacks, and stops affected children in dependency order. The code manager
then prepares and atomically finishes the complete module set, rejecting
`-on_load`, partial, unexpected, or ungoverned modules. Stateful children use a
tested `sys:change_code` version pair or restart from externalized versioned
state. Only after candidate health and a durable generation commit may queued
work resume.

Before `generation_committed`, candidate phases perform no irreversible
external effect. Health checks and migrations receive extension-administration
authority, not session credentials, workspace grants, or arbitrary executor
authority. Any necessary effect is isolated and explicitly compensable.

Every transition is idempotent and carries enough retained evidence for
restart. On manager or VM recovery, affected dispatch remains fenced until the
activation record is resolved. Loopex restores the durably selected generation
or resumes only a specifically safe phase using the same artifact and state
digests. Loaded code alone never proves that B became authoritative. A partial
module set or ambiguous generation must never become observable.

### 17.6 Exact rollback rule

Suppose retained generation A is current, then candidate B becomes current and
A becomes the old same-name code version. If B fails migration or health:

1. stop B children and all B contribution dispatch;
2. keep the activation barrier closed;
3. use `code:soft_purge/1` and, where useful,
   `erlang:check_process_code/2` to prove old retained A is not executing;
4. soft-purge old A to free the BEAM's second version slot;
5. reload the exact retained A artifact, making A current and B old;
6. restore or downgrade externalized state, restart A children, and prove A is
   healthy and usable;
7. purge old B only when no reference remains;
8. commit the restored generation and release queued work.

If any safe-reference or soft-purge proof fails, Loopex does not force-purge and
does not claim in-place rollback. It fails closed: restart the complete VM code
domain on retained A, then reconstruct and replay every member runtime before
releasing work. A dedicated extension-host VM is restarted directly; a shared
in-brain domain may require restarting the BEAM. Conformance fault injection
covers every activation and rollback phase, repeated activation, bounded
atom/code growth, and partial-load failure.

### 17.7 Extension state

Stateless callbacks are preferred. Stateful extensions externalize versioned
state and provide tested upgrade and downgrade fixtures. Extension process state
is never the sole durable copy of session-critical information.

If a future product requires uninterrupted side-by-side revisions, it runs
separate extension-host VMs behind a versioned protocol. Loopex does not promise
simultaneous same-name revisions inside one VM.

An extension-host VM is a separately trusted service, not a partial sandbox. A
tenant- or project-supplied host receives only the narrow portable protocol: no
brain credentials, native distribution membership, or direct runtime/journal
store handles.

### 17.8 Runtime distributions

Do not require a compiler in every production brain:

- **Minimal runtime distribution:** runs sessions and previously retained,
  validated extension artifacts.
- **Developer/builder distribution:** includes compiler, file watcher, and
  local extension-author tooling.
- **Validation hand or VM:** compiles, tests, lints, scans, and packages
  candidates outside the brain.

The packaging plan for each release says which distribution it produces and
which OTP applications it contains.

### 17.9 Generated-code lifecycle

“Generated code” means three different things:

1. **Workspace changes.** Source, tests, and configuration written into the
   user workspace through ordinary tool effects.
2. **Ephemeral executable candidates.** Scripts, compilers, tests, and tools run
   only inside a selected hand with explicit budgets.
3. **Candidate brain extensions.** Rare artifacts proposed for explicit review,
   packaging, and trusted activation.

The promotion path is:

```text
request
  -> source and tests in an isolated workspace
  -> deterministic source/package checks
  -> compile/test/lint/scan in disposable hand or VM
  -> bounded repair loop over external diagnostics
  -> immutable candidate artifact + provenance + evidence
  -> host/operator trust decision
  -> signed or otherwise approved retained package
  -> quiescent extension activation transaction
```

Model output, passing tests, sandbox reports, package metadata, resource files,
and declared capabilities are evidence. None grants live brain authority.

### 17.10 Production core upgrades

0.x promises continuity of durable session history across governed trusted
extension replacement. It does not promise arbitrary hot replacement of the
Loopex release itself.

Production `.appup`/`.relup` upgrades require later work:

- exact old/new packaged fixtures;
- upgrade and downgrade callbacks for every state-bearing process;
- safe purge/reference checks;
- mixed-version protocol and node compatibility;
- interrupted-upgrade recovery;
- storage migration compatibility and rollback;
- operator runbooks and exact-artifact evidence.

Restart plus journal replay remains a supported continuity mechanism even after
hot release upgrades exist.

## 18. Embedded API, transports, and clients

### 18.1 Embedded Elixir API

The public API remains small and runtime-scoped:

```elixir
{:ok, runtime} = Loopex.start_link(runtime_options)

{:ok, session_id} =
  Loopex.create_session(runtime, session_options,
    command_id: Loopex.ID.command()
  )

{:ok, attachment} =
  Loopex.attach(runtime, session_id,
    request_id: Loopex.ID.request(),
    client_id: "my-app",
    attachment_key: "primary",
    after_event_sequence: 0
  )

{:accepted, command_id} =
  Loopex.command(attachment, %Loopex.Command.Prompt{
    command_id: Loopex.ID.command(),
    content: [%Loopex.Content.Text{text: "Fix the failing test"}]
  })

for event <- Loopex.events(attachment) do
  handle_event(event)
end
```

Intended surface:

- runtime start/stop and health;
- runtime-scoped session create/list/stop/fork and consistent read-only lookup;
- attachment request, incarnation, snapshot/cursor, replacement, and detach;
- command admission;
- authoritative snapshot;
- durable events and transient progress;
- extension-generation inspection and activation request through host policy.

Model, store, policy, artifact, broker, executor, and extension implementations
are ordinary behaviours, not global plugin macros.

### 18.2 JSONL RPC

The first language-neutral transport is long-lived stdin/stdout RPC:

- strict LF-delimited JSON records;
- correlated admission/query responses plus asynchronous events/progress;
- explicit `hello`, version, feature, and limit negotiation;
- snapshot/cursor attachment;
- interaction request/response round trips;
- no terminal escape codes on protocol stdout;
- bounded diagnostics on stderr;
- identical DTO semantics to the embedded API;
- frame-size, fragmented-input, malformed-input, slow-consumer, and backpressure
  tests;
- golden-vector sample clients in Elixir, Python, and JavaScript.

The same command families cover prompt, steer, follow-up, abort, interaction,
session lifecycle, compaction, fork, snapshot, and state queries. Admission
responses remain separate from asynchronous work.

### 18.3 Reference daemon

The local daemon adds:

- Unix-domain-socket transport;
- one-controller/many-observer policy;
- stale-controller fencing and crash takeover;
- session list/open/stop;
- the ADR-selected daemon-grade durable store;
- race-free snapshot/cursor replay;
- backpressure and reconnect behavior;
- process/service lifecycle and diagnostics.

The daemon is an adapter and reference host. It does not move controller leases,
user identity, or authorization into core semantics.

### 18.4 Reference CLI

The reference CLI is a real product and conformance consumer, not a debugging
shell. Its minimum flows include:

- prompt and streamed answer;
- visible tool calls, results, and artifacts;
- abort with truthful cleanup outcome;
- steering and queued follow-up;
- `/model` switching with continuation compatibility handling;
- session resume, branch/fork, and attachment;
- project-resource trust admission;
- extension selection/code-generation inspection and developer reload;
- explicit local versus isolated executor selection.

The CLI documents that local execution has the user’s OS authority and trusted
extensions have full authority in its VM. Its default `AllowAll` policy is for a
trusted developer, not an enterprise permission model.

Initial UI may be line-oriented and use an Elixir terminal library. A richer
alt-screen client can arrive later or live outside Elixir over RPC. UI ambition
must not delay a useful runtime.

### 18.5 Print and event modes

After the core RPC path is stable, the CLI may expose:

- one-shot print mode for a prompt and terminal result;
- one-way JSON event mode for simple pipelines;
- long-lived bidirectional RPC for real clients.

These modes are projections of the same session semantics and do not create
alternate loops.

### 18.6 Agent Client Protocol

ACP is the most important planned editor edge. It standardizes editor-agent
JSON-RPC, streaming updates, multiple sessions, and bidirectional permission
requests.

Loopex must perform an ACP semantic mapping and conformance spike before
freezing its public protocol v1. ACP does not replace the internal durable
operation, journal, receipt, fencing, or reconciliation model. A later
`loopex_acp` adapter maps:

- sessions and prompts;
- content blocks and diffs;
- progress and terminal outcomes;
- tool/permission interactions;
- cancellation and reconnect behavior.

Any ACP concept without a lossless Loopex mapping is documented before protocol
freeze rather than patched after release.

### 18.7 Other ecosystem protocols

- **MCP** may expose or consume tools/resources at an edge. It is not Loopex’s
  authority model, operation ledger, or effect-receipt protocol.
- **A2A** may connect independent agents or host-orchestrated sessions. It does
  not create built-in multi-agent orchestration.
- **AG-UI** may project events into a frontend. It does not define durable
  session truth.
- **Agent Skills** may map a restricted data/resource subset. Scripts become
  hand packages, and `allowed-tools` never grants permission.

Adapters reserve stable mappings for session, command, content, tool, artifact,
interaction, and outcome identities. They cannot redefine event ordering,
terminal uniqueness, fencing, or host authority.

### 18.8 Later transports

After semantic stability:

- WebSocket for remote and browser clients;
- HTTP for administrative queries, not token-stream ownership;
- native trusted-BEAM adapter for in-cluster callers;
- generated client SDKs from frozen schemas.

Every transport implements the same admission, attachment, snapshot, cursor,
and interaction semantics.

## 19. Future hosts and ecosystem posture

### 19.1 Expected consumers

| Consumer | Loopex supplies | Consumer owns |
| --- | --- | --- |
| Reference CLI | One runtime, local policy, sessions, tools, events, local or isolated hands | Developer UX and explicit trust choices |
| IDE/editor | ACP adapter, diffs, progress, interactions, cancellation, replay | Editor identity, UI, permission presentation, workspace UX |
| CI/headless harness | Idempotent lifecycle, terminal outcomes, replayable events, exact artifacts | Repository credentials, approval strategy, pipeline policy |
| Security-rich assistant | Runtime instances, policy/grant seam, generic interactions, event projection, executor port | Identity, security, secrets, memory, objectives, channels, delivery |
| Team coding service | Isolated runtime/session mechanics, workspace leases, broker seam, observer streams | Tenancy, quotas, worktree allocation, review, fleet policy, audit |
| Remote worker fleet | Capability requirements, jobs, leases, fences, receipts, reconciliation | Provisioning, certificates, placement, autoscaling, capacity |

### 19.2 Secured sample host

The Loopex repository should ship a small standalone secured-host example before
public protocol freeze. It proves:

- authenticated transport admission outside core;
- allow/deny/defer policy;
- durable generic confirmation;
- scoped opaque grants;
- credential references and ephemeral resolution;
- pre-persistence/public redaction;
- host-owned writer fencing;
- feature-flagged adoption and rollback;
- no private process or journal access.

The example is deliberately generic. It is conformance evidence, not an
enterprise product.

### 19.3 Potential security-rich host integration

[Allbert Assist](https://github.com/lexlapax/allbert-assist/) is one possible
future host and a source of design lessons, not a dependency, release
prerequisite, or architectural owner. A future adapter would map:

| Host concern | Loopex seam |
| --- | --- |
| Authenticated inbound request | Durably admitted Loopex command |
| Security decision | Policy allow/deny/defer plus opaque grant |
| Registered capability execution | Executor or tool-provider implementation |
| Confirmation | Generic interaction rendered and authorized by the host |
| Durable conversation/audit | Projection of Loopex public events |
| Long-term context | Host context/resource provider |
| Objectives and fan-out | Host composition of multiple Loopex sessions |
| External delivery | Host outbox consuming public events |
| Secrets and redaction | Host credential/content-protection/store adapters |

Loopex IDs, model output, tool metadata, interaction answers, trace IDs, and
grants never bypass that host’s own capability and security boundaries. Loopex
does not import that host's authority model or implementation into core; product
concepts are translated explicitly at the adapter edge.

Actual integration requires a separately authorized roadmap and architecture
decision in [Allbert Assist](https://github.com/lexlapax/allbert-assist/). It is
not mandatory Loopex release scope. Eventual adoption should be feature-flagged,
preserve the existing route initially, and allow rollback without rewriting the
host’s persistent data.

Loopex begins as an independent implementation. Its founding codebase copies no
source, tests, private contracts, or proprietary material from
[Allbert Assist](https://github.com/lexlapax/allbert-assist/) or another
harness. Public documentation, released behavior, and architecture lessons may
inform independently written designs and tests, with material sources cited.
Any later copied or adapted code requires explicit license, provenance,
attribution, security, and coupling review plus maintainer approval.

**Lessons from a prior system.** The correctness invariants this vision
insists on — one owner serializes a session; intent commits before dispatch;
facts commit before publication; a lost effect is unknown, never blindly
retried; channels render rather than own loops; generated code compiles away
from the coordinator — were learned operating
[Allbert Assist](https://github.com/lexlapax/allbert-assist/), a
security-centered assistant runtime. The most relevant records are its
coding-surface and authority-boundary analysis
([pi-integration-rethink.md](https://github.com/lexlapax/allbert-assist/blob/main/docs/archives/pi-integration-rethink.md)),
its cooperative-cancellation and child-process-kill contract
([ADR 0085](https://github.com/lexlapax/allbert-assist/blob/main/docs/adr/0085-cooperative-cancellation-and-child-process-kill.md)),
and the release retrospective in which resource ownership — not fan-out
logic — proved to be the systemic root of its concurrency defects
([archived v1.1 plan](https://github.com/lexlapax/allbert-assist/blob/main/docs/plans/archives/v1.1-plan.md)).
The complete set of consulted documents is linked directly in §29.6. The
lessons flow into Loopex; the code does not.

### 19.4 Team product boundary

A team coding product adds organization and role identity, repository and
secret policy, worktree leases, review and merge rules, shared observer
dashboards, quotas, scheduling, remote worker pools, audit retention,
compliance exports, and multi-session orchestration. Those are hosts around
Loopex, not reasons to put tenancy or workflows in the kernel.

### 19.5 Host conformance matrix

Before ecosystem beta, execute one equivalent semantic operation through:

- embedded reference CLI;
- secured sample host;
- ACP client mapping;
- remote gateway/executor.

The resulting durable operation identity, outcome algebra, public-event order,
snapshot meaning, cancellation semantics, and receipt/fencing behavior must be
equivalent even though presentation, policy, and placement differ.

## 20. Repository seed

### 20.1 Initial layout

The repository begins as one monorepo and version train with four visible
areas: the standard-runtime-only protocol/core/runtime application; replaceable
adapter and reference-client applications; language-neutral conformance
fixtures; and executable examples plus documentation. Physical package or
repository splits require demonstrated external-consumer, deployment,
ownership, or release pressure and an ADR.

This vision intentionally does not freeze application names or a complete
directory tree. The bootstrap should nevertheless make dependency direction
obvious: core never imports adapter, client, provider, store, executor, or host
implementations.

**Bootstrap runtime floor.** Erlang/OTP 26+ and Elixir 1.17+ are the
repository-start compatibility target, not an eternal promise. A runtime-floor
ADR validates the exact code-loading, terminal, disposable-node, dependency,
and platform requirements before the first compatibility claim. CI then tests
the accepted floor and current stable releases; later floor changes require an
ADR and compatibility notes.

### 20.2 First documents to derive

This document seeds, but does not contain, the repository's operational
documents. Derive a concise README and AGENTS file, an implementation
architecture, the active bounded plan, constraining ADRs, protocol/conformance
specifications, developer/test guidance, and operator recovery guidance. Plans
own dates, staffing, exact build inventories, and release acceptance; ADRs own
decisions that refine this vision.

### 20.3 Founding `AGENTS.md` rules

The derived AGENTS file should carry only rules an implementation agent must
remember every turn: reading and authority order, dependency direction,
runtime and VM-global code ownership, durability ordering, complete
fencing/reconciliation identity, trust and credential boundaries, temporary
test homes, warning-free checkpoints, and the obligation to update contracts
when behavior changes. Detailed rationale remains here or in ADRs and developer
documentation.

### 20.4 ADR agenda

Focused ADRs should precede implementation where evidence must choose among
valid designs. The initial agenda covers runtime and VM-global code ownership;
the three durable transaction domains; operation-kind and terminal semantics;
public schemas and attachment delivery; store selection and migrations;
provider continuation and exact context staging; tool/executor/grant contracts;
extension activation and rollback; isolated and remote hand threat models; ACP
mapping and protocol-v1 criteria; and compatibility/deprecation policy.

### 20.5 Documentation as product

The repository should become practical learning material for Elixir and AI:

- every OTP process has an ownership-focused moduledoc;
- every public behaviour has a smallest working adapter;
- examples progress fake model → real model → custom tool → durable store →
  RPC client → trusted extension → isolated hand → remote hand;
- each architectural claim names the OTP primitive and Loopex contract behind
  it;
- examples avoid hidden global state and unexplained macros;
- conformance suites are documented as tools for adapter authors;
- a “build the loop from first principles” guide stays executable against real
  code.

## 21. Delivery strategy

Delivery is vertical and useful. Loopex should become a real coding loop early,
then deepen its durability and ecosystem evidence without turning the vision
into a release backlog. A bounded contract-experiment stage may test the
riskiest OTP claims and freezes nothing. Every actual stage receives its own
accepted plan, which may split, resequence, or omit future capabilities while
preserving the founding boundaries.

The capability ladder is guidance rather than version scope:

| Stage | Constitutional question answered |
| --- | --- |
| Contract experiments | Are session durability, effect truth, and VM-global trusted-code evolution feasible with the stated OTP semantics? |
| Useful local kernel | Can one developer use a small, durable, truthful coding loop through the embedded API and reference client? |
| Durable service | Can independent clients attach, recover, and agree on one protocol candidate without owning session lifetime? |
| Governed extension runtime | Can trusted behavior evolve without changing session truth, weakening authority, or pretending code is runtime-local? |
| Isolated hands | Can generated and less-trusted work execute outside the brain through the same effects contract? |
| Remote ecosystem | Can the contract span workers and materially different hosts without turning Loopex into a fleet or product-policy platform? |
| Compatibility baseline | Are public contracts proven by independent consumers, migrations, rollback, and packaged operation? |

The serial barriers are durable local truth before multi-client protocol;
extension namespaces and activation evidence before public-protocol freeze;
isolated-hand conformance before remote workers; and materially different
consumer evidence before 1.0. Restart plus replay remains the continuity
mechanism until release hot upgrades receive separate proof.

### 21.1 Planning rule

The vision names questions and serial barriers; plans name work. Every active
plan states its purpose, bounded scope, non-goals, dependencies, parallel
workstreams, fault and conformance evidence, real-path validation, migration
and rollback impact, packaging expectations, and explicit deferrals. A missing
proof delays a compatibility claim; it does not silently weaken an invariant.

## 22. Ownership and serial barriers

Implementation may parallelize core/runtime, protocol/store, model/context,
executor/tool, client/extension, and security/conformance work only after their
shared contracts are explicit. No workstream may create an alternate session
loop, private authority path, or competing durability truth to avoid a barrier.

The enduring rejoin order is:

```text
durable local session and operation truth
-> multi-client attachment and protocol candidate
-> extension namespaces plus VM-global activation proof
-> public protocol compatibility decision
-> isolated-hand conformance
-> remote-worker and multi-host compatibility evidence
```

Active plans decide staffing and exact gates. Rejoin evidence remains
proportional to the claim: pure/property tests for reducers, reusable
conformance at every edge, fault injection for durable transitions, exact
artifact and migration evidence for releases, and real provider/executor paths
where product behavior is claimed.

## 23. Verification and acceptance philosophy

### 23.1 Evidence hierarchy

Tests prove contracts; demonstrations prove usability. Videos and walkthroughs
are supplementary, never the only acceptance evidence.

Release evidence is:

- bound to exact source SHA and artifact digest;
- machine-readable where practical;
- reproducible from documented commands;
- explicit about seed, counts, timing, provider/executor identity, platform,
  and limits;
- stored with PASS criteria and failure artifacts;
- run against temporary homes and workspaces;
- based on real configured providers/endpoints for attended product acceptance.

Fakes, fixtures, and simulators belong in automated tests. They do not replace
real-provider or real-sandbox validation where a release claims those paths.

### 23.2 Test layers

1. **Pure reducer and property tests.** Generated command, result, duplicate,
   crash, cancellation, and recovery sequences assert legal states,
   monotonicity, terminal uniqueness, queue ordering, and replay equivalence.
2. **Behaviour conformance suites.** Every code store, runtime store, journal
   store, model, artifact store, policy, executor, broker, extension, and
   transport adapter runs a reusable suite.
3. **Process fault injection.** Kill provider tasks, tool tasks, coordinators,
   event hubs, stores, extension children, clients, gateways, and workers at
   every durable transition.
4. **Storage fault injection.** Fail before/after write, flush, fsync, index,
   commit marker, transaction reply, snapshot, migration, and tail recovery.
5. **Protocol vectors.** Canonical JSON fixtures, language-neutral job/receipt
   fixtures, unknown fields/types, version negotiation, frame fragmentation,
   duplicate commands, cursor replay, interaction races, and slow consumers.
6. **Security negative tests.** Wrong grant audience/expiry/fence, stale writer,
   project-resource denial, secret fixtures, poisoned-recall fixtures (a
   poisoned memory or retrieval block must never produce an unapproved
   effect), extension namespace collision, generated-code load attempts,
   untrusted distribution peer, and path assumptions.
7. **Real integrations.** Every claimed provider, durable store, extension
   load path, isolation boundary, or remote topology receives attended evidence
   appropriate to that claim.
8. **Packaging.** Install and exercise the exact built release/package, not only
   the source tree.

All automated tests use a temporary `LOOPEX_HOME` and temporary workspace.
Tests never write to a developer’s real home, session store, credential store,
or project unless the attended scenario explicitly opts in.

### 23.3 Core invariant suite

The following should become named, continuously enforced properties:

- Two runtime instances coexist without global-state collisions.
- One active run exists per session in 0.x.
- One terminal event exists per admitted run and per logical tool call; private
  retry attempts do not create competing public terminals.
- `outcome_unknown` remains immutable; reconciliation appends rather than
  rewrites.
- Journal/outbox transaction commits before stable publication or effect
  dispatch.
- `commit_unknown` prevents acknowledgement, publication, and dispatch until
  resolved.
- Replay reaches the same canonical state as uninterrupted execution.
- Repeated scoped command IDs with the same canonical digest cannot duplicate
  work; a different digest conflicts.
- VM-code, runtime, and session mutations resolve through their correct durable
  domains; attachment retries never replay stale capabilities.
- Every effect intent commits before dispatch.
- Every live result matches operation, attempt, current session epoch, and the
  operation kind's dispatch identity; executor effects additionally match
  executor epoch, identity, and fence.
- Prior receipts affect recovered state only through a current validated
  reconciliation query and complete origin tuple.
- Session restart cannot leave an unfenced child completing against rebuilt
  state.
- Complete tool results correspond to complete tool calls and persist in source
  order.
- Partial, malformed, or truncated tool calls never execute.
- Progress and diagnostics never become canonical public state.
- Exact staged context and canonical model-request digest commit with the model
  intent before dispatch; recovery cannot silently rebuild different input.
- Injected blocks carry derived lineage and provenance typing to the provider
  payload and cannot bypass tool policy or grants.
- Client disconnect never owns session lifecycle.
- Slow attachments never block coordinator progress.
- Coordinator callbacks perform no blocking external work except the bounded
  journal transaction.
- Host metadata, IDs, interactions, model output, and extension metadata never
  grant authority.
- Workspace references remain opaque to core.
- Known credential material never appears in prohibited planes.
- Generated, tenant, or arbitrary project code never loads into a brain VM.
- Native distribution connects trusted gateways only.
- No effectful unknown is blindly retried.
- Local, isolated, and remote hands implement one job/receipt contract.
- Same-VM extension activation is VM-global, drains every affected runtime,
  advances a durable phase machine, loads only a sealed atomic module set, and
  follows exact rollback or restart/replay.
- Provider/library structs never cross core or public protocol boundaries.

### 23.4 Minimalism budgets

Minimalism is tested, not declared:

- seven conformance-tested built-in tool implementations with an
  evidence-selected reference profile;
- reference CLI system and active-tool prompt target under 1,000 tokens before
  project context; host budgets remain host-owned;
- no built-in sub-agent, plan, objective, background job, team workflow,
  social channel, or policy engine;
- no external runtime dependency in `loopex` core;
- one canonical semantic contract across transports;
- no public PIDs, module atoms, functions, or raw Erlang terms;
- one page of code can start a runtime, create a session, submit a prompt, and
  consume events;
- every proposed core concept includes an argument for why it cannot be an
  adapter, extension, executor, client, or host concern.

### 23.5 Performance evidence

Measure before setting budgets:

- command admission and transaction latency;
- context-pipeline assembly and per-provider latency and budget pressure;
- snapshot creation/load and replay time by record count;
- provider first-token time versus Loopex overhead;
- event fan-out, per-attachment queue, and slow-consumer cost;
- coordinator mailbox depth and scheduler pressure;
- per-runtime and per-session memory;
- tool output throughput under backpressure;
- artifact spill overhead;
- extension drain time, activation time, and code/atom growth;
- worker selection, dispatch, cancellation, and reconciliation time;
- store recovery and migration time per adapter.

Performance claims cite recorded before/after evidence from equivalent commands,
artifacts, and environments. Do not promise BEAM-scale numbers before measured
baselines.

### 23.6 Release-plan requirements

Each versioned plan turns the relevant vision claims into bounded scope and
explicit evidence. It names purpose and non-goals, ADR prerequisites,
workstreams and barriers, conformance and fault injection, real-path and exact
artifact validation, performance where material, migration/rollback impact,
and the authority required to defer an accepted outcome.

## 24. Compatibility and release governance

### 24.1 Separately versioned surfaces

Loopex has at least these compatibility surfaces:

1. private journal/store schema;
2. public command/admission/event/snapshot/interaction protocol;
3. executor job/receipt/reconciliation protocol;
4. extension manifest, contribution, and lifecycle API;
5. embedded Elixir API;
6. artifact/archive formats when they become public.

They do not freeze together. A stable public event does not freeze the private
journal. A store migration does not imply a wire migration. A package version
does not replace protocol negotiation.

### 24.2 0.x policy

0.x follows semantic versioning. Every public surface is labeled stable,
release-candidate, or experimental.

- Experimental APIs may break in a minor release with explicit migration notes.
- Release-candidate surfaces carry schemas and conformance but no long support
  promise until their freeze criteria pass.
- Stable surfaces define additive-field rules, unknown-value handling,
  reader/writer compatibility, deprecation window, and supported upgrade span.
- Internal process topology, process messages, and private structs are not
  public API.

Public protocol v1 freezes only after embedded API, JSONL RPC, daemon, secured
sample host, ACP mapping, and extension namespaces exercise the semantics.
Executor protocol stability waits for local, isolated, and remote evidence
appropriate to the claimed transport.

### 24.3 Migration and rollback

Every durable migration milestone defines:

- supported source and target versions;
- forward migration;
- interrupted-migration detection and recovery;
- backup/restore or downgrade policy;
- previous-binary reopening boundary;
- extension-state upgrade/downgrade fixtures where applicable;
- exact packaged rollback procedure.

“Restart the old binary” is not a rollback plan if the new binary irreversibly
changed its store.

### 24.4 Publication posture

The repository may publish Hex packages and binary releases once their consumers
justify them. Every binary release records source SHA, artifact digest, OTP/
Elixir versions, platform, included runtime applications, install smoke, and
rollback instructions.

Compiler-bearing builder releases and minimal runtime releases are separate
artifacts when that separation begins. A hands container image is a separately
decided and versioned artifact, not an implicit side effect of documenting
Docker.

## 25. Risks and countermeasures

| Risk | Countermeasure |
| --- | --- |
| Loopex becomes a second host product | Enforce ownership table and minimalism budgets; reject identity, memory, objectives, channels, tenancy, billing, and workflow from core. |
| “Runtime is the framework” becomes unstructured OTP code | Pure reducer, explicit ownership, supervision docs, behaviours only at edges, dependency checks, conformance suites. |
| Global state makes embedding brittle | Runtime reference in every API; instance-scoped registries/configuration; the VM-global code manager is the explicit exception because it owns a VM-global resource. |
| Provider churn shapes core | Canonical Loopex types; direct adapter seam; fake-adapter core build; tested dependency range. |
| Provider-native data is lost | Opaque compatibility-bound continuation sidecar with switch tests. |
| Event sourcing becomes infrastructure theater | Journal only facts needed for recovery; small public vocabulary; progress and diagnostics stay separate. |
| Store timeout duplicates effects | Three-state commit result, transaction ID resolution, fencing before dispatch. |
| Remote effect runs twice | Stable IDs, attempts, durable receipts, idempotency classes, leases, fences, current reconciliation, immutable unknown. |
| Cancellation claims too much | Process ownership before acceptance, escalation, cleanup proof, no rollback claims. |
| Multi-client control races | Durable admission order in core; host/daemon controller policy and writer fencing outside core. |
| Slow clients block work | Durable outbox and owned event dispatcher with bounded per-attachment queues. |
| Protocol freezes too early | Bounded experiments freeze nothing; multi-transport, secured-host, ACP, and extension-envelope evidence precedes v1. |
| A human-readable local store becomes an accidental public database | Explicit experimental private adapter; crash contract; stable archive format separate. |
| Hot reload is oversold | VM-global activation authority, cross-runtime leases, sealed closure, durable phases, exact rollback, two-version/atom budgets, restart/replay fallback. |
| Generated code compromises brain | Compile/run in hands; explicit promotion; no auto-install/load; shared brains reject tenant code. |
| Extension supply chain compromises runtime | Provenance/digest/signing policy, protected namespaces, validation VM, no model-driven installer. |
| Distribution is mistaken for sandboxing | Trusted gateways only; mutual TLS; cookies not auth; isolated portable gateway for less-trusted workers. |
| Host policy leaks into kernel | Mechanism-only policy port, opaque grants, generic interactions, host conformance sample. |
| Credentials leak through traces or persistence | References only, bounded content protection, capture-off observability, seeded negative tests. |
| Retrieved memory becomes a persistent injection channel | Provenance-typed, delimited context blocks; untrusted-by-default recalls; stricter write gates for always-in-context tiers; poisoned-recall negative tests; tool policy unchanged by context. |
| TUI scope delays runtime | Useful line-oriented client first; richer client can attach over protocol. |
| Planning outruns software | Bounded non-freezing experiments, vertical useful stages, and plans that own estimates and exact acceptance. |
| Package/app structure becomes its own framework | One repo/version through 0.x; split only on observed boundary and ADR. |
| Name collides after launch | Complete clearance before first public release while rename cost is low. |

## 26. Current founding decisions

The following are project doctrine unless deliberately revised:

1. Loopex is a greenfield repository and independent implementation.
2. Loopex is an OTP-native coding-session and effects runtime, not a generic
   agent framework.
3. “The runtime is the framework” means direct OTP plus small explicit edge
   behaviours, not an unstructured system and not an agent DSL.
4. The runtime is multi-instance and host-neutral; executable code generation is
   explicitly VM-global, and conflicting code trust domains use separate VMs.
5. The core application has no external runtime dependency.
6. The model boundary is `Loopex.LLM`; the reference adapter uses ReqLLM
   directly; core has no Jido framework dependency.
7. Loopex owns durable coding-session mechanics. Hosts own identity, policy,
   secrets, tenancy, placement, memory, objectives, channels, and product UI.
8. The reference distribution supplies seven conformance-tested tool
   implementations. Its default profile and prompt budget are evidence-driven
   reference-product choices, not kernel policy.
9. Tool execution is serial by default.
10. VM-code truth, runtime-control truth, private session journal, public
    events, snapshots, progress, and diagnostics are separate domains or
    planes.
11. A reference local file representation remains a private adapter format
    until a separately versioned interchange contract is deliberately frozen.
12. Generic operations have kind-specific attempt protocols. Executor effects
    include request digests, epochs, fencing, retained receipts, current
    reconciliation, and immutable unknown outcomes.
13. Credentials remain host-owned and workspace identity remains opaque.
14. Native execution is not a sandbox; distribution connects only trusted
    gateways; less-trusted code uses a narrow OS-isolated hand.
15. Trusted extensions activate through a VM-global manager, sealed artifact
    closure, cross-runtime quiescence, durable activation phases, atomic
    module-set loading, exact rollback, and restart/replay fallback.
16. Production brains need not contain a compiler; builder and validation
    distributions are separate.
17. Bounded contract experiments freeze nothing. Useful local session/effect
    truth precedes multi-client freeze; governed extensions precede protocol v1;
    isolated hands precede remote workers.
18. ACP mapping occurs before public protocol v1 freeze.
19. Actual integration into an external host is separately authorized by that
    host and is not Loopex release acceptance.
20. Restart plus journal replay is the production continuity mechanism before
    separately proven core release hot upgrades.
21. License is Apache-2.0.
22. The working name is Loopex, pending final public clearance.
23. Durable stores are selected by contract and evidence, not language purity;
    core remains independent of every store implementation.
24. The context pipeline is the sole seam for memory, retrieval, and prompt
    systems. The kernel owns lineage, typing, budgets, exact staging, and
    receipts; providers, transformers, selectors, observers, stores, memory
    truth, and trust policy remain extension or host concerns.
25. VM-code commands, runtime commands, session commands, and attachment
    requests have distinct identity, durability, and replay semantics.
26. A model call dispatches only the exact canonical context committed with its
    operation intent; recovery never silently rebuilds different input.

## 27. Open questions and decision triggers

| Question | Decision trigger |
| --- | --- |
| Does final trademark, domain, Hex, and GitHub clearance support “Loopex”? | Before public packages, domains, or compatibility-bearing branding. |
| How rich should the reference terminal become? | Before implementation expands beyond useful line-oriented flows. |
| Which active built-in tool profile should the reference CLI default to? | After representative prompt-cost, shell-avoidance, safety, and task-utility evidence. |
| Which durable store satisfies the runtime and journal contracts, and does a human-readable private adapter remain useful? | Before a durable service makes operational or compatibility claims. |
| What exact JSON Schema subset covers tools, interactions, content, and extension envelopes? | Before public protocol fixtures become release candidates. |
| What is the retention/encryption policy for provider continuation sidecars? | Before a persisted real-provider path is accepted. |
| Which sandbox backend is the first supported isolated hand? | Before claiming an OS isolation boundary. |
| Is an official hands container/microVM image a released artifact or documentation only? | Before publishing or supporting such an image. |
| Which remote transport is primary for non-BEAM workers? | Before remote non-BEAM compatibility is claimed. |
| What ACP subset must map losslessly? | Before public protocol v1 decision. |
| Which materially different consumers qualify the 1.0 compatibility baseline? | Before a 1.0 plan is accepted. |
| What evidence justifies splitting an application or Hex package? | At each proposed split; no default split. |
| When should full production release hot upgrades be attempted? | Only after exact old/new release fixtures and remote/multi-consumer compatibility evidence exist. |
| Which future host first validates the security-rich embedding seam? | Before claiming that host class is conformant; no external repository is modified by default. |
| Does a reference memory extension live in-repo or in the ecosystem? | Before governed context-extension examples are published. |
| Which exact request bytes remain inline and which use immutable artifact references? | During the context/store ADR, without weakening exact reconstructability. |
| Does the reference recall example stay deterministic-lexical before any embedding provider? | During the context-pipeline ADR; replayability favors deterministic-first. |
| Is an always-in-context pinned memory tier core-supported or extension-simulated? | Before public protocol v1 freeze. |
| Does the bootstrap OTP/Elixir floor survive dependency and platform evidence? | Before the first compatibility-bearing release. |

## 28. Name and license

### 28.1 Name

**Loopex** means “the loop, in Elixir.” It encodes the central thesis that an
agent is a loop around an LLM and follows familiar Elixir ecosystem naming.

Before the first public release:

- perform a professional trademark search in relevant software classes;
- confirm Hex package availability;
- confirm repository organization/name availability;
- register chosen domains and social identifiers where desired;
- check package-manager and major search-engine collisions;
- rename before public compatibility promises if clearance is weak.

The working name is a decision for repository creation, not a claim of legal
clearance.

### 28.2 License

**Apache License 2.0** is the founding license. It is permissive for open-source,
commercial, and enterprise hosts and includes an explicit patent grant.

Loopex is an independent implementation informed by public product behavior and
primary-source runtime documentation. Any later copied or adapted code requires
explicit license, provenance, attribution, security, and coupling review plus
maintainer approval.

## 29. Informative design sources

These are design inputs, not compatibility promises unless a later ADR or
public specification says otherwise. Mutable external sources were last
reviewed on 2026-08-14.

### 29.1 Elixir and Erlang runtime

- José Valim, [Elixir coding-harness thread](https://x.com/josevalim/status/2088186994849468659).
- Erlang/OTP, [secure coding and deployment guidance](https://www.erlang.org/docs/29/system/secure_coding.html).
- Erlang/OTP, [compilation and code loading](https://www.erlang.org/doc/system/code_loading.html).
- Erlang/OTP, [`code` module](https://www.erlang.org/doc/apps/kernel/code.html).
- Erlang/OTP, [release handling](https://www.erlang.org/doc/system/release_handling.html).
- Erlang/OTP, [`sys` module and code-change facilities](https://www.erlang.org/doc/apps/stdlib/sys.html).
- Erlang/OTP, [`peer` module](https://www.erlang.org/doc/apps/stdlib/peer.html).
- Erlang/OTP, [TLS distribution](https://www.erlang.org/doc/apps/ssl/ssl_distribution.html).
- Elixir, [`GenServer`](https://hexdocs.pm/elixir/GenServer.html) and
  [`Supervisor`](https://hexdocs.pm/elixir/Supervisor.html).
- Livebook, [runtime topology](https://livebook.hexdocs.pm/runtime.html).

### 29.2 Coding harnesses and server architecture

- Pi, [project](https://pi.dev) and
  [coding-agent README](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md).
- Pi, [JSON mode](https://pi.dev/docs/latest/json),
  [RPC mode](https://pi.dev/docs/latest/rpc),
  [extensions](https://pi.dev/docs/latest/extensions), and
  [security](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/security.md).
- Codex CLI, [repository](https://github.com/openai/codex).
- OpenCode, [server architecture](https://opencode.ai/docs/server/).
- OpenClaw, [project](https://github.com/openclaw/openclaw).

Pi validates the small-loop, rich-extension, multiple-hosting-mode product
shape; OpenCode validates the client/server topology; Codex CLI validates the
terminal-native provider-backed harness category. Loopex promises
compatibility with none of them. These harnesses are studied design inputs,
nothing more: no Loopex default or construct is justified by pointing at one,
and the reasoning behind each choice lives in this document and its ADRs.

### 29.3 Model adapter substrate

- ReqLLM, [repository](https://github.com/agentjido/req_llm) and
  [Hex package](https://hex.pm/packages/req_llm).

### 29.4 Client, tool, and agent ecosystem protocols

- Agent Client Protocol,
  [introduction](https://agentclientprotocol.com/get-started/introduction) and
  [architecture](https://agentclientprotocol.com/get-started/architecture).
- Model Context Protocol, [specification](https://modelcontextprotocol.io/specification/2025-11-25).
- Agent Skills, [specification](https://agentskills.io/specification).
- A2A, [protocol specification](https://a2a-protocol.org/v0.3.0/specification/).
- OpenTelemetry, [generative-AI semantic attributes](https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/).

### 29.5 Memory, retrieval, and context engineering

- Anthropic, [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents).
- Letta, [memory blocks](https://docs.letta.com/guides/agents/memory-blocks).
- Zep/Graphiti, [temporal knowledge-graph memory](https://github.com/getzep/graphiti)
  and [arXiv:2501.13956](https://arxiv.org/abs/2501.13956).
- Mem0, [arXiv:2504.19413](https://arxiv.org/abs/2504.19413) — noting that
  competing memory benchmarks are vendor-run and publicly disputed; treat
  all such numbers as unproven until independently reproduced.
- ACE — Agentic Context Engineering, [arXiv:2510.04618](https://arxiv.org/abs/2510.04618)
  (evolving playbook contexts; delta updates against brevity bias and
  context collapse).
- Spotlighting — provenance marking against prompt injection,
  [arXiv:2403.14720](https://arxiv.org/abs/2403.14720).
- AgentPoison — memory/RAG poisoning,
  [OpenReview](https://openreview.net/forum?id=Y841BRW9rY).
- Code-retrieval posture:
  [Claude Code's move from RAG to agentic search](https://x.com/bcherny/status/2017824286489383315),
  [Cline on not indexing codebases](https://cline.bot/blog/why-cline-doesnt-index-your-codebase-and-why-thats-a-good-thing),
  [Cursor on semantic search](https://cursor.com/blog/semsearch),
  [Aider's repository map](https://aider.chat/docs/repomap.html).

### 29.6 Potential future host and prior-system evidence

[Allbert Assist](https://github.com/lexlapax/allbert-assist/) is one possible
future host and the prior system whose operating lessons §19.3 carries. The
design documents consulted — lessons and evidence only; no code flows
(§19.3):

- [pi-integration-rethink.md](https://github.com/lexlapax/allbert-assist/blob/main/docs/archives/pi-integration-rethink.md)
  — the authority-boundary analysis that puts a YOLO core and a gated
  wrapper in different products.
- [ADR 0068](https://github.com/lexlapax/allbert-assist/blob/main/docs/adr/0068-pi-mode-coding-surface-and-local-coding-trust-tier.md)
  — the linked host's gated coding surface and local-coding trust tier.
- [ADR 0067](https://github.com/lexlapax/allbert-assist/blob/main/docs/adr/0067-tui-terminal-channel.md)
  and
  [ADR 0029](https://github.com/lexlapax/allbert-assist/blob/main/docs/adr/0029-typed-runtime-response-contracts.md)
  — split model/client payloads and typed response contracts (§10.5's
  lineage).
- [ADR 0085](https://github.com/lexlapax/allbert-assist/blob/main/docs/adr/0085-cooperative-cancellation-and-child-process-kill.md)
  — cooperative cancellation and child-process kill (§9.6's lineage).
- [ADR 0091](https://github.com/lexlapax/allbert-assist/blob/main/docs/adr/0091-daemon-backed-tui-session-protocol.md)
  — daemon-backed session protocol and thin terminal client (§18.3's
  lineage).
- [ADR 0032](https://github.com/lexlapax/allbert-assist/blob/main/docs/adr/0032-dynamic-plugin-generation-and-sandboxed-loading.md)
  — sandboxed generation and gated loading of generated code (§17.9's
  lineage).
- [ADR 0083](https://github.com/lexlapax/allbert-assist/blob/main/docs/adr/0083-objectives-parallel-child-fanout.md)
  and
  [ADR 0084](https://github.com/lexlapax/allbert-assist/blob/main/docs/adr/0084-autonomous-channel-notification-authority.md)
  — parallel child fan-out and autonomous-channel notification authority:
  the host-side orchestration and delivery lessons behind §3.2's
  exclusions.
- [Archived v1.1 plan](https://github.com/lexlapax/allbert-assist/blob/main/docs/plans/archives/v1.1-plan.md)
  and
  [request flow](https://github.com/lexlapax/allbert-assist/blob/main/docs/plans/archives/v1.1-request-flow.md)
  — the concurrency retrospective in which resource ownership, not fan-out
  logic, proved to be the systemic root of eight corrective rounds.
- [v1.4 plan](https://github.com/lexlapax/allbert-assist/blob/main/docs/plans/v1.4-plan.md)
  and
  [request flow](https://github.com/lexlapax/allbert-assist/blob/main/docs/plans/v1.4-request-flow.md)
  — the cost evidence for retrofitting a component boundary into a
  monolith: why Loopex is born as the boundary.
- [delegate-agents.md](https://github.com/lexlapax/allbert-assist/blob/main/docs/developer/delegate-agents.md),
  [channel-parity.md](https://github.com/lexlapax/allbert-assist/blob/main/docs/developer/channel-parity.md),
  and
  [cross-channel-threading.md](https://github.com/lexlapax/allbert-assist/blob/main/docs/developer/cross-channel-threading.md)
  — delegate-agent, channel-contract, and threading lessons behind the
  attachment model (§11).
- [active-memory-retrieval.md](https://github.com/lexlapax/allbert-assist/blob/main/docs/research/active-memory-retrieval.md)
  — the deterministic, bounded, replayable recall baseline informing the
  reference context-provider posture (§13.5).
- [codegen-agent-loop-research.md](https://github.com/lexlapax/allbert-assist/blob/main/docs/research/codegen-agent-loop-research.md)
  — the bounded generate/critique/repair committee behind the
  generated-extension lifecycle (§17.9).

Every mention of that project in Loopex documentation must use the canonical
full repository URL, and every consulted document is linked directly. It
remains an external potential host, never a core dependency.

## 30. Closing thesis

Minimal coding harnesses demonstrate that a small loop with a rich extension
seam can be more adaptable than a feature-heavy agent platform. Product hosts
demonstrate that identity, policy, channels, durable delivery, memory, review,
tenancy, and release assurance are real concerns—but they should not be
prerequisites for improving the loop.

Elixir supplies the missing middle. A session can be an actor without becoming
ephemeral. A client can disappear while the session continues. Provider and
tool IO can be concurrent without making durable state concurrent. Trusted
behavior can evolve while history remains in place. A brain can coordinate
hands on another machine. Failure can be observed, fenced, reconciled, and
reported truthfully.

Loopex exposes those runtime properties through a small durable
session-and-effects boundary and stops there. That disciplined boundary is what
allows a terminal harness, an IDE agent, a CI worker, a security-rich assistant,
a team coding platform, and future products to depend on the same core without
forcing the core to become any one of them.
