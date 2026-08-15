# 0001. Repository and application layout

- **Status:** Proposed
- **Date:** 2026-08-15
- **Decision owner:** Maintainer
- **Prerequisite for:** the M0 gate (see [docs/roadmap.md](../roadmap.md))

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

## Context

[Vision §20.1](../vision.md) names one monorepo and one version train with four
visible areas — the standard-runtime-only protocol/core/runtime application,
replaceable adapter and reference-client applications, language-neutral
conformance fixtures, and executable examples plus documentation — and
deliberately does not freeze names or a directory tree. It requires the tree to
make dependency direction obvious: core never imports adapter, client, provider,
store, executor, or host implementations.

[Vision §7.2](../vision.md) is stricter than a naming preference. The `loopex`
core application must have **no external runtime dependency**, while the
reference model adapter is specified as using ReqLLM directly (founding
decisions 5 and 6). Those two requirements cannot both hold inside a single Mix
project: one `mix.exs` listing `req_llm` puts an external dependency in the core
application's dependency list on the day the reference adapter lands.

The same section warns the other way: "Folder structure alone is not evidence
for a package boundary," and physical application or Hex-package splits require
demonstrated pressure and an ADR. So the tree must separate applications without
implying separate packages or release trains.

A repository rider exists. `.claude/hooks/deps-budget.sh` hardcodes
`apps/loopex/mix.exs` and is silently inert before the scaffold exists. It is
client-only early feedback, not repository enforcement. That hook rejects
*every* dependency tuple in the core's deps list, including dev-only ones, so
any accepted layout permitting dev/test dependencies in `apps/loopex` would
also contradict the budget it previews.

## Decision

Use a single Elixir umbrella project at the repository root.

```text
mix.exs                    umbrella root; one version train
apps/loopex/               Loopex.Protocol + Loopex.Core + Loopex.Runtime
apps/<adapter apps>/       model, store, executor, transport adapters
apps/<client apps>/        reference daemon and CLI
conformance/               language-neutral fixtures and golden vectors
examples/
docs/
```

1. `apps/loopex` holds the protocol, pure core, and OTP runtime as one
   application, matching vision §20.1's singular "protocol/core/runtime
   application." Its `deps` list is **empty** — no runtime dependencies and no
   dev or test tooling either. By M0 closure, repository and development checks
   use only standard Elixir/OTP/Mix entrypoints; accepted adapter runtime
   dependencies remain outside core. If a later accepted decision adds a
   project-wide external formatter, analysis, or documentation dependency, it
   is declared once at the umbrella root rather than appearing in the core's
   dependency list.
2. Every replaceable edge and every reference client is its own umbrella
   application. Application boundaries carry the dependency direction
   structurally: `apps/loopex` never lists an in-umbrella dependency, and
   adapters depend inward on it.
3. Umbrella application boundaries are **not** package boundaries. Everything
   ships as one version train through 0.x. A Hex-package or repository split
   remains a separate decision requiring its own evidence and ADR
   (vision §7.2, §24.4).
4. Adapter and client applications are created by an accepted plan, each with a
   named owner and a reason beyond folder tidiness. This ADR fixes the shape,
   not the inventory.
5. `conformance/` sits outside `apps/` because the fixtures are language-neutral
   data for adapter authors in any language, not an OTP application.
6. The first accepted scaffold creates the repository-owned, client-neutral
   dependency-budget and direction command, currently proposed as
   `scripts/check-deps-budget.sh`, and wires it into the aggregate.
   `.claude/hooks/deps-budget.sh` becomes a thin caller of that command so every
   client and CI invoke the same enforcement. The repository command does not
   exist yet.
7. The **M0 gate** locks proof against a real `apps/loopex/mix.exs`, including an
   adversarial fixture that introduces a forbidden core-to-adapter reference and
   demonstrates that the repository command fails. This is an implementation
   obligation, not a condition of accepting this ADR: scaffolding cannot exist
   until an accepted plan and red gate authorize it.

## Alternatives and evidence

**Single Mix project with directory separation, enforced by `mix xref`.**
Rejected. The reference ReqLLM adapter would place an external dependency in the
core application's `mix.exs`, contradicting founding decision 5 directly. It
also erases the explicit application graph between core and adapter. A repository
check could reconstruct that boundary from directories and `mix xref` output,
but the umbrella represents the graph directly and still pairs it with the
adversarial enforcement required for static and dynamic references.

**Poncho projects — separate Mix projects joined by path dependencies.**
Rejected for now. It buys independent release cadence, which vision §7.2
explicitly does not want through 0.x, at the cost of a shared build, shared
test invocation, and shared configuration. Revisit only under demonstrated
release-cadence pressure, which would be the same evidence a package split
needs.

**Multiple repositories.** Rejected: vision §7.2 mandates one repository and one
release version through 0.x.

## Consequences

- Umbrella application boundaries make dependency direction explicit and
  enforceable, but do not prove it alone. The repository command and its
  adversarial fixture carry that proof; ordinary compilation is not claimed to
  detect every static or dynamically constructed module reference.
- The core-against-fakes build that vision §7.2 requires is expressible as an
  ordinary per-application test command.

What becomes harder:

- Umbrella configuration is repository-wide. This collides with the vision's
  runtime-instance rule: per-runtime state must not hide in application
  environment. Tests and examples must pass runtime references explicitly, and
  the M0 gate should include a check that core reads no global application
  environment for per-runtime state.
- Root `mix test` runs every application. The core-only, fakes-only build needs
  its own locked command; ambiguity there would let an adapter dependency leak
  into a "core" claim.
- Built-in analysis and formatter configuration lives at the umbrella root, and
  Dialyzer PLT handling in umbrellas needs explicit setup. Any later separately
  accepted external project-wide tool also lives at the root; this ADR does not
  authorize one.
- Publishing from an umbrella is per-application. The one-version-train rule
  becomes a check to write, not a property the tooling gives for free.

## Compatibility

No released surface exists; nothing to break. Application names inside `apps/`
are internal until a package is published, at which point the name becomes a
compatibility surface under vision §24.1.

## Migration and rollback

No code exists. Rollback is deleting the scaffold in the same branch that
created it. After applications exist, renaming one is a breaking change for any
in-repo dependent and must go through an amendment to this ADR.

## Links

- [Vision §7.1–§7.2](../vision.md) — four layers, core dependency budget
- [Vision §20.1](../vision.md) — repository seed and initial layout
- [Vision §24.1, §24.4](../vision.md) — versioned surfaces, publication posture
- [docs/roadmap.md](../roadmap.md) — capability guidance and ADR agenda
- [docs/developer/agent-context-map.md](../developer/agent-context-map.md) —
  the `deps-budget.sh` rider
