<a id="concept"></a>
## Concept

Technical depth: [Artifact contents, companion placement and smoke proofs](0038-installed-distribution-and-release-artifact-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-21
- **Decision owner:** Maintainer
- **Supersedes:** nothing; it applies [ADR 0003](0003-extension-contract-boundary.md#concept)'s
  rule that a minimal runtime distribution carries no compiler, and
  [ADR 0019](0019-host-owned-provider-protection.md#concept)'s separate
  protected provider companion, to an installed artifact
- **Prerequisite for:** M6 outcomes 1 and 5, accepted before any release
  build, manifest or install script is written

<a id="concept-adr-0038-decision"></a>
### Context and Decision

Technical depth: [Artifact contents](0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-decision).

Loopex is a source-tree surface. The operator index says it is not packaged or
published for consumers; the coding-sessions guide says the CLI is not
packaged or installed. Running it needs Git, Mix and an Elixir/OTP pair; after
M5 it needs Mix and the pair from a source archive. The reference CLI is an
escript named `loopex` (`apps/loopex_cli/mix.exs:24`) started through a small
POSIX launcher (`apps/loopex_cli/bin/loopex`) that exists for one reason: the
emulator reserves `SIGINT`, so the launcher catches the terminal interrupt
outside the emulator and forwards `SIGTERM`, which the CLI turns into the
public abort. The launcher already finds the escript beside itself and works
for a checkout, a copied pair and an installed pair. The provider companion
is built as a separate escript whose launch configuration records absolute
`worker_path` and `interpreter_path` values taken from the build machine
(`apps/loopex_llm_reqllm/lib/mix/tasks/loopex.provider.build.ex:56-70`), so
the companion is not relocatable today.

The vision's release governance is explicit: a binary release records its
exact source, artifact, toolchain, platform, contents, install proof and
rollback procedure; what a package contains is a compatibility decision,
because a consumer pins the package rather than the surfaces inside it; and a
minimal runtime distribution carries no compiler.

**The decision.**

1. **A binary release is one platform-specific OTP release archive** built by
   `mix release` from the umbrella, containing the compiled applications, the
   Erlang runtime system (ERTS) of the toolchain pair it was built with, the
   reference CLI, the daemon, the runtime and the protected provider
   companion. No compiler, no Mix and no Hex are inside it. "No Erlang or
   Elixir installation required" is claimed only because ERTS is bundled.
2. **One installed command, the existing launcher, promoted.** The archive
   extracts to one directory; `bin/loopex` is the launcher, relocated with the
   directory, and it finds the release beside itself as it finds the escript
   today. There is no second command, no shell wrapper generated per
   installation and no single native executable.
3. **The provider companion stays a separate protected process inside the
   release**, discovered relative to the release root and verified by digest
   before every launch, as its launch configuration verifies it today. The
   absolute paths in that configuration become paths relative to the release
   root, resolved once at launch. ADR 0019's process, Port, OS-guard and
   private-channel topology is unchanged.
4. **Every archive ships with a manifest** naming the source commit, the
   toolchain pair, the platform, every file with its size and SHA-256, the
   archive digest and the `SOURCE_IDENTITY` M5 defines, plus a checksum file
   for the archive. An installation can be verified against the manifest
   without the source tree.
5. **Supported platforms for `0.3.0` are the two the project can prove:**
   macOS on Apple silicon and Linux on x86-64, on the current toolchain pair.
   A platform without a retained install smoke is not supported, whatever the
   archive builds on.
6. **The install and rollback contract is explicit.** Install is extract and
   run; upgrade is extract beside and switch; rollback of the binary is switch
   back, and rollback of a migrated root is ADR 0036's restore, which the
   plan proves together. Uninstall is delete the directory; the home is the
   operator's and is never deleted.
7. **Publication is a separate maintainer decision** after closure, gated on
   the public-name clearance the vision's name section already requires.
   Building and retaining the artifact is M6 scope; publishing it is not.

<a id="concept-adr-0038-consequences"></a>
### Observable Consequences

Technical depth: [Smoke proofs and manifest](0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-smoke).

An operator on a supported platform downloads one archive and its checksum,
verifies, extracts, runs `bin/loopex init`, and has a working daemon and CLI
with no toolchain installed. `loopex version` prints the release version, the
source commit, the toolchain pair and the platform from the manifest. The
same source archive M5 produces still builds the same release from source on
either supported pair. The source tree keeps working exactly as before: the
escript build and the launcher's checkout mode are unchanged.

<a id="concept-adr-0038-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-compatibility).

This creates the vision's surface 7, released package contents, which is inert
until publication and permanent afterward. The archive's contents are
therefore fixed by this decision, not by convenience: one archive contains the
whole reference host and nothing that is a separately versioned library. Hex
packages are not published by M6. Rollback of the binary is switching
directories; rollback of storage is ADR 0036's; the two are proved together in
one demonstration so that "restart the old binary" is never mistaken for a
plan.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
