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
- **Prerequisite for:** M7 outcomes 1 and 5 (draft; this was M6 before the maintainer's reframing of 2026-09-26), accepted before any release
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
   Elixir installation required" is claimed only because ERTS is bundled, and
   "no other installation required" is claimed only because every native
   library ERTS and its NIFs need either links statically, ships inside the
   archive, or belongs to the platform's base system named in the companion.
   The Elixir release documentation states the contract plainly: a release
   runs on the same operating-system distribution and version it was
   assembled on. The ordinary development toolchain does not satisfy this:
   measured on 2026-09-21, the current pair's Homebrew OTP links its crypto
   NIF to Homebrew's OpenSSL, and the Linux host's OTP links glibc 2.44,
   OpenSSL, brotli, zstd and ncurses from its distribution.
2. **The build environment is part of the decision.** Each platform's release
   is built by a retained recipe from a release toolchain built for that
   purpose, inside a build environment whose base system is the oldest the
   release supports; the companion names the recipe, the environment and the
   allowed base-library set per platform, and the install lane refuses an
   archive whose shared objects resolve anywhere else.
3. **One installed command, the existing launcher, promoted.** The archive
   extracts to one directory; `bin/loopex` is the launcher, relocated with the
   directory, and it finds the release beside itself as it finds the escript
   today. There is no second command, no shell wrapper generated per
   installation and no single native executable.
4. **The provider companion stays a separate protected process inside the
   release**, discovered relative to the release root and verified by digest
   before every launch, as its launch configuration verifies it today. The
   absolute paths in that configuration become paths relative to the release
   root, resolved once at launch. ADR 0019's process, Port, OS-guard and
   private-channel topology is unchanged.
5. **Every archive ships with a manifest** naming the source commit, the
   toolchain pair, the platform and its minimum base system, every file with
   its size and SHA-256, the archive digest and the `SOURCE_IDENTITY` M5
   defines, plus a checksum file for the archive. An installation can be
   verified against the manifest without the source tree.
6. **Supported platforms for `0.3.0` are the two the project can prove:**
   macOS on Apple silicon and Linux on x86-64, each with a minimum base
   system fixed at acceptance from its build environment, on the current
   toolchain pair. A platform without a retained install smoke is not
   supported, whatever the archive builds on.
7. **The install and rollback contract is explicit.** Install is extract and
   run; upgrade is extract beside and switch; rollback of the binary is switch
   back, and rollback of a damaged or, in a later release, migrated root is
   ADR 0036's restore, which the plan proves together. Uninstall is delete
   the directory; the home is the operator's and is never deleted.
8. **Publication is a separate maintainer decision** after closure, gated on
   the public-name clearance the vision's name section already requires and
   on the macOS signing decision the companion records. Building and
   retaining the artifact is M7 scope; publishing it is not.

<a id="concept-adr-0038-consequences"></a>
### Observable Consequences

Technical depth: [Smoke proofs and manifest](0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-smoke).

An operator on a supported platform downloads one archive and its checksum,
verifies, extracts, runs `bin/loopex init`, and has a working daemon and CLI
with no toolchain and no third-party OpenSSL installed. `loopex version`
prints the release version, the source commit, the toolchain pair and the
platform from the manifest. The
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
packages are not published by M7. Rollback of the binary is switching
directories; rollback of storage is ADR 0036's; the two are proved together in
one demonstration so that "restart the old binary" is never mistaken for a
plan.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
