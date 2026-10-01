<a id="technical-depth"></a>
## Technical depth

Concept: [Installed distribution and release artifact](0038-installed-distribution-and-release-artifact.md#concept).

<a id="technical-adr-0038-decision"></a>
### Artifact Contents

Concept: [Context and decision](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-decision).

**Build.** `mix release loopex` at the umbrella root, with `include_erts`
naming the release toolchain's ERTS, `include_executables_for: [:unix]`, and
the release's application list drawn from the umbrella's role table so that
every `:client`, `:store`, `:model` and `:executor` application the reference
host composes is included and nothing else. The build runs only from a clean
source extraction under the canonical archive-extraction rule the milestone
guide fixes, on the current toolchain pair's versions, and it is refused on a
dirty tree. Cross-compilation is not used: each platform builds on a host of
that platform, which is why the supported set is the two the project can run.

**Build environment.** The development toolchain is not the release
toolchain. Measured on 2026-09-21: on the Mac, Homebrew `erlang 29.0.5` links
`crypto.so` to `/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib`, which a
clean Mac does not have; on the Linux host, `/usr/lib/erlang` links
`crypto.so` to the distribution's `libcrypto.so.3`, `libbrotli*` and
`libzstd`, `beam.smp` to `libncursesw.so.6` and `libstdc++`, on glibc 2.44,
which is newer than Debian 12 (2.36) and Ubuntu 24.04 (2.39). A release built
from either would fail at its first provider call on the very host the smoke
lane describes. Therefore:

| Platform | Release toolchain | Build environment | Allowed base set |
| --- | --- | --- | --- |
| `darwin-arm64` | OTP of the current pair built by the retained recipe with OpenSSL linked statically into the crypto NIF and without a terminal library | The Mac, with the recipe's own OpenSSL source build; Homebrew is not on the build `PATH` | `/usr/lib/libSystem.B.dylib` and the system frameworks under `/System/Library/Frameworks`; nothing under `/opt` or `/usr/local` |
| `linux-x86_64` | The same recipe on Linux | A container of the oldest supported distribution, whose glibc is the platform's minimum base, fixed at acceptance; the Linux host's own OTP is never used | The dynamic loader, glibc's `libc`, `libm`, `libdl`, `libpthread`, `librt`, and `libgcc_s`; `libstdc++` only if the recipe cannot avoid it, recorded either way |

The recipes live under `scripts/release/`, one per platform, invoke the
toolchain's own configure and build with the flags that disable dynamic
OpenSSL and termcap, and record the OpenSSL version they embed in the
manifest. `scripts/release/assert-linkage.sh` runs `otool -L` or `ldd` over
every shared object and every executable in the archive and refuses any
resolution outside the archive or the allowed base set; it runs at build time
and as the smoke lane's first step. Recommended minimum bases, to be fixed
from the retained build at acceptance: the macOS version the Mac's SDK
targets, and glibc 2.35 from an Ubuntu 22.04 container.

**macOS distribution.** A downloaded archive carries the quarantine
attribute, and Gatekeeper refuses an unsigned or un-notarized `beam.smp`
extracted from it. Ad hoc signing does not clear a download. The decision
open before acceptance is whether `<installed-version>` is signed and notarized under a
developer account, or whether the operator guide documents removing the
attribute after verification; the smoke lane simulates the quarantined
download either way and proves the documented path.

**Layout of the extracted archive.**

```text
loopex-<installed-version>-<platform>/
  bin/loopex                 the promoted launcher (POSIX sh)
  bin/loopex-release         the mix release start script the launcher invokes
  erts-<version>/            the bundled runtime system
  lib/<app>-<version>/       every included application
  releases/<installed-version>/            the release's boot and configuration files
  companion/                 the protected provider companion and its launch file
  MANIFEST.json              see below
  SOURCE_IDENTITY            the M5-defined source identity of the tree it was built from
```

**Launcher promotion.** `bin/loopex` keeps its interrupt contract verbatim.
Its escript-location step gains one branch: when `../releases` exists beside
it, it runs the release start script with `eval`-free argument passing and the
same asynchronous child, saved stdin and forwarded `SIGTERM`. `LOOPEX_ESCRIPT`
keeps working for the checkout arrangement. The checkout mode is unchanged and
its existing tests keep passing.

**Companion placement.** The provider build task writes the launch
configuration with `worker_path` and `interpreter_path` relative to a
`release_root` key instead of absolute values; `ProviderConfiguration` resolves
them against the release root the launcher exports in one environment
variable at start and verifies the digest as today. The companion's escript
and its `.launch` and `.manifest` files live under `companion/`. In the
checkout arrangement the release root is the application directory, so the
same code serves both.

**Manifest.**

```json
{
  "release": "<installed-version>",
  "source_commit": "<40-hex>",
  "source_identity_sha256": "<64-hex>",
  "toolchain": {"elixir": "1.20.3", "otp": "29.0.5", "openssl": "<embedded version>"},
  "platform": "darwin-arm64",
  "platform_minimum": "<macOS version | glibc version>",
  "files": [{"path": "bin/loopex", "size": 1234, "sha256": "<64-hex>"}]
}
```

`files` lists every file in the archive except `MANIFEST.json` itself, sorted
by raw path bytes, one entry per regular file with symbolic links recorded as
`{"path": "...", "link": "<target>"}`. The archive SHA-256 appears only in
the external `loopex-<installed-version>-<platform>.tar.gz.sha256` checksum or
attestation, never inside the archive whose digest it names.
`loopex version --verify` recomputes every file digest against the manifest
and reports the first mismatch.

<a id="technical-adr-0038-smoke"></a>
### Smoke Proofs

Concept: [Observable consequences](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-consequences).

The release check gains one lane per supported platform, run on a host of that
platform with **no** Git, Mix, Elixir or Erlang on the `PATH` and no OpenSSL
outside the base system (on macOS, nothing under `/opt/homebrew/opt/openssl*`
or `/usr/local/opt/openssl*`; on Linux, inside a container of the minimum
base with no OpenSSL package), asserted by the lane before it starts, from an
empty temporary home:

The Open [M8 plan](../plans/M8.md#concept) widens this workflow: its outcome 6
adds an attached conversation with detach and reconnect, and a backup and
restore, and its proposal P8 names which commands start the service on demand.
The steps below predate that plan and are reconciled with it before
acceptance.

1. Verify the archive against its checksum file; extract as a quarantined
   download would be; `scripts/release/assert-linkage.sh` over the extraction
   exits `0`; `bin/loopex version --verify` exits `0`.
2. Initialize the home with the accepted successor grammar over ADR 0049's
   schema. Configure two admitted provider env references and exact model
   choices; validate, inspect origins and run `doctor`. No file credential or
   unaccepted provider-selection grammar is assumed.
3. Run `loopex run --daemon` with no daemon running: it starts the daemon on
   demand and completes one real provider session; detach, attach as
   observer, take over, `daemon stop`; every step is the M5 workflow through
   the installed command.
4. Start again on demand; list and resume the session; complete it;
   `daemon logs` prints a bounded redacted log.
5. Retain a pre-upgrade closed-root backup and an actually available prior
   artifact. Restore into an empty root using a verified restoration tool that
   supports that backup, then start the matching prior binary and validate its
   sessions. The first binary distribution may use the prior source release;
   do not assume it had an installed layout or a `store restore` command.
   Separately prove same-version backup/restore of the candidate's newer root.
6. Delete the directory; the home is intact; `ls` proves nothing was written
   outside the home, the workspace and the lane's temporary directory, which
   the lane proves by a before-and-after inventory of the filesystem roots
   the process could reach.

Every lane retains its complete output, the manifest and the archive digest
outside the repository under a stable reference and SHA-256 digest, and the
closure evidence page records them.

<a id="technical-adr-0038-compatibility"></a>
### Compatibility Mechanics

Concept: [Compatibility and rollback](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-compatibility).

**Surface 7.** The archive is the package. Its name, its contents and the
version it declares become permanent at first publication. Nothing in it is a
separately versioned library; the applications inside are not published to
Hex and their versions are the release's. A later change that splits the
archive is a compatibility decision under the vision's rule.

**ADR 0003.** The release carries no compiler, no Mix and no build path, which
is the minimal runtime distribution ADR 0003's clause 4 describes. Extension
acquisition and installation remain deferred; nothing in the archive is an
extension source.

**ADR 0019 and ADR 0034.** The companion remains a separate OS process behind
the Port and OS guard; the credential still crosses the private channel; the
composition-bound token resolved through host custody is unchanged. Only the
path resolution changes, and the digest verification before launch is kept.

**Rollback.** Follow step 5 of the installed smoke above: retain a pre-upgrade
backup and available prior artifact, restore with a compatible tool, then start
the matching prior binary. Do not assume the old artifact contains a restore
command or an installed directory layout.

**Rejected alternatives.**

- *A single native executable* (Burrito-style) adds a packer dependency, a
  self-extraction step at first run and a second launcher; the OTP release
  already is a self-contained directory and the launcher already exists.
- *Hex publication* creates seven package surfaces at once and welds their
  versions; no consumer justifies it.
- *Service-manager installation* is host policy and a later milestone.
- *Homebrew or distribution packaging* depends on publication and on name
  clearance; it is not `<installed-version>` scope.
- *A release without ERTS* would require an installed Erlang of the exact
  version and could not claim "no toolchain required".
- *Building the release from the development toolchain* was the first draft
  and is refused by the measurements above; it would have produced an
  archive that passes every fast check and fails on the first clean host.
- *A curl-piped install script*, which pi, Hermes Agent and OpenClaw all
  lead with, is a publication-time convenience and follows name clearance.

**Open before acceptance.** The exact `platform` identifiers and each
platform's minimum base, fixed from the retained recipe builds; the allowed
base-library set per platform, including whether `libstdc++` is in it; the
macOS signing and notarization decision; the public-name clearance status,
which gates publication rather than this decision.
