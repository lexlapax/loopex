# 0003: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Extension contract boundary and distribution constraints](0003-extension-contract-boundary.md#concept).

This companion states the exact obligations, the constraints the founding vision
already fixes, and the questions this decision deliberately leaves open.

<a id="technical-adr-0003-context"></a>
## What Publication Forecloses

Concept: [Context](0003-extension-contract-boundary.md#concept-adr-0003-context).

A consumer pins a package, not a module or a surface. Three consequences follow
and none is reversible after a first publication:

1. A package's contents become a compatibility unit. Two surfaces shipped in one
   package share one version forever, which is why the extension API and the
   runtime cannot be the same published unit.
2. A package name becomes public. Renaming is a migration, not an edit.
3. A published package declares a language version requirement, which is a
   supported-span claim under
   [ADR 0002](0002-bootstrap-runtime-floor-technical.md#technical-adr-0002-compatibility).

Until publication, all three are free. The founding vision requires demonstrated
external-consumer pressure before a package boundary is drawn, and third-party
extension authors are that pressure for the contract specifically.

<a id="technical-adr-0003-decision"></a>
## Exact Obligations and Deferred Questions

Concept: [Decision](0003-extension-contract-boundary.md#concept-adr-0003-decision).

Obligations this decision fixes:

1. The contributor-facing dependency is `:loopex_protocol`. A published
   extension declaring a dependency on the runtime application is out of
   contract.
2. A first-party extension declares a manifest, is sealed into a retained
   artifact, and activates through the VM-global manager exactly as a
   third-party extension does. No build-time linking, no direct supervision-tree
   insertion, and no privileged activation path.
3. Acquisition sources are an application in this repository, a filesystem
   location the host admits, or a package registry. Each is an input to the
   builder or validation distribution, which resolves, compiles, and seals a
   candidate. None is a load path.
4. A brain never fetches or compiles a candidate. A minimal runtime distribution
   carries no compiler, and shared-VM activation rejects loading from
   unvalidated paths.
5. Host policy admits each candidate and owns the configuration naming sources.
   No Loopex application reads a user home directory, and no test or helper may
   point at a real one.

Deferred to the milestone that builds extensions, with the trigger recorded in
the roadmap ADR agenda:

- the installation pipeline and its durable records;
- the conflict-resolution algorithm across the sealed closure, including when a
  candidate is placed in a separate extension-host VM instead;
- signing, provenance, and trust-evidence formats;
- the host configuration schema and discovery rules;
- registry resolution and offline or air-gapped acquisition.

<a id="technical-adr-0003-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0003-extension-contract-boundary.md#concept-adr-0003-alternatives).

**Runtime as the contributor dependency.** Rejected. It contradicts the vision's
separately versioned surfaces: the extension API could not move without a
runtime release, and a runtime release would risk every extension.

**Full distribution ADR now.** Rejected. The vision reserves decisions for cases
where evidence must choose among valid designs. With no runtime, manifest
implementation, or observed conflict, the inputs are absent, and the artifact
would be rewritten rather than reused.

**Defer everything.** Rejected. The contributor-facing boundary and the
publication rule constrain the scaffold and the embedded API, both of which are
designed before extensions exist.

**A first-party fast path.** Rejected. An internal shortcut means the contract is
never exercised by the authors best placed to find its defects, and a shortcut
that exists is never removed.

<a id="technical-adr-0003-consequences"></a>
## Operational Consequences

Concept: [Consequences](0003-extension-contract-boundary.md#concept-adr-0003-consequences).

- Membership in the contract application is decided by whether an external
  contributor needs the module to build. Runtime convenience is not a reason,
  and the boundary needs review pressure because the easy failure is drift of
  runtime helpers into the contract.
- Sealing is set-wide. Admitting one candidate can require re-resolving and
  re-sealing every installed extension, so first-party extension dependencies
  stay minimal or absent.
- A prebuilt artifact carries its build toolchain and is verified before
  activation. An artifact built on an unlisted pair is unusable, not merely
  unsupported.
- Every first-party extension pays manifest and sealing cost. If that cost
  becomes an argument for a shortcut, the correct response is to reduce the
  cost, not to create an exemption.

<a id="technical-adr-0003-compatibility"></a>
## Compatibility and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0003-extension-contract-boundary.md#concept-adr-0003-compatibility).

No surface exists while nothing is published. This decision is removable on its
branch before integration, and its in-repository effects are module placement
and application dependencies only.

After a first publication, moving a module across the contract boundary,
renaming a published application, or withdrawing a package is a compatibility
event on the extension API and the released-package surface, requiring migration
notes and the amendment obligations in
[ADR 0002](0002-bootstrap-runtime-floor-technical.md#technical-adr-0002-compatibility).

Changing the contributor-facing dependency, permitting a first-party shortcut,
or allowing a brain to compile or fetch a candidate changes this decision and
requires an amendment with evidence.
