# Getting Started

<a id="concept"></a>
## Concept

Technical depth: [Commands and code for both tracks](getting-started-technical.md#technical-depth).

This guide is the first stop for a developer. It has two tracks:

- **Building on Loopex** — running Loopex inside your own Elixir application, or
  driving its sessions from a program in any language over the session protocol.
- **Contributing to Loopex** — changing this repository: its toolchain, its
  checks, where each application lives, and how work is planned and closed.

Both tracks start from a source checkout. Nothing is published as a package, and
no surface is stable yet: every API, option, record, and wire shape named here
may change between revisions, so pin an exact revision and read
[Compatibility surfaces](compatibility-surfaces.md#concept) before depending on
one. The guide routes to the pages that own each topic rather than repeating
them.

<a id="concept-getting-started-model"></a>
## What You Are Working With

Loopex is an OTP runtime that keeps coding-agent sessions durable. A **runtime**
is a supervised process tree a host starts explicitly and names by an opaque
reference. A **session** is a durable conversation between an operator and a
model; its history is an append-only journal written by exactly one process at a
time, so a session survives the process that ran it and can be resumed. A
**run** is one task inside a session: the model is asked, may call tools, and is
asked again until it stops, a declared bound is reached, or the run is stopped.
Tools act on a workspace through an **executor**, and every tool call is decided
by the host's **policy** — Loopex never grants itself authority.

A caller watches a session by **attaching** at a position in its committed event
stream. Committed **events** are truth and arrive at least once, in order;
**progress** — the model's text as it streams, a command's output as it runs — is
a transient rendering aid that may be dropped.

Five replaceable boundaries, called ports, separate the kernel from everything
concrete: the Store, the Model, the Executor, the ArtifactStore, and the Policy.
The repository ships one implementation of each except Policy, which every host
supplies itself.

Technical depth: [Building from source](getting-started-technical.md#technical-getting-started-source).

<a id="concept-getting-started-embedding"></a>
## Building On: Embed a Runtime in an Elixir Host

An embedding host calls the `Loopex` facade in process. It starts a runtime,
creates or resumes a session, attaches, submits commands, and reads events; the
runtime runs the loop. The quickest working runtime comes from
`LoopexComposition`, which wires the shipped local Store, the ReqLLM model
adapter, and the local executor with its four coding tools. A host that wants a
different store, model, or executor composes the ports itself and starts the
runtime directly.

What the host must decide, and Loopex will not decide for it:

- **where durable state lives** — a state root directory;
- **which workspace the tools may touch**;
- **who authorizes tool calls** — a policy module and its stable identity; and
- **how much context one request may carry** — a context token budget (the
  reference composition defaults it; a direct runtime requires it).

A model provider also needs its credential and its private companion process,
built once from the checkout. A runtime can be started with no model and no
tools at all; it then creates, attaches to, and recovers sessions but runs no
turns, which is a useful first experiment that needs no credential.

The full contract is [Runtime and embedding](runtime-and-embedding.md#concept);
the turn machine behind it is [Agent loop and tools](agent-loop-and-tools.md#concept).

Technical depth: [A first embedded host](getting-started-technical.md#technical-getting-started-embedding).

<a id="concept-getting-started-policy"></a>
## Building On: Write the Host Policy

The policy is the one boundary every host implements. It receives a bounded
description of one tool call — which tool, its arguments, its effect class, the
workspace — and answers allow, deny, or defer. Anything other than a well-formed
allow is a denial: a policy that crashes, blocks, or answers malformed data
denies, and a denial is reported to the model and never retried.

Defer is how a host asks its operator: it poses one bounded multiple-choice
question, the runtime keeps that question as durable session state, and when an
answer arrives the same policy is asked again with the answer attached. The
answer never grants anything by itself, and a pending question survives the
host process ending.

Technical depth: [A first policy](getting-started-technical.md#technical-getting-started-policy).

<a id="concept-getting-started-protocol"></a>
## Building On: Drive Sessions Over the Wire

A program in any language can drive a session over the experimental session
protocol: one JSON object per line, with an exact generation negotiated first. The
foreground app server speaks it over standard input and output for one client at
a time, and a daemon speaks it over a Unix-domain socket for many clients that
may observe one session while one controls it. Both are launched by a host that
chooses the store, model, tools, and policy; a client drives sessions but never
configures them.

The protocol is strict on purpose — a client that relies on a lenient parser is
not conformant — and it separates durable events, which advance a client's
cursor, from progress, which does not. An independent client written in plain
JavaScript ships in `clients/node` and is the best worked example.

The contract is the [session protocol pair](app-server-protocol.md#concept); the
daemon's hosting model is [the daemon pair](daemon.md#concept); running either is
covered by the operator pages for the
[app server](../operator/app-server.md#concept) and the
[daemon](../operator/daemon.md#concept).

Technical depth: [A first protocol client](getting-started-technical.md#technical-getting-started-protocol).

Technical depth: [Against a daemon](getting-started-technical.md#technical-getting-started-daemon).

<a id="concept-getting-started-adapter"></a>
## Building On: Replace a Port

A different store, model provider, or executor is an edge application that
implements one behaviour and depends inward on core. It joins the port's shared
conformance suite rather than writing its own, returns only bounded plain data
across the boundary, and is wired by a composition — core never learns its
name. The ports, their callbacks, and the suites are in
[the architecture pair](architecture.md#concept-arch-ports).

Technical depth: [Adding an adapter](getting-started-technical.md#technical-getting-started-adapter).

<a id="concept-getting-started-contributing"></a>
## Contributing: Toolchain and Checks

Development needs Git, Bash, ordinary POSIX tools, and the accepted Elixir and
Erlang/OTP toolchain — nothing else. Two supported toolchain pairs are pinned,
and the older one is the floor. While editing, run the focused tests for what
you touched. Before a change is integrated, the fast check runs once: formatting,
warning-free compilation, dependency direction, documentation structure, and the
credential-free test suite. A prose-only change has a documentation mode. The
slow release check, which needs a real provider credential, runs once before a
milestone closes and is not part of everyday work.

Checks are honest by rule: a required check is never skipped, filtered, softened,
or retried into passing, and a failure that disappears on retry is a flake to
fix. [DEVELOPMENT.md](../../DEVELOPMENT.md) owns the commands and prerequisites,
and the [verification guide](verification.md#concept) owns which checks a
change selects and why.

Technical depth: [Everyday commands](getting-started-technical.md#technical-getting-started-checks).

<a id="concept-getting-started-layout"></a>
## Contributing: Where Things Live

The repository is one Elixir umbrella of eleven applications under `apps/`, an
independent client under `clients/`, repository scripts under `scripts/`, and
documentation under `docs/`. Dependencies point inward to the kernel,
`apps/loopex`, and a check refuses any that do not. Tests live beside each
application, and a boundary's shared conformance suite is reused rather than
copied. Public modules and functions document a `Concept` section before a
`Technical depth` section, and project documents come in the same two depths,
as the [development charter](development-charter.md#concept) explains.

Technical depth: [The repository map](getting-started-technical.md#technical-getting-started-layout).

<a id="concept-getting-started-milestones"></a>
## Contributing: How Work Is Planned

Work is maintainer-directed. Bounded work is a milestone: a pair of plan
documents naming its purpose, outcomes, and how each outcome will be proved,
accepted by the maintainer before implementation. Work lands on `main` in small
reviewed changes; a milestone closes only when every outcome maps to tests or
retained evidence and an independent review has read the exact candidate.
Decisions about ownership, trust, public contracts, persistent formats,
dependencies, or migration are architecture decisions, proposed and accepted
before the work that depends on them. [AGENTS.md](../../AGENTS.md) is the
canonical development contract, [the plans register](../plans/README.md) says
what is authorized now, and the [milestone guide](milestones.md#concept) has the
procedure.

Technical depth: [Plans, decisions, and commits](getting-started-technical.md#technical-getting-started-milestones).

<a id="concept-getting-started-diagnosing"></a>
## Diagnosing a Running Runtime

Loopex is diagnosed through its own observability rather than by adding print
statements: a host starts a trace session through the runtime reference it
holds, and telemetry spans arrive at every port call and transaction. Both are
bounded, redacted, and never truth or authority. The contract is the
[observability pair](observability.md#concept); the levels an operator turns on
are in the [operator runbook](../operator/observability.md#concept).

Technical depth: [A first trace session](getting-started-technical.md#technical-getting-started-diagnosing).

## Related

- [Root README](../../README.md) — what Loopex is and where it stands.
- [Architecture](architecture.md#concept) — applications, ports, truth planes,
  and the serial session owner.
- [Developer documentation](README.md).
