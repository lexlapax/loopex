# Roadmap

**Status: non-normative sequencing guidance.** This file derives from
[docs/vision.md](vision.md) §20–§24 and §27. It exists so milestone plans and
ADRs can be written in a sensible order; it is not authority. It creates no
scope, authorizes no work, and cannot resequence a serial barrier or weaken an
invariant. When it conflicts with the vision, an accepted ADR, or an accepted
plan, those win and this file is wrong.

The commitments live in `docs/plans/` (one accepted plan per stage) and
`docs/adr/`. Version numbers, milestone contents, and ordering below the serial
barriers are all revisable; a plan may split, resequence, or omit anything here.
Dates and staffing are deliberately absent — plans own those
([vision §21.1](vision.md)).

## How a Milestone Runs

1. The maintainer explicitly opens the stage. Nothing before that point
   authorizes product implementation
   ([AGENTS.md](../AGENTS.md) § Milestones and Gates).
2. `gate` skill: plan candidate under `docs/plans/` plus a branch-only
   executable acceptance gate that is red for the declared missing behavior
   while every existing check stays green. The red tree never reaches `main`.
3. The maintainer accepts plan and gate. Acceptance locks exact commands,
   protected tests, fixtures, evidence classes, and their digest.
4. Implementation runs inside that envelope; ADR-class questions surface as
   Propose-and-pause packets, not silent choices.
5. `close-milestone` skill assembles a closure candidate from exact-SHA gates,
   retained evidence, and independent review. Only the maintainer closes it.
6. At closeout, working notes move out of the context map's § Version-Specific
   Guidance and this file's ladder is updated to match what actually shipped.

Current stage state is never stored here — read
[docs/developer/agent-context-map.md](developer/agent-context-map.md)
§ Version-Specific Guidance.

### Where the Files Go

Maintainer decision, 2026-08-15, revised the same day after review. Two flat
files per milestone under `docs/plans/`:

```text
docs/plans/<name>.md         the plan: purpose, scope, outcomes table, state
docs/plans/<name>-gate.md    the locked acceptance contract
```

`<name>` is the milestone name — `M0`, `v0.1`, `v1.0`. The gate is separate
because its bytes are digested at acceptance, and a plan's progress notes change
constantly; sharing one file would churn the digest until it meant nothing.

There is no separate evidence file. Evidence goes in the plan's outcomes table
as links, and earns its own file only if it genuinely outgrows that.

Design and flow documents are **not** plan artifacts. They are living
architecture: they outlive the milestone that introduced them and are corrected
as code changes. They live in `docs/architecture/` (for example
`docs/architecture/user-request-flow.md`) and plans link to them. Keeping them
out of `docs/plans/` is what lets an accepted plan stay an immutable record
while the diagram stays true.

ADRs stay flat and numbered in `docs/adr/NNNN-short-title.md`, per the `adr`
skill — decisions are not milestone-scoped.

[docs/plans/README.md](plans/README.md) is the human entry point: the vocabulary,
the gate lifecycle, and every milestone with its current state.

## The Ladder

Each rung answers one constitutional question from
[vision §21](vision.md). "Proves" is the headline outcome a plan would have to
turn into bounded scope and evidence.

| Milestone | Ships | Constitutional question | Proves | Freezes |
| --- | --- | --- | --- | --- |
| **M0** — contract experiments | No | Are session durability, effect truth, and VM-global trusted-code evolution feasible under the stated OTP semantics? | Journal write/replay, `commit_unknown` fencing and reconciliation across a restart, one extension activation plus exact A→B→A rollback, one real-provider slice. Disposable code. | Nothing, by construction. |
| **v0.1** — useful local kernel | Yes | Can one developer use a small, durable, truthful coding loop through the embedded API and reference client? | The full loop: seven tools, durable sessions, embedded API, JSONL RPC, line-oriented terminal client, restart+replay continuity. | Nothing public; surfaces are experimental. |
| **v0.2** — durable service | Yes | Can independent clients attach, recover, and agree on one protocol candidate without owning session lifetime? | Reference daemon, race-free multi-client attachment, snapshots and cursors, the ADR-selected durable store, public protocol as release candidate. | Protocol RC (schemas + conformance, no support promise). |
| **v0.3** — governed extension runtime | Yes | Can trusted behavior evolve without changing session truth, weakening authority, or pretending code is runtime-local? | Extension manifest and namespaces, quiescent versioned activation, extension state upgrade/downgrade fixtures, exact rollback. | Extension contribution API as RC. |
| **v0.4** — isolated hands | Yes | Can generated and less-trusted work execute outside the brain through the same effects contract? | Executor gateway to an OS-isolated hand, generated-code promotion path, executor conformance suite passing local and isolated. | Executor protocol for local + isolated transports. |
| **v0.5** — remote ecosystem | Yes | Can the contract span workers and materially different hosts without becoming a fleet or policy platform? | Executor broker, trusted-gateway distribution, ACP adapter, secured sample host, remote-worker reconciliation evidence. | Executor protocol for the claimed remote transport; ACP mapping. |
| **v1.0** — compatibility baseline | Yes | Are public contracts proven by independent consumers, migrations, rollback, and packaged operation? | Materially different consumers, migration and rollback fixtures, exact packaged artifacts and install smoke, public protocol v1 decision. | Public protocol v1 and the surfaces whose freeze criteria passed. |

M0 is the only rung that ships nothing, which is why it is the only M-named
milestone. Every other milestone is named for the release it produces, so the
name alone tells you whether work there reaches users.

Compatibility surfaces do not freeze together
([vision §24.1](vision.md)): private journal schema, public protocol, executor
protocol, extension API, embedded Elixir API, and artifact formats each freeze
on their own evidence. A milestone that stabilizes one says nothing about the
rest.

## The Only Hard Ordering

Everything above can be resequenced by an accepted plan except the rejoin order
in [vision §22](vision.md):

```text
durable local session and operation truth
-> multi-client attachment and protocol candidate
-> extension namespaces plus VM-global activation proof
-> public protocol compatibility decision
-> isolated-hand conformance
-> remote-worker and multi-host compatibility evidence
```

Restated as the four barriers a plan may not cross: durable local truth before
multi-client protocol; extension namespaces and activation evidence before
public-protocol freeze; isolated-hand conformance before remote workers;
materially different consumer evidence before 1.0. Restart plus replay is the
continuity mechanism until release hot upgrades get separate proof.

## ADR Agenda by Milestone

The agenda comes from [vision §20.4](vision.md) and the decision triggers in
[vision §27](vision.md). "Before" names the earliest milestone that cannot
honestly proceed without the decision. Use the `adr` skill; an ADR is for a
decision among valid designs, never for logging a reversible choice.

| Decision | Before | Why it blocks |
| --- | --- | --- |
| Repository and application layout | M0 gate | Dependency-direction enforcement needs a real tree. Rider: `.claude/hooks/deps-budget.sh` hardcodes `apps/loopex/mix.exs` and is silently inert under any other layout — the layout change must fix that hook in the same commit. |
| Runtime floor (OTP 26+ / Elixir 1.17+) | M0 gate | Validates the exact code-loading, terminal, disposable-node, dependency, and platform requirements, and defines what the version matrix must cover. Open question: does the floor survive that evidence? |
| Runtime instances and VM-global code ownership | M0 | The code manager is the one deliberate VM-global exception; its ownership must be settled before any activation experiment. |
| Three durable transaction domains | M0 | VM-code, runtime-control, and session truth have different identity, durability, and replay semantics. |
| Operation kinds and terminal semantics | M0 | Attempt protocols, the closed outcome algebra, and reconciliation identity are what M0 exists to test. |
| Tool, executor, and grant contracts | v0.1 | The loop cannot dispatch effects before the job/receipt/grant shape exists. |
| Provider continuation and exact context staging | v0.1 | A model call dispatches only the exact canonical context committed with its intent; the sidecar's retention/encryption policy gates any persisted real-provider path. |
| Context pipeline contracts | v0.1 | The sole seam for memory, retrieval, and prompts. Includes the deterministic-lexical-first recall posture and the inline-bytes-versus-artifact-reference line. |
| Store selection and migrations | v0.2 | A durable service makes operational and compatibility claims; in-memory plus an experimental private local adapter carries v0.1 only. |
| Public schemas and attachment delivery | v0.2 | Command/event envelopes, snapshot-first attach, and the exact JSON Schema subset must exist before protocol fixtures become release candidates. |
| Extension activation and rollback | v0.3 | Quiescence, atomic module-set loading, and exact A→B→A rollback are the milestone. |
| Isolated-hand threat model and sandbox backend | v0.4 | Nothing may claim an OS isolation boundary before the backend is chosen and reviewed. |
| Remote-hand threat model and transport | v0.5 | Distribution connects trusted gateways only; the primary non-BEAM transport gates any remote compatibility claim. |
| ACP mapping and protocol-v1 criteria | v0.5 → 1.0 | ACP mapping precedes the v1 freeze decision by founding decision 18. |
| Compatibility and deprecation policy | 1.0 | Additive-field rules, unknown-value handling, deprecation window, supported upgrade span. |

## Evidence Expectations

Claim-proportional, per [vision §23](vision.md) and
[AGENTS.md](../AGENTS.md) § Milestones and Gates:

- **Reducers and replay** — property tests, always.
- **Every replaceable boundary** — reusable conformance suites (store, model,
  executor, extension, transport), from the milestone that introduces it.
- **Durable transitions** — process and store fault injection; a durability
  claim without it is not evidence.
- **Protocols** — golden vectors and reader/writer compatibility.
- **Trust boundaries** — negative tests plus security review.
- **Real paths** — a tagged, explicitly invoked lane. Fakes support automated
  tests; they never substitute for required real-provider, store, isolation, or
  package evidence.
- **Performance** — measure before budgeting ([vision §23.5](vision.md)); no
  BEAM-scale promises before recorded baselines.
- **Releases** — exact artifact digests, install smoke, migration and rollback
  procedure ([vision §24.3](vision.md)–§24.4).

Minimalism budgets ([vision §23.4](vision.md)) are tests, not slogans: the
seven-tool surface, the sub-1,000-token reference prompt, the zero-external-
dependency core, and "one page starts a runtime and consumes events" each need
an executing check by the milestone that makes them true.

## Open Questions Not Yet Owned by a Milestone

These have triggers rather than positions
([vision §27](vision.md)); listing them here does not schedule them:

- Name, trademark, domain, and Hex clearance — before public packages or
  branding.
- Reference terminal richness and the default active-tool profile — after
  prompt-cost and task-utility evidence.
- Whether a reference memory extension lives in-repo or in the ecosystem.
- Whether an always-in-context pinned memory tier is core-supported or
  extension-simulated — before protocol v1 freeze.
- Whether an official hands container/microVM image is a released artifact.
- Which future host first validates the security-rich embedding seam.
- What evidence would justify splitting an application or Hex package — no
  default split.

## What This File Is Not

It is not a backlog, a commitment, a release schedule, or a source of
authority. It does not authorize implementation, name dates, freeze version
numbers, or record current progress. Keep it short; when a milestone closes,
correct the ladder to match reality rather than growing a history section —
git holds the history.
