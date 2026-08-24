# Roadmap

<a id="concept"></a>
## Concept

Technical depth: [Roadmap technical depth](roadmap-technical.md#technical-depth)

**Status: non-normative capability guidance.** This roadmap projects the
founding vision into a readable sequence of questions. It does not authorize
work, create a release commitment, weaken an invariant, or replace an accepted
plan. Canonical milestone status lives in
[docs/plans/README.md](plans/README.md).

The sequence begins with durable local truth and becomes broader only as
evidence supports it. Candidate labels are navigation aids. An accepted plan
may split, combine, rename, resequence, or omit projected work beneath the
vision’s enduring barriers.

Authority details: [Roadmap boundary and derivation](roadmap-technical.md#technical-roadmap-boundary)

<a id="concept-roadmap-ladder"></a>
### Capability ladder

Each rung asks a product question rather than promising a milestone or version.
A rung may take more than one milestone to answer, and the milestone names below
are navigation aids for the current projection rather than commitments.
Compatibility surfaces remain independent and freeze only when their own
evidence is accepted.

Technical depth: [Candidate proofs and possible freezes](roadmap-technical.md#technical-roadmap-ladder)

<a id="concept-roadmap-m0"></a>
#### Contract experiments — M0 candidate

Can Loopex prove the feasibility of durable session truth, honest effect
recovery, and VM-global trusted-code evolution under the intended OTP
semantics? This candidate freezes no product surface.

Technical depth: [M0 candidate proof boundaries](roadmap-technical.md#technical-roadmap-m0)

<a id="concept-roadmap-useful-local-kernel"></a>
#### Useful local kernel — v0.1 candidate

Can a developer use a small, durable, truthful coding loop through the
embedded API and reference client? Two milestones answer it: the foreground
harness a developer drives from a terminal, then the headless boundary another
program drives with the same semantics. It builds on the durable single-machine
session and effect truth M1 delivered. Its surfaces remain experimental
throughout, and the projected `0.1.0` tag sits at the end of the second
milestone rather than the first.

Technical depth: [Useful-local-kernel candidate proof](roadmap-technical.md#technical-roadmap-useful-local-kernel)

<a id="concept-roadmap-foreground-harness"></a>
##### Foreground coding harness — M2 candidate

Can an operator do real work in their own terminal against a durable session?
The projected shape is a genuine multi-turn loop over committed conversation
history, real tool results returned to the model, a four-tool bootstrap coding
profile, host policy that can refuse a call, truthful same-process cancellation,
streaming progress, session discovery and resume, a one-page embedded
composition, and a runnable `loopex` command. It publishes nothing and freezes
nothing.

Technical depth: [Foreground-harness candidate proof](roadmap-technical.md#technical-roadmap-foreground-harness)

<a id="concept-roadmap-session-protocol"></a>
##### Headless session protocol — M3 candidate

Can a separate program drive the same session semantics over a language-neutral
boundary? The projected shape is a long-lived stdio JSONL contract with an exact
versioned schema bundle, golden vectors, capability negotiation, command
admission separated from asynchronous completion, and sample clients. The vision
names this transport before the reference daemon, so a daemon inherits a
boundary already proved against a real loop instead of defining one.

Technical depth: [Session-protocol candidate proof](roadmap-technical.md#technical-roadmap-session-protocol)

<a id="concept-roadmap-durable-service"></a>
#### Durable service — v0.2 candidate

Can independent clients attach, recover, and agree on one protocol candidate
without owning session lifetime? M4 carries this rung: daemon-owned session
lifetime, a local socket transport, concurrent independent clients,
collaboration with crash takeover, snapshot and cursor replay, residency limits,
a daemon-grade store, and cancellation that crosses processes. The protocol
still remains experimental.

Technical depth: [Durable-service candidate proof](roadmap-technical.md#technical-roadmap-durable-service)

<a id="concept-roadmap-governed-extension-runtime"></a>
#### Governed extension runtime — v0.3 candidate

Can reviewed and promoted trusted behavior evolve without changing session
truth, weakening authority, or pretending executable code is runtime-local?
Public protocol and extension contribution surfaces can become release
candidates only through a separate accepted decision after the proof.

Technical depth: [Governed-extension candidate proof](roadmap-technical.md#technical-roadmap-governed-extension-runtime)

<a id="concept-roadmap-isolated-hands"></a>
#### Isolated hands — v0.4 candidate

Can generated and less-trusted work execute outside the brain through the same
effect contract? Only proven local and isolated transports can support an
executor-protocol claim.

Technical depth: [Isolated-hands candidate proof](roadmap-technical.md#technical-roadmap-isolated-hands)

<a id="concept-roadmap-remote-ecosystem"></a>
#### Remote ecosystem — v0.5 candidate

Can the same contract span workers and materially different hosts without
turning Loopex into a fleet or policy platform? Only proven mappings and remote
transports can support compatibility claims.

Technical depth: [Remote-ecosystem candidate proof](roadmap-technical.md#technical-roadmap-remote-ecosystem)

<a id="concept-roadmap-compatibility-baseline"></a>
#### Compatibility baseline — 1.0 candidate

Are the public surfaces supported by independent consumers, migrations,
rollback, exact packages, and install proof? Only individually proven surfaces
freeze.

Technical depth: [Compatibility-baseline candidate proof](roadmap-technical.md#technical-roadmap-compatibility-baseline)

<a id="concept-roadmap-rejoin-order"></a>
### Enduring rejoin order

This roadmap does not define or paraphrase the normative order. Its Technical
depth carries the checked verbatim sequence from the founding vision.

Technical depth: [Checked verbatim rejoin copy](roadmap-technical.md#technical-roadmap-rejoin-order)

Plans may rearrange work below those barriers, never pass through them without
the decision required to amend the vision.

<a id="concept-roadmap-adr-agenda"></a>
### Decision agenda

Decisions are made when their capability first depends on them, not merely to
record implementation activity. The early agenda covers repository layout and
runtime floor, then runtime/code ownership, transaction domains, and operation
outcomes; the tool, effect, context, and session-input contracts a foreground
harness dispatches through; the schema, negotiation, and interaction-identity
contracts a headless protocol publishes; durable storage, attachment, and
collaboration for a daemon; then extension rollback, isolated and remote threat
models, ACP mapping, and compatibility policy.

Technical depth: [Decision-by-capability blocking matrix](roadmap-technical.md#technical-roadmap-adr-agenda)

<a id="concept-roadmap-evidence"></a>
### Evidence expectations

Evidence grows with the claim: properties for reducers, conformance at
replaceable boundaries, fault injection for durable transitions, vectors for
protocols, negative tests for trust, and real-path or exact-package proof when
those paths are claimed. Each accepted plan selects and locks its exact
evidence.

Technical depth: [Evidence classes and governing references](roadmap-technical.md#technical-roadmap-evidence)

<a id="concept-roadmap-open-questions"></a>
### Open questions without a milestone

Name clearance, terminal scope, the reference tool profile beyond the four
bootstrap tools, reference memory, pinned memory, published hand images,
secured-host validation, and package splits remain trigger-based questions.
Their presence here does not schedule them.

Technical depth: [Complete unscheduled question list](roadmap-technical.md#technical-roadmap-open-questions)

<a id="concept-roadmap-boundary"></a>
### Boundary

This file is not a backlog, commitment, release schedule, current-status
record, or source of authority. Git retains its history; accepted plans create
work commitments.

Technical depth: [Normative exclusions](roadmap-technical.md#technical-roadmap-boundary)
