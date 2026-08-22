# Loopex

**The loop, in Elixir.**

> **Clarity before mechanism.** Loopex explains purpose, constraints, and
> observable behavior before implementation machinery. Every important
> commitment remains traceable to precise technical contracts and evidence.
> Nothing essential depends on hidden context.

An agent is a loop around an LLM. Loopex makes that loop an OTP-native,
embeddable runtime for durable coding-agent sessions and controlled effects:
a small, provider-neutral model loop with truthful recovery, versioned client
contracts, location-transparent tool execution, and governed live extensions.
It is a minimal terminal coding harness on its own, and small enough to
disappear inside a larger host.

The architectural brief is José Valim's observation about Elixir as a coding
harness substrate, taken literally: **"You don't need an external framework
for this. The runtime is the framework."** Loopex does not hide OTP behind an
agent framework, workflow DSL, or macro layer. Sessions are supervised
processes; durable truth is an append-only journal; clients attach and detach
while the session lives; a session "brain" can coordinate local or remote
"hands"; trusted code can evolve while session state stays in place.

<!-- loopex:readme-status:start -->
## Where Things Stand

**Revision status:** Pre-implementation planning; active milestone `M1` is accepted; no next candidate is recorded.

[Canonical milestone status and plan records](docs/plans/)
<!-- loopex:readme-status:end -->

The [roadmap](docs/roadmap.md#concept) is non-normative capability guidance;
[CHANGELOG.md](CHANGELOG.md) records what changed.

The founding [Concept vision](docs/vision.md#concept) and its
[Technical depth](docs/vision-technical.md#technical-depth) are one decision-bearing authority:
boundaries, invariants, protocol planes, trust model, and delivery shape are
settled there. The [documentation index](docs/) is the approachable route into
the rest of the project.

## Why It Exists

Minimal coding harnesses have proven that a small loop with a rich extension
seam beats a feature-heavy agent platform. Product hosts have proven that
identity, policy, channels, memory, and delivery are real concerns — and that
they should not be prerequisites for improving the loop. Elixir supplies the
missing middle: the BEAM already has the primitives those systems rebuild by
hand — actors, supervision, live code evolution, distribution — and Loopex
adds exactly what the runtime does not supply: stable identities,
transactions, receipts, fencing, reconciliation, protocol versions, and trust
boundaries.

The rules it holds itself to:

- One serial owner per session; durable intent before effects; durable facts
  before publication.
- Truthful failure: a lost effect is `outcome_unknown`, never a blind retry.
- Plain data across every boundary; metadata never grants authority.
- Mechanism in Loopex, governance in the host.
- Generated code is a candidate, not authority.
- Everything entering model context is provenance-typed, budgeted data.
- Every core concept pays rent: if it can be an extension, adapter, or host
  concern, it stays out of the kernel.
- The smallest sufficient system wins; every abstraction names the concrete
  examples or implementations it serves.

## What It Is — and Is Not

The same runtime should support a reference CLI, an IDE agent over the Agent
Client Protocol, CI/headless harnesses, a security-rich personal assistant
host, a team coding service, and remote executor fleets — all over one
semantic contract.

It is deliberately **not** a generic agent framework, a workflow engine, an
identity or policy product, a memory product or RAG framework, a
social-channel hub, a marketplace, or a sandbox-by-supervision-tree. Those
belong to hosts, adapters, and extensions around the core. Memory, retrieval,
and prompt systems plug in through one governed context pipeline in the
[vision](docs/vision.md#concept-vision-model-boundary), with its exact contract
in the [technical companion](docs/vision-technical.md#technical-vision-model-boundary),
without entering the kernel.

## The Shape

- **Four layers:** a versioned protocol, a pure session core, an OTP session
  runtime, and replaceable edges (model adapters, stores, executors,
  transports, clients). The core application depends on the Elixir/Erlang
  standard runtime only.
- **Durable sessions:** a private recovery journal plus a small stable
  public-event vocabulary, snapshots, and transient progress — distinct
  planes with distinct guarantees. Restart replays; clients reconnect from
  cursors.
- **Honest effects:** every model call and tool job is a durable operation
  with attempts, epochs, fencing, receipts, and reconciliation.
- **Brains and hands:** tool execution is placement-transparent — local
  process, isolated container/microVM, or trusted remote worker — behind one
  job/receipt protocol. Distribution connects trusted gateways only; the
  sandbox is the OS boundary, never the BEAM.
- **Governed live extensions:** trusted OTP applications activate as
  quiescent generations with tested migration and exact rollback — code
  evolves, session history survives.
- **A seven-tool coding surface** (`read write edit bash grep find ls`)
  inside a system prompt budgeted under 1,000 tokens.

## Honest Posture

Loopex is a personal project, developed in the open, by the same author as
[Allbert Assist](https://github.com/lexlapax/allbert-assist/) — whose
operating lessons shaped this design and one of whose future roles may be
hosting Loopex. It is an independent, clean-room implementation: design
lessons are credited in the vision's sources; no code is ported from any
harness.

What the open development does not include:

- **No support promises.** Issues are read when there is time; no reply, fix,
  or timeline is owed.
- **The roadmap follows the maintainer's use,** not a backlog. Requests are
  interesting to read but create no obligations.
- **No stability promises in 0.x.** Public surfaces are labeled stable,
  release-candidate, or experimental, and the labels are honest — but 0.x
  minors may break experimental APIs with migration notes.

None of that is discouragement; it is the accurate shape of the project. The
code is Apache-2.0, so the permission to use, fork, and embed it is real
regardless of what can be promised about support.

## Roadmap

[The roadmap](docs/roadmap.md#concept) gives the candidate capability sequence and why
the ordering matters. Its [technical companion](docs/roadmap-technical.md#technical-depth)
holds the exact prerequisite and evidence projection. Each accepted milestone
maps its bounded outcomes back to those capabilities.

The roadmap is guidance. The commitment is an accepted plan.

## Start Here

- [DEVELOPMENT.md](DEVELOPMENT.md) — current bootstrap prerequisites and the
  provider-neutral local validation command.
- [docs/](docs/) — documentation index, including every active Concept and
  Technical depth pair.
- [docs/developer/development-charter.md](docs/developer/development-charter.md#concept)
  and its [technical companion](docs/developer/development-charter-technical.md#technical-depth)
  — clarity, traceability, and development form.
- [docs/vision.md](docs/vision.md#concept) and
  [docs/vision-technical.md](docs/vision-technical.md#technical-depth) — the paired founding
  vision and architecture; everything else derives from them.
- [docs/roadmap.md](docs/roadmap.md#concept) and
  [docs/roadmap-technical.md](docs/roadmap-technical.md#technical-depth) — candidate capability
  sequencing and exact evidence projection. Non-normative guidance.
- [AGENTS.md](AGENTS.md) — the repository's tool-neutral development contract.
- [docs/developer/agent-context-map.md](docs/developer/agent-context-map.md)
  — routing map by area.
- `docs/adr/` — architectural decisions, as they land.
- [docs/plans/](docs/plans/) — canonical milestone status plus accepted, active,
  and closed paired-plan/gate records.
- [CHANGELOG.md](CHANGELOG.md) — what changed, per milestone.

## License

Loopex is licensed under the [Apache License, Version 2.0](LICENSE).
Copyright 2026 Sandeep Puri.

Apache-2.0 matches the license of the stack Loopex is built on — Elixir and
Erlang/OTP are both Apache-2.0 — and gives you an explicit patent grant
alongside explicit "AS IS", no-warranty terms that match the no-promises
posture above. If you contribute, your contribution is licensed under the
same terms — that is Apache-2.0 §5, and there is no separate CLA.
