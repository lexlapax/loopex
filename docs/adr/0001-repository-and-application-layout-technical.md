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
apps/loopex_protocol/      Loopex.Protocol + the extension contract
apps/loopex/               Loopex.Core + Loopex.Runtime
apps/<adapter apps>/       model, store, executor, transport adapters
apps/<client apps>/        reference daemon and CLI
conformance/               language-neutral fixtures and golden vectors
examples/
docs/
```

`apps/loopex_protocol` holds what a contributor outside this repository must
compile against: versioned protocol envelopes and content types, canonical
boundary data types, extension behaviours and callbacks, and manifest and
contribution schemas. It holds no supervision, process, dispatch, or storage
code. The test for membership is whether an extension or an independent client
would need the module to build against a released contract; convenience for the
runtime is not a reason to place a module there.

Implementation constraints:

1. `apps/loopex_protocol/mix.exs` and `apps/loopex/mix.exs` each return an empty
   `deps` list apart from the one in-umbrella edge in constraint 3. No runtime,
   development, test, formatter, analysis, or documentation dependency is
   declared in either.
2. An accepted project-wide external tool, if later authorized, is declared at
   the umbrella root. This ADR does not authorize one.
3. `apps/loopex` declares exactly one in-umbrella dependency,
   `:loopex_protocol`. `apps/loopex_protocol` declares none, and no reverse edge
   from contract to runtime may exist. Adapter and client applications declare
   an inward dependency on `:loopex`, and on `:loopex_protocol` when they only
   need the contract.
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
  the one-version train; Mix does not supply that property automatically. Each
  umbrella child declares its own `:version`, written as `vsn` into its `.app`
  file, and the umbrella root declares none — so a shared version is a
  convention this repository enforces, not a property Mix provides. The check
  covers `apps/loopex_protocol` and `apps/loopex` from the first scaffold.
- Splitting the contract does not authorize publishing it. Publication remains
  deferred until an external consumer justifies it, and the split exists so that
  decision stays available rather than to make it.
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

A Hex-package or repository split, independent version train, external
dependency in either dependency-free application, a reverse edge from contract
to runtime, or further relocation of core and runtime into separate applications
changes this decision and requires an amendment with migration and rollback
evidence.

Moving a module between `apps/loopex_protocol` and `apps/loopex` is an ordinary
in-repository change while nothing is published. After publication it becomes a
compatibility event on surface 7 and on the extension API, because a consumer
pins the package rather than the module.
