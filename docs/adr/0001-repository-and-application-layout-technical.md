# 0001. Repository and application layout — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Repository and application layout](0001-repository-and-application-layout.md#concept).

This file supplies implementation constraints and evidence for ADR 0001.
Status, ownership, and governance live in the Concept file; acceptance binds
both files.

<a id="technical-adr-0001-context"></a>
## Constraints and Current Rider

Concept: [Context](0001-repository-and-application-layout.md#concept-adr-0001-context).

[The dependency doctrine](../vision-technical.md#technical-vision-dependency-doctrine)
requires the `loopex` core application to carry no external runtime dependency,
while the reference model adapter may use ReqLLM. A single application-level
`mix.exs` listing `req_llm` would therefore place an adapter dependency in the
core application even if source directories were separated.

The same doctrine says folder structure is not evidence for a package boundary.
Physical application and package boundaries solve different problems:
applications express the runtime dependency graph, while Hex packages and
repositories establish publication and release boundaries.

`.claude/hooks/deps-budget.sh` currently hardcodes
`apps/loopex/mix.exs`. It rejects every dependency tuple in the core `deps`
list, including development-only and test-only tuples, but is silently inert
before that file exists. It is client-local early feedback, not portable
enforcement.

<a id="technical-adr-0001-decision"></a>
## Exact Tree and Enforcement Obligations

Concept: [Decision](0001-repository-and-application-layout.md#concept-adr-0001-decision).

The accepted shape is:

```text
mix.exs                    umbrella root; one version train
apps/loopex/               Loopex.Protocol + Loopex.Core + Loopex.Runtime
apps/<adapter apps>/       model, store, executor, transport adapters
apps/<client apps>/        reference daemon and CLI
conformance/               language-neutral fixtures and golden vectors
examples/
docs/
```

Implementation constraints:

1. `apps/loopex/mix.exs` returns an empty `deps` list. No runtime, development,
   test, formatter, analysis, or documentation dependency is declared there.
2. An accepted project-wide external tool, if later authorized, is declared at
   the umbrella root. This ADR does not authorize one.
3. `apps/loopex` never declares an in-umbrella dependency. Adapter and client
   applications declare an inward dependency on `:loopex` as required.
4. Every adapter or client application is created under an accepted plan that
   names its owner and the concrete boundary it implements.
5. `conformance/` is not an OTP application. Its fixtures remain plain,
   language-neutral data reusable by out-of-BEAM consumers.
6. The first accepted scaffold creates a repository-owned command, currently
   proposed as `scripts/check-deps-budget.sh`, and wires it into the aggregate.
   The existing client hook becomes a thin caller of that entrypoint.
7. The M0 gate locks proof against the real `apps/loopex/mix.exs` and an
   adversarial fixture containing a forbidden core-to-adapter reference. It
   proves the repository command detects dependency-list and source-reference
   violations. Ordinary compilation alone is not sufficient evidence,
   especially for dynamically constructed module references.
8. The gate includes a core-only, fakes-only command and proves that it neither
   resolves nor starts adapter applications.
9. The M0 gate checks that core reads no per-runtime state from global
   application environment; tests and examples pass runtime references
   explicitly.

The scaffold and gate are M0 implementation obligations, not conditions for
accepting this ADR. Product scaffolding remains unauthorized until the M0 plan
and branch-only red gate are accepted.

<a id="technical-adr-0001-alternatives"></a>
## Alternative Analysis and Evidence

Concept: [Alternatives](0001-repository-and-application-layout.md#concept-adr-0001-alternatives).

**Single Mix project with directory separation.** Rejected. A reference adapter
dependency would appear in the core application's dependency list, and the
application graph would need to be reconstructed from source directories and
analysis output. `mix xref` remains useful evidence inside the umbrella but is
not a substitute for the explicit application boundary.

**Poncho projects joined by path dependencies.** Rejected for now. They support
independent release cadence at the cost of shared configuration, build, and test
invocation. Revisit only when demonstrated release pressure justifies a package
boundary decision.

**Multiple repositories.** Rejected. The founding vision requires one
repository and version train through 0.x.

<a id="technical-adr-0001-consequences"></a>
## Operational Consequences and Edge Cases

Concept: [Consequences](0001-repository-and-application-layout.md#concept-adr-0001-consequences).

- Root `mix test` runs every application. A separate locked command must prove
  the core-only, fakes-only claim without adapter leakage.
- Formatter and built-in analysis configuration live at the umbrella root.
  Dialyzer PLT handling in umbrellas requires explicit setup if an accepted plan
  uses it.
- Umbrella configuration is repository-wide, but runtime-instance state is not.
  Any use of application environment for per-runtime ownership violates the
  runtime-reference invariant.
- Publishing from an umbrella is per application. A repository check must prove
  the one-version train; Mix does not supply that property automatically.
- Application boundaries do not detect every static or dynamic reference. The
  dependency command needs an adversarial corpus rather than one happy-path
  source scan.

<a id="technical-adr-0001-compatibility"></a>
## Compatibility and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0001-repository-and-application-layout.md#concept-adr-0001-compatibility).

No compatibility surface exists before publication. The scaffold can be
removed atomically on its implementation branch before integration. Once an
application name is consumed in-repository, renaming it changes dependent Mix
configuration and module/application references. Once published, the name is a
public compatibility surface governed by the
[technical compatibility rules](../vision-technical.md#technical-vision-compatibility).

A Hex-package or repository split, independent version train, external core
dependency, or relocation of protocol/core/runtime into separate applications
changes this decision and requires an amendment with migration and rollback
evidence.
