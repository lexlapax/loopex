# Loopex

**The loop, in Elixir.**

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

## Where Things Stand

- **Now** — Pre-implementation. No product code exists; nothing is installable.
- **In flight** — [ADR 0001](docs/adr/0001-repository-and-application-layout.md)
  (repository layout) and
  [ADR 0002](docs/adr/0002-bootstrap-runtime-floor.md) (runtime floor) are
  proposed, awaiting acceptance.
- **Next** — Open the M0 gate: a bounded set of contract experiments, disposable,
  freezing nothing.
- **Last closed** — Seed bootstrap, 2026-08-15.

**[What's committed and how you tell it's done →](docs/plans/)** ·
[the map](docs/roadmap.md) · [what changed](CHANGELOG.md)

The founding vision — [docs/vision.md](docs/vision.md) — is complete and
decision-bearing: boundaries, invariants, protocol planes, trust model, and
delivery shape are settled there. This section will keep changing; the shape
below should not, much.

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

## What It Is — and Is Not

The same runtime should support a reference CLI, an IDE agent over the Agent
Client Protocol, CI/headless harnesses, a security-rich personal assistant
host, a team coding service, and remote executor fleets — all over one
semantic contract.

It is deliberately **not** a generic agent framework, a workflow engine, an
identity or policy product, a memory product or RAG framework, a
social-channel hub, a marketplace, or a sandbox-by-supervision-tree. Those
belong to hosts, adapters, and extensions around the core. Memory, retrieval,
and prompt systems plug in through one governed context pipeline
([docs/vision.md](docs/vision.md) §13.5) without entering the kernel.

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

## Roadmap (suggested shape)

| Milestone | Proves |
| --- | --- |
| M0 | Bounded contract experiments: durability/replay, operation truth across a restart, extension activation/rollback, one real provider slice. Disposable; freezes nothing. |
| v0.1 | A useful local coding harness: full loop, seven tools, durable sessions, JSONL RPC, terminal client. |
| v0.2 | A durable service: daemon, multi-client attach, snapshots/cursors, the ADR-selected daemon store, protocol release candidate. |
| v0.3 | Governed extensions and live reload, with exact rollback proof. |
| v0.4 | Isolated hands and generated-code trials behind the executor gateway. |
| v0.5 | Remote hands and ecosystem beta: broker, trusted gateways, ACP adapter, sample hosts. |
| 1.0 | A compatibility baseline: independent consumers, migrations, rollback, packaged operation. |

[docs/roadmap.md](docs/roadmap.md) carries the fuller shape — what each rung
proves, which ADRs precede it, and the serial barriers that cannot be
resequenced. It is guidance; the delivery commitment is
[docs/vision.md](docs/vision.md) §21 turned into accepted per-milestone plans
in `docs/plans/`.

## Start Here

- [DEVELOPMENT.md](DEVELOPMENT.md) — current bootstrap prerequisites and the
  provider-neutral local validation command.
- [docs/vision.md](docs/vision.md) — the founding vision and architecture;
  everything else derives from it.
- [docs/roadmap.md](docs/roadmap.md) — milestone sequencing, ADR agenda, and
  serial barriers. Non-normative guidance.
- [AGENTS.md](AGENTS.md) — repository rules for coding agents and
  agent-assisted work.
- [docs/developer/agent-context-map.md](docs/developer/agent-context-map.md)
  — routing map by area.
- `docs/adr/` — architectural decisions, as they land.
- `docs/plans/` — the active milestone plan.
- [CHANGELOG.md](CHANGELOG.md) — what changed, per milestone.

## License

Loopex is licensed under the [Apache License, Version 2.0](LICENSE).
Copyright 2026 Sandeep Puri.

Apache-2.0 matches the license of the stack Loopex is built on — Elixir and
Erlang/OTP are both Apache-2.0 — and gives you an explicit patent grant
alongside explicit "AS IS", no-warranty terms that match the no-promises
posture above. If you contribute, your contribution is licensed under the
same terms — that is Apache-2.0 §5, and there is no separate CLA.
