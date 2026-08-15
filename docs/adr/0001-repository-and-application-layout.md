# 0001. Repository and application layout

- **Status:** Proposed
- **Date:** 2026-08-15
- **Decision owner:** Maintainer
- **Prerequisite for:** the M0 gate (see [docs/roadmap.md](../roadmap.md))

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
`apps/loopex/mix.exs` and is silently inert under any other layout; the context
map requires the layout decision to fix that hook in the same change.

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
   application." Its `deps` list stays empty except for dev/test-only tooling,
   and the dependency-budget check enforces that.
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
6. Accepting this ADR requires the scaffold commit to make
   `.claude/hooks/deps-budget.sh` effective rather than inert, and to prove it
   fires — the chosen path matches the hardcoded `apps/loopex/mix.exs`, so the
   change is verification, not a rewrite.

## Alternatives and evidence

**Single Mix project with directory separation, enforced by `mix xref`.**
Rejected. The reference ReqLLM adapter would place an external dependency in the
core application's `mix.exs`, contradicting founding decision 5 directly. It also
demotes dependency direction from a structural property the compiler enforces to
a convention a check must chase, which is the weaker form of the same guarantee.

**Poncho projects — separate Mix projects joined by path dependencies.**
Rejected for now. It buys independent release cadence, which vision §7.2
explicitly does not want through 0.x, at the cost of a shared build, shared
test invocation, and shared configuration. Revisit only under demonstrated
release-cadence pressure, which would be the same evidence a package split
needs.

**Multiple repositories.** Rejected: vision §7.2 mandates one repository and one
release version through 0.x.

## Consequences

- Dependency direction becomes a compile-time property. A core module that
  reaches for an adapter fails to compile rather than failing review.
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
- Static-analysis and formatter configuration is duplicated or inherited across
  applications, and Dialyzer PLT handling in umbrellas needs explicit setup.
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
- [docs/roadmap.md](../roadmap.md) — ADR agenda and milestone sequencing
- [docs/developer/agent-context-map.md](../developer/agent-context-map.md) —
  the `deps-budget.sh` rider
