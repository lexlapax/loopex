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

**Revision status:** Closed milestone product baseline; active milestone `M5` is in progress; no next candidate is recorded.

[Canonical milestone status and plan records](docs/plans/)
<!-- loopex:readme-status:end -->

## What Loopex Provides

At source version `0.2.0`, Loopex is a working single-machine coding harness
and the runtime underneath it. It runs from a source checkout on macOS and
Linux. It is not yet a published package, and its client protocol is
experimental. [CHANGELOG.md](CHANGELOG.md) records how each capability arrived.

- **A durable session runtime you can embed.** An Elixir host starts an
  explicit runtime and owns its sessions. Each session has one serial owner and
  an append-only journal in a local store. Intent is recorded before any effect
  and facts before any publication, so a session survives a crash of its
  process and replays on restart. A lost effect is reported as
  `outcome_unknown` and reconciled, never blindly retried. See the
  [embedding guide](docs/developer/runtime-and-embedding.md#concept).
- **A coding loop at the terminal.** The `loopex` command runs a prompt as a
  durable, multi-turn session and streams the answer as it is produced. The
  model sees the whole conversation and the real output of every tool it ran.
  Four coding tools (`read`, `write`, `edit`, `bash`) act on a real workspace
  under a host policy that can allow or refuse each call. Earlier sessions can be
  listed and resumed. See [coding sessions](docs/operator/coding-sessions.md#concept).
- **Governed model context.** A repository's instruction files and pinned Git
  skills reach the model only after an explicit admission decision. They are
  budgeted, provenance-typed data and never a grant of authority. Downloaded
  skill files carry no permissions.
- **A provider boundary that keeps the credential out of the session.** Model
  calls go through a provider-neutral boundary. The reference adapter runs the
  provider in a private companion process that receives the credential over a
  bootstrap channel. Credentials never enter journals, events, progress or
  diagnostics.
- **Honest tool execution.** Every tool job is a durable operation with
  attempts, fencing tokens and receipts. The trusted local executor supervises
  each command's process group and reports exactly what it could confirm.
- **Durable questions and bounded artifacts.** A host policy, such as the app
  server's `ask` stance, can answer a tool request with a question instead of a
  verdict. The question stays as durable
  session state, so it can be answered after the asking process is gone.
  Clients read tool output back in verified, bounded chunks.
- **Session protocols and an independent client.** A foreground app server
  speaks the experimental session protocol `loopex.experimental/1` over standard
  input and output, and the daemon speaks `loopex.experimental/2` over its
  socket. A dependency-free [Node client](clients/node/README.md) drives
  sessions end to end over both. See [app server operations](docs/operator/app-server.md#concept).
- **A local daemon that outlives its clients.** `loopex daemon` owns every
  session for one state root and keeps them running while no client is
  connected. Several client processes reach it over a same-user Unix socket.
  One client drives a session under a controller lease while others observe,
  and a client can explicitly take over when the driver is lost. An orderly
  stop drains work and reports what it stopped; a failure ends with a named
  exit status. See the [daemon guide](docs/operator/daemon.md#concept).
- **Observability without source changes.** A host can start a runtime-scoped
  trace session and read telemetry spans that are bounded and redacted. See
  [observability](docs/operator/observability.md#concept).

**Where to start:** the [operator getting-started guide](docs/operator/getting-started.md)
takes you from a checkout to a first session. The
[developer getting-started guide](docs/developer/getting-started.md#concept)
covers building on Loopex and contributing to it.

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
  inside a system prompt budgeted under 1,000 tokens. The first four ship
  today; the rest follow measurement of those.

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

## How Work Is Checked

Two commands, both run from the repository root and described in
[DEVELOPMENT.md](DEVELOPMENT.md):

```bash
bash scripts/check.sh            # the fast check, credential-free
LOOPEX_PROVIDER_API_KEY=... bash scripts/check-release.sh
```

`scripts/check.sh` runs warning-free compilation, formatting, the repository
structure checks, documentation ordering, the dependency budget, one version
across the applications, and the credential-free suite with one application per
VM. It runs once per integration candidate. `scripts/check-release.sh` is the
slow one: the real-provider workflows, the independent Node client, the
fresh-source archive build and the long-duration bound proofs; it needs a
provider credential and the pinned Node, and runs once before closure. An
unchanged-source release reuses that evidence and runs only its pre-tag
administrative-SHA proofs.

Hosted CI — `.github/workflows/agent-bootstrap.yml` — runs
`bash scripts/check.sh --select` on every push to `main` and every pull
request, on the current toolchain pair. It is a replaceable runner of the
repository's own command, not a second definition of the check. Nothing merges
to `main` without a green CI run on the candidate and an independent review of
its diff.

The [verification guide](docs/developer/verification.md#concept) and its
[technical companion](docs/developer/verification-technical.md#technical-depth)
are the rule book: three stages, how a changed boundary selects its checks, and
what keeps them honest. The [milestone guide](docs/developer/milestones.md#concept)
and its [technical companion](docs/developer/milestones-technical.md#technical-depth)
are how a milestone is planned, run and closed. There are no per-milestone gate
runners; the gate files under `docs/plans/` are historical records.

## Roadmap

[The roadmap](docs/roadmap.md#concept) gives the candidate capability sequence and why
the ordering matters. Its [technical companion](docs/roadmap-technical.md#technical-depth)
holds the exact prerequisite and evidence projection. Each accepted milestone
maps its bounded outcomes back to those capabilities.

The roadmap is guidance. The commitment is an accepted plan.

## Start Here

- [Operator getting started](docs/operator/getting-started.md) — from a
  source checkout to a first coding session, a daemon and a clean stop.
- [Developer getting started](docs/developer/getting-started.md#concept) — building on
  Loopex (embedding, the session protocol) and contributing to it.
- [DEVELOPMENT.md](DEVELOPMENT.md) — current bootstrap prerequisites and the
  two check commands.
- [docs/developer/verification.md](docs/developer/verification.md#concept) and
  its [technical companion](docs/developer/verification-technical.md#technical-depth)
  — the rule book for checking work: stages, selection, and the honesty rules.
- [docs/developer/milestones.md](docs/developer/milestones.md#concept) and its
  [technical companion](docs/developer/milestones-technical.md#technical-depth)
  — how a milestone is planned, run, closed and released.
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
- [docs/plans/](docs/plans/) — canonical milestone status plus the accepted,
  active, and closed plan pairs, and the historical gate records beside them.
- [CHANGELOG.md](CHANGELOG.md) — what changed in each release and milestone.

## License

Loopex is licensed under the [Apache License, Version 2.0](LICENSE).
Copyright 2026 Sandeep Puri.

Apache-2.0 matches the license of the stack Loopex is built on — Elixir and
Erlang/OTP are both Apache-2.0 — and gives you an explicit patent grant
alongside explicit "AS IS", no-warranty terms that match the no-promises
posture above. If you contribute, your contribution is licensed under the
same terms — that is Apache-2.0 §5, and there is no separate CLA.
