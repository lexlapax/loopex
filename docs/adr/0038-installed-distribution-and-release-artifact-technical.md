<a id="technical-depth"></a>
## Technical depth

Concept: [Installed distribution and release artifact](0038-installed-distribution-and-release-artifact.md#concept).

<a id="technical-adr-0038-decision"></a>
### Artifact Contents

Concept: [Context and decision](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-decision).

**Build.** `mix release loopex` at the umbrella root, with `include_erts: true`,
`include_executables_for: [:unix]`, and the release's application list drawn
from the umbrella's role table so that every `:client`, `:store`, `:model` and
`:executor` application the reference host composes is included and nothing
else. The build runs only from a clean source extraction under the canonical
archive-extraction rule the milestone guide fixes, on the current toolchain
pair, and it is refused on a dirty tree. Cross-compilation is not used: each
platform builds on a host of that platform, which is why the supported set is
the two the project can run.

**Layout of the extracted archive.**

```text
loopex-0.3.0-<platform>/
  bin/loopex                 the promoted launcher (POSIX sh)
  bin/loopex-release         the mix release start script the launcher invokes
  erts-<version>/            the bundled runtime system
  lib/<app>-<version>/       every included application
  releases/0.3.0/            the release's boot and configuration files
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
  "release": "0.3.0",
  "source_commit": "<40-hex>",
  "source_identity_sha256": "<64-hex>",
  "toolchain": {"elixir": "1.20.3", "otp": "29.0.5"},
  "platform": "darwin-arm64",
  "files": [{"path": "bin/loopex", "size": 1234, "sha256": "<64-hex>"}],
  "archive_sha256": "<64-hex>"
}
```

`files` lists every file in the archive except `MANIFEST.json` itself, sorted
by raw path bytes, one entry per regular file with symbolic links recorded as
`{"path", "link": "<target>"}`. `archive_sha256` is the digest of the
`.tar.gz` and is repeated in `loopex-0.3.0-<platform>.tar.gz.sha256`.
`loopex version --verify` recomputes every file digest against the manifest
and reports the first mismatch.

<a id="technical-adr-0038-smoke"></a>
### Smoke Proofs

Concept: [Observable consequences](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-consequences).

The release check gains one lane per supported platform, run on a host of that
platform with **no** Git, Mix, Elixir or Erlang on the `PATH` (asserted by the
lane before it starts), from an empty temporary home:

1. Verify the archive against its checksum file; extract; `bin/loopex version
   --verify` exits `0`.
2. `bin/loopex init`, `config set` a provider profile whose credential
   reference names `LOOPEX_PROVIDER_API_KEY`, `config set` the policy profile,
   `doctor` exits `0`.
3. Start the daemon, run one real provider session through it, detach,
   attach as observer, take over, stop the daemon; every step is the M5
   workflow through the installed command.
4. Stop and restart the daemon; list and resume the session; complete it.
5. Extract a second copy beside the first as `0.3.0` again, switch, run the
   listing: the binary rollback contract.
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

**Rollback.** Binary: switch back to the previous directory. Storage: ADR 0036's
restore. The plan's single demonstration performs both in order: migrate,
run, restore under the previous release, run.

**Rejected alternatives.**

- *A single native executable* (Burrito-style) adds a packer dependency, a
  self-extraction step at first run and a second launcher; the OTP release
  already is a self-contained directory and the launcher already exists.
- *Hex publication* creates seven package surfaces at once and welds their
  versions; no consumer justifies it.
- *Service-manager installation* is host policy and a later milestone.
- *Homebrew or distribution packaging* depends on publication and on name
  clearance; it is not `0.3.0` scope.
- *A release without ERTS* would require an installed Erlang of the exact
  version and could not claim "no toolchain required".

**Open before acceptance.** The exact `platform` identifiers; whether the
Linux archive targets glibc only; the public-name clearance status, which
gates publication rather than this decision.
