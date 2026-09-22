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

**Revision status:** Closed milestone product baseline; active milestone `M5` is accepted; next candidate `M6` is open.

[Canonical milestone status and plan records](docs/plans/)
<!-- loopex:readme-status:end -->

M0 through M4 are closed and integrated. The capsule above, derived from the
canonical register, carries the current M5 state. M1 delivered the durability kernel:
an explicit embedded runtime, durable local Store, canonical model boundary, trusted-local
executor, thin reference client, durable events, and receipt reconciliation
across a real runtime-process crash. What it deliberately did not deliver is a
usable coding loop — that loop ran a fixed two turns, carried no conversation
history, and exposed two demonstration tools, so the only way to drive it was a
test selector.

M2 made that loop a command:
`loopex` submits a prompt into a durable session, the answer streams as it is
produced, the loop runs as many turns as the task needs while the model sees the
whole conversation and the real output of every tool it ran, four coding tools
act on a real workspace under a host policy that can refuse, a repository's own
behaviour-shaping files reach the model only by an explicit decision taken at
the terminal, and yesterday's session can be found and continued. Those bytes
are part of the closed product baseline; the marked status capsule above and
the canonical plan register carry the milestone state.

Loopex remains source-tree milestone work, not an installable package or frozen
public API. The annotated tag `v0.0.0-m2` identifies the exact integrated M2
source snapshot only. Start with the
[coding sessions guide](docs/operator/coding-sessions.md#concept) for the `loopex`
command, or the [operator runtime guide](docs/operator/runtime.md#concept) for the
embedded runtime beneath it and run the complete source-tree loop, or use the
[developer embedding guide](docs/developer/runtime-and-embedding.md#concept) to
understand the composition and commit ordering.

The integrated post-closure repair line implements the accepted follow-up decisions for a
private provider process, explicit local recovery handoff, versioned provider
accounting, and bounded executor receipts. The
[source qualification](docs/evidence/M2-ff17990-review-followup.md#final-repaired-source-06dadbb)
and [integration disposition](docs/evidence/M2-recorded-limitations.md#final-repaired-source-integration)
name the evidence and authority used for integration. Those repairs do not
publish a package or label a public surface.

M3 delivered pinned Git skill installation, project-only discovery,
explicit manifest admission, and operator-selected instructions and supporting
files in model context. Skills use the existing tool, policy and artifact paths;
downloaded scripts and metadata grant no permissions. Fresh-process CLI recovery
uses the exact retained skill snapshot with its configured provider and executor.
Core repairs keep required context ahead of optional content, let acknowledgements
continue while Store reads wait, and retire settled provider permits safely. See
[project skills](docs/operator/coding-sessions.md#operator-sessions-skills) for
the commands and [embedding resources](docs/developer/runtime-and-embedding.md#technical-embedding-resources)
for the host API. The exact M3 product source
`f45354572840636b473ad7e40e42355fdff4fc17` passed M3-only qualification
on the macOS floor pair and Linux; the [M3 plan](docs/plans/M3.md#concept-m3-final-qualification-f453545)
records that evidence and the separate lifecycle decision.

M4 is closed. Its plan pair and its five prerequisite ADRs (0023, 0024, 0026,
0028 and 0030) are accepted, the development floor is refreshed to Elixir
1.18.5 with OTP 27.3.4, and its work is integrated on `main`. The runs that
qualified the closure candidate are retained in
[M4 closure runs](docs/evidence/M4-closure-runs.md).

What M4 delivers is an operator-usable foreground server and an independent
consumer over durable interactions and bounded artifact transfers, with runtime
tracing and telemetry. Two applications join the eight: `loopex_telemetry` at
the edge, owning the only Loopex-attached telemetry handler, and
`loopex_app_server` as a client, serving the experimental session protocol over
one foreground process on standard input and output. Core admits one external
dependency, the telemetry event dispatcher the dependency doctrine names. A
host policy can now answer a tool decision with a bounded question instead of a
verdict; the runtime keeps that question as durable session state, so an
operator can still answer it after the server process is gone, and the answer is
evidence for a new host decision rather than an authorization. A caller holding
an artifact reference can read it back in verified bounded chunks instead of
fetching all of it.

The independent consumer lives in [`clients/node`](clients/node/README.md)
as plain JavaScript the pinned Node runs directly, with no build step, package
manifest, lockfile or dependency; it drives a session end to end over the wire,
selecting an admitted skill, answering the host policy's question, watching the
authorization the host mints afterwards, and reading back a verified bounded
transfer of what the tool produced.

M4 also moved the source `VERSION` from `0.0.0` to `0.1.0`. That is a source
version and nothing more: accepted
[ADR 0023](docs/adr/0023-experimental-public-session-protocol.md#concept) keeps
it independent of the negotiated protocol generation, and it is not a tag, a
package, a publication or a compatibility freeze. The source-only `v0.1.0` tag
**has been applied** to M4's exact `main` integration commit under the
maintainer's separate release decision; it publishes no package, installer or
service unit and freezes no surface. See the
[M4 plan](docs/plans/M4.md#concept) for the accepted scope and its workstreams,
[App server operations](docs/operator/app-server.md#concept) for driving it,
and the [canonical register](docs/plans/README.md) for its current status.

Since closure, `Loopex.AppServer.Host.serve/0` and the shipped `ask` and
`allow-all` host policies replaced the test-tree fixture the operator guide
used to name, `LoopexComposition` can wire bounded artifact transfers with
`artifact_transfers: true`, and the local executor's launch guard writes each
control frame as one line and one write. [CHANGELOG.md](CHANGELOG.md) records
the detail.

The repaired reference local executor requires `/bin/bash` for its internal
supervision on Darwin and Linux; raw commands still use `/bin/sh`. See the
[runtime prerequisite](docs/operator/tools-and-policy.md#operator-local-supervision-shell)
before using the reference stack. Core and custom executors are unaffected.

### M5 Durable Service

`M5` defines the durable-service rung: a local daemon
that owns session lifetime for a state root, so sessions keep running while no
client is connected; several independent client processes reaching one session
over a Unix-domain socket; one of them driving while the others watch, with an
explicit takeover when the driver dies; and all of it on the existing local
store adapter within that adapter's documented limits. Read the
[M5 plan](docs/plans/M5.md#concept) and its
[technical companion](docs/plans/M5-technical.md#technical-depth) for the
purpose, outcomes and how each one is to be proved.

The four prerequisite decision records are ADRs
[0031](docs/adr/0031-daemon-grade-store-selection-and-migration.md#concept),
[0032](docs/adr/0032-daemon-attachment-residency-and-replay.md#concept),
[0033](docs/adr/0033-collaboration-controller-lease-and-takeover.md#concept)
and [0034](docs/adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept).
The status capsule above and the
[canonical register](docs/plans/README.md)
carry the milestone and decision state; this paragraph only says what the work
is for.

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
  inside a system prompt budgeted under 1,000 tokens; M2 ships the first four
  and measures them, and the rest follow the measurement.

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
- [CHANGELOG.md](CHANGELOG.md) — what changed, per milestone.

## License

Loopex is licensed under the [Apache License, Version 2.0](LICENSE).
Copyright 2026 Sandeep Puri.

Apache-2.0 matches the license of the stack Loopex is built on — Elixir and
Erlang/OTP are both Apache-2.0 — and gives you an explicit patent grant
alongside explicit "AS IS", no-warranty terms that match the no-promises
posture above. If you contribute, your contribution is licensed under the
same terms — that is Apache-2.0 §5, and there is no separate CLA.
