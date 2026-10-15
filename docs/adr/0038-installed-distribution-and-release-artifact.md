<a id="concept"></a>
## Concept

Technical depth: [Build recipe, artifact contents, install and smoke proofs](0038-installed-distribution-and-release-artifact-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-21; reconciled with the delivered M7 baseline and the
  maintainer's 2026-10-13 host and label decisions; build recipe, manifest,
  linkage inventory, install contract and failure names detailed on 2026-10-13;
  the maintainer's ADR 0003 compiler reading recorded on 2026-10-13; the
  attended reconnect and installed-service helper case `m8.service-review`
  added to the installed demonstration on 2026-10-13; after the holistic
  internal review on 2026-10-13, the revised closure hosts (D18), sign-out
  before uninstall, the retained M7 root in the refusal step (D24) and the
  scoped install umask; on 2026-10-14 the escript-build statement corrected,
  the fast-check refusal proofs named and the `auth` crash-dump case added
  (D37), then the NIF library modes, the fast-check seams, the attended
  record's restore step and the Linux lane's removal query corrected, and
  the uninstall keychain query limited to the operator's own home; the
  untouched-paths statement narrowed to what the service's own stop and
  start touch, and the closure matrix completed with `m7-adopt`,
  `m7-adopt-lock` and D36's deferral, and the daemon's discard of
  `LOOPEX_PROVIDER_API_KEY` stated with its binding exception, on 2026-10-14;
  the recovery of an M6 or M7 root stated as adoption or the build that wrote
  it, and the installed lane's archive line named, after the ninth internal
  review on 2026-10-14; the archive line's path stated on the host that runs
  the lane and its exit status on a failed step, after the tenth internal review on 2026-10-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing. It applies [ADR 0003](0003-extension-contract-boundary.md#concept)'s
  rule that a minimal runtime distribution carries no compiler, and
  [ADR 0019](0019-host-owned-provider-protection.md#concept)'s separate
  protected provider companion, to an installed artifact. It makes one
  clarifying amendment of accepted ADR 0003, decided by the maintainer on
  2026-10-13: obligation 4's sentence "A minimal runtime distribution carries
  no compiler" is read as "carries no build toolchain", so the OTP `compiler`
  application ships as a runtime dependency (see
  [The compiler clarification](#concept-adr-0038-compiler))
- **Depends on:** [ADR 0037](0037-host-configuration-and-path-discovery.md#concept) for installed initialization and configuration discovery, [ADR 0071](0071-daemon-attached-conversation.md#concept) for `chat --service`, `m8.service-review` and the service's configuration-only credentials, [ADR 0072](0072-store-readiness-marker-backup-and-restore.md#concept) for the current-format marker and the backup and restore commands, [ADR 0073](0073-provider-oauth-sign-in.md#concept) for uninstall's `auth status` and `auth logout`, the `loopex-oauth` keychain item and the `auth` crash-dump case, and accepted [ADR 0051](0051-current-format-physical-restore.md#concept) for the restore transition they use
- **Prerequisite for:** M8 outcomes 1, 6 and 7 (this was M6 before the maintainer's reframing of 2026-09-26), accepted before any release
  build, manifest or install script is written

<a id="concept-adr-0038-decision"></a>
### Context and Decision

Technical depth: [Artifact contents](0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-decision).

Technical depth: [Build recipe](0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-build).

Technical depth: [Failure modes and refusals](0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-failures).

Loopex is a source-tree surface. Running it needs Git, Mix and an Elixir/OTP
pair, or Mix and the pair from an M5 source archive. The reference CLI is an
escript named `loopex` (`apps/loopex_cli/mix.exs`) started through a small
POSIX launcher (`apps/loopex_cli/bin/loopex`). The launcher exists because the
emulator reserves `SIGINT`: it catches the terminal interrupt outside the
emulator and forwards `SIGTERM`, which the CLI turns into the public abort.
The provider companion is a second escript, built by the same command. Its
launch configuration records absolute `worker_path` and `interpreter_path`
values from the build machine
(`apps/loopex_llm_reqllm/lib/mix/tasks/loopex.provider.build.ex`), so the
companion is not relocatable today.

The vision's release governance is explicit: a binary release records its
exact source, artifact, toolchain, platform, contents, install proof and
recovery procedure; what a package contains is a compatibility decision,
because a consumer pins the package rather than the surfaces inside it; and a
minimal runtime distribution carries no compiler.

**The decision.**

1. **A binary release is one platform-specific archive that runs the two
   existing escripts on a bundled Erlang runtime.** `mix release` assembles
   the Erlang runtime system (ERTS) and the seven OTP library applications the
   escripts load. The reference CLI escript (which carries the runtime, the
   daemon and every reference application) and the provider companion escript
   are placed beside it. Both are built from the candidate commit by the same
   escript build the release check's fresh-source lane runs, the CLI with the
   relocatable launch pair, on each platform's pinned runtime. The release
   check's real-provider lanes exercise that extraction's own build; the
   installed-artifact lane exercises the archive's. The archive carries no build tool: no
   Mix, Hex, `erlc`, `elixirc`, source or dependency tree. The Erlang
   `compiler` application and Elixir's own modules are present only because
   the Elixir runtime declares them and does not start without them; nothing
   in the archive builds or fetches code. The maintainer decided this reading
   of ADR 0003 on 2026-10-13, below. "No Erlang or Elixir installation required" is claimed only
   because ERTS is bundled, and "no other installation required" only because
   every native object links nothing outside the platform base named below.
2. **The build environment is part of the decision.** On macOS the runtime is
   the precompiled Erlang/OTP 29.0.5 that mise installs for Apple silicon. It
   targets macOS 15.0, links its crypto library to OpenSSL statically, and
   links only system libraries. On Linux the runtime is built from source
   inside an Ubuntu 22.04 container, with OpenSSL 3 linked statically into the
   crypto library. The Linux build host's own runtime (a newer glibc with a
   dynamic system OpenSSL) is never used. A build refuses a toolchain or an
   output that links anything outside the platform's allowed base set.
3. **One installed command, the existing launcher, extended.** The archive
   extracts to one directory. `bin/loopex` is the launcher. When a manifest
   sits beside it, it runs the CLI escript with the bundled runtime, with the
   same interrupt forwarding as today. There is no second command, no wrapper
   generated per installation and no single native executable. From a
   source tree the launcher still runs the checkout's escript; it now also
   resolves a symbolic link to itself.
4. **The provider companion stays a separate protected process inside the
   release.** Its launch configuration names the companion and its
   interpreter by paths relative to the release root. The CLI resolves them
   once against its own location and verifies the companion's digest before
   every launch, as today. ADR 0019's process, Port, OS-guard and
   private-channel topology is unchanged.
5. **Every archive ships with a manifest and a verifier that needs nothing
   from the archive's runtime.** The manifest names the release version, the
   platform and its minimum base, the source commit, the Elixir, OTP, ERTS
   and OpenSSL versions, and every file with its mode class, size and SHA-256.
   The verifier is a POSIX shell script that uses only base-system tools, so
   it runs before anything in the archive is executed, including before the
   macOS quarantine step. The archive's own digest lives only in its external
   checksum file.
6. **Supported platforms for `0.5.0` are the two the maintainer selected on
   2026-10-13:** `darwin-arm64`, macOS 15.0 or later on Apple silicon; and
   `linux-x86_64`, glibc 2.35 or later on x86-64, with `ps` and a system
   certificate bundle present. A platform without a retained installed-artifact
   lane is not supported, whatever the archive builds on.
7. **The install and recovery contract is explicit.** Install is verify,
   extract and put `bin` on the `PATH`. Upgrade to a later build is replacing
   the install directory while the service is stopped. Uninstall is signing
   out of every provider with `loopex auth logout`, so no token outlives the
   program that can remove it, and then deleting the directory. The release
   never writes into its install directory. No install, upgrade or uninstall
   step other than the service's own `service stop` and start reads or
   writes a state root, a workspace or a backup; besides the service's own
   files in `log/` beside its configuration file, the only home write is
   that logout. A release opens only roots in its own current format and
   refuses any other root before writing to it, under ADR 0072. Before 1.0
   there is no upgrade of an older root and no switching back to an earlier
   release over a root this release wrote. Recovery is a backup restored under
   a build that reads the root's format, with ADR 0072's commands for the
   current format; the M6 and M7 builds provide no operator restore, so a
   root they wrote is adopted or stays with the build that wrote it.
8. **macOS uses a documented quarantine-removal step, not signing.** The
   maintainer chose on 2026-10-13 that the macOS archive is neither signed nor
   notarized. The operator verifies the archive against its checksum file,
   extracts it, verifies the extraction against its manifest, and only then
   removes the quarantine attribute with one documented command.
9. **Publication is a separate maintainer decision** after closure, gated on
   the public-name clearance the vision's name section already requires.
   Building and retaining the artifact is M8 scope; publishing it is not.

<a id="concept-adr-0038-compiler"></a>
### The Compiler Clarification of ADR 0003

Technical depth: [ADR 0003 amendment text](0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-compiler).

Accepted ADR 0003 says that a minimal runtime distribution carries no
compiler. Its purpose is that a running brain never fetches, builds or loads
unvalidated code. Elixir declares the OTP `compiler` application as a
dependency and does not start without it, so an archive that runs the
escripts cannot omit that application.

The maintainer decided on 2026-10-13 to read the rule as "carries no build
toolchain": no Mix, no Hex, no `erlc`, no `elixirc`, and no source or
dependency tree. The OTP `compiler` application ships as a runtime dependency
of Elixir, and nothing in the archive calls it to build or load code. This is
a clarifying amendment of ADR 0003's text. ADR 0003's accepted bytes are not
edited, and its other obligations are unchanged. The release layout check
refuses any build tool or source file in the archive.

<a id="concept-adr-0038-consequences"></a>
### Observable Consequences

Technical depth: [Install, upgrade and removal](0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-install).

Technical depth: [Smoke proofs](0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-smoke).

An operator on a supported platform downloads one archive and its checksum
file, checks the checksum, extracts, runs the verifier, on macOS removes the
quarantine attribute, moves the directory into place and adds its `bin` to the
`PATH`. `loopex init` then gives a working daemon and CLI with no toolchain
and no third-party OpenSSL installed. `loopex version` prints the release
version, platform, source commit and toolchain from the manifest.

A refused archive or install names its reason: a checksum or manifest
mismatch, an unexpected file, a file writable by others, the wrong platform or
a base system older than the minimum. Nothing runs from the archive until the
verifier has passed.

The attended installed demonstration runs the conversation through the
installed service. It reconnects to a running task from a second terminal,
and it runs ADR 0071's helper case `m8.service-review`: a review with helper
roles through the service, a detach and reconnect while a helper runs, and a
service stop during a helper followed by the stop-only result after restart.

The same source archive M5 produces still builds the escript pair from source
on either supported toolchain pair. The source tree keeps working as before:
the ordinary escript build is unchanged, and the launcher's checkout mode
still runs the checkout's escript.

<a id="concept-adr-0038-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-compatibility).

This creates the vision's surface 7, released package contents, which is inert
until publication and permanent afterward. The archive's name, layout,
manifest format and verifier are therefore fixed by this decision, not by
convenience: one archive contains the whole reference host and nothing that is
a separately versioned library. Hex packages are not published by M8.

Before 1.0 there is no binary rollback over a newer root, and no earlier build
is claimed to refuse one safely. Replacing an install leaves every root
untouched. If a later build refuses a root by name, the root is byte-identical
and the previous install directory, kept until the new build serves, still
opens it. Recovery from an unservable root restores a backup under a build
that reads its format, with ADR 0072's commands for the current format; the
M6 and M7 builds provide no operator restore. The installed demonstration proves the
refusal and the same-build restore together, so that "restart the old binary"
is never mistaken for a plan.

## Open for the Maintainer

None. Acceptance of this record includes the fix choices the M8 [internal review 2](../process/agent-context-map.md#disposition-m8-internal-review2-2026-10-13) and [holistic 2 to 10](../process/agent-context-map.md#disposition-m8-holistic10-2026-10-14) dispositions list for it.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
