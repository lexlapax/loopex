<a id="technical-depth"></a>
## Technical depth

Concept: [Installed distribution and release artifact](0038-installed-distribution-and-release-artifact.md#concept).

<a id="technical-adr-0038-decision"></a>
### Artifact Contents

Concept: [Context and decision](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-decision).

**Names.** The release label is the content of `VERSION` (`0.5.0` for M8).
`<platform>` is `darwin-arm64` or `linux-x86_64`. The archive is
`loopex-<label>-<platform>.tar.gz`, gzip-compressed tar, with one top-level
directory `loopex-<label>-<platform>/`. Its checksum file is
`loopex-<label>-<platform>.tar.gz.sha256`, one line in the format
`shasum -a 256 -c` and `sha256sum -c` both read:
`<64 lowercase hex><two spaces>loopex-<label>-<platform>.tar.gz<LF>`.

**Layout of the extracted archive.** Exactly these entries; every directory
is mode `0755`, every file under `bin/`, `libexec/` and `erts-*/bin/` `0755`
and every other file, the two NIF libraries included, `0644`, owner and
group recorded as `0`.

```text
loopex-0.5.0-<platform>/
  bin/loopex                  launcher (POSIX sh), from apps/loopex_cli/bin/loopex
  bin/loopex-verify           verifier (POSIX sh), from apps/loopex_cli/bin/loopex-verify
  bin/no_dot_erlang.boot      boot file the escript runner loads from <root>/bin
  libexec/loopex              CLI escript, built with --relocatable
  libexec/loopex_provider     provider companion escript
  erts-17.0.5/bin/            beam.smp erl erlexec escript erl_child_setup inet_gethost
  lib/kernel-11.0.3/ebin/     and stdlib, compiler, crypto, asn1, public_key, ssl
  lib/crypto-5.9.2/priv/lib/crypto.so
  lib/asn1-5.5/priv/lib/asn1rt_nif.so
  releases/29/OTP_VERSION     read by ProviderWorker.otp_version/0
  SOURCE_IDENTITY             the export-substituted commit and committer date
  LICENSE                     the repository licence
  MANIFEST                    see below
```

The ERTS and application versions are those of OTP 29.0.5 and are recorded
in the manifest; a different OTP patch release changes them only through an
amendment of the pins below. The seven OTP applications are the closure of
every OTP application the two escripts' embedded `.app` files declare
(`kernel`, `stdlib`, `compiler`, `crypto`, `ssl`, `public_key`) plus
`asn1`, which `public_key` requires. No dependency in `mix.lock` contributes
native code, so the native objects are exactly the five ERTS executables and
the two NIF libraries named above. `apps/loopex_cli/bin/loopex-verify` is a
new file in the source tree; everything else is built or copied.

**Launcher.** `bin/loopex` keeps its interrupt contract verbatim: saved
standard input, asynchronous child, trapped `INT TERM HUP QUIT` forwarded as
`SIGTERM`, the `ask` crash-dump settings and the `kill -0` wait loop. Besides
extending the crash-dump case from `ask` to `auth` (`bin/loopex:60-67`; M8
D37, ADR 0073), it changes in two places.

1. It resolves `$0` through symbolic links (a `readlink` loop, relative
   targets joined to the link's directory) before computing its own
   directory with `pwd -P`, so a link from a `PATH` directory works.
2. Command selection: `LOOPEX_ESCRIPT` when set, as today; otherwise, when
   `$here/../MANIFEST` is a regular file, the installed mode; otherwise the
   checkout mode, which runs `$here/../loopex` as today. The installed mode sets
   `root=$(cd "$here/.." && pwd -P)`, requires exactly one
   `$root/erts-*/bin/escript` and an executable `$root/libexec/loopex`, unsets
   `ERL_LIBS ERL_ROOTDIR ESCRIPT_EMULATOR ERL_FLAGS ERL_AFLAGS ERL_ZFLAGS`,
   and starts the child as `"$runner" "$root/libexec/loopex" "$@"`. The
   runner, `erl`, `erlexec` and `beam.smp` exec one another, so the child
   process identifier the launcher signals is the emulator, exactly as with
   today's `#!/usr/bin/env escript` chain.

**Companion relocation.** `mix loopex.provider.build` accepts
`--relocatable` beside `--force` and `--warnings-as-errors`; `build_pair/1`
already forwards its arguments. The task builds, validates and verifies the
companion at its absolute build paths as today, then writes the `.launch`
file with `worker_path: "libexec/loopex_provider"` and
`interpreter_path: "erts-<:erlang.system_info(:version)>/bin/escript"`, both
relative, and the unchanged `worker_sha256` and `build_manifest_sha256`. The
CLI embeds that file at compilation as today. `LoopexCli.ProviderLaunch.options/0`
returns `options/2` applied to that embedded configuration and
`Path.expand(:escript.script_name())`; `options/2` is the test seam, since
under ExUnit the script name is not the escript. It returns the
configuration with both paths joined to the release root, the escript path
with two directory levels removed, when both paths are relative; it returns
absolute paths unchanged; a mixed pair is returned unchanged and
`ProviderConfiguration.validate/1` refuses it. The
root therefore comes from the location of the code already running, never
from the environment. `ProviderConfiguration` is unchanged: it still requires
absolute paths, and `verify_artifact/1` still checks the companion's digest
and the interpreter's execute bit before every launch. The companion runs on
the bundled runtime because the carrier executes `"$interpreter" "$worker"`
under `env -i PATH=/usr/bin:/bin`, the runner finds `erl` beside itself, and
Mix's `erl` derives `ROOTDIR` from its own location. The worker's identity
check compares its build manifest's Elixir and OTP versions with
`System.version()` and `releases/29/OTP_VERSION`, which is why that file is
placed. The archive ships no `.launch` file. The daemon's
`--provider-launch FILE` keeps requiring absolute paths; which launch source
the installed service uses when that flag is absent is ADR 0071's cell, and
this ADR provides `options/0` for it. A `--relocatable` CLI run from a
checkout finds no companion and refuses as `provider_artifact_unavailable`;
only the release step uses that build.

**Version command.** `loopex version` takes no arguments. In the installed
mode it prints one line from the manifest header,
`loopex <release> <platform> commit <source-commit> elixir <v> otp <v> openssl <v>`,
and exits `0`, or exits `1` with `manifest_unreadable`. From a checkout it
prints `loopex <VERSION> source`. It reads the root through a function that
takes the escript path, which `version_command_test.exs` calls with a
temporary tree. It verifies nothing; the verifier does.

**Manifest.** `MANIFEST` is ASCII text, one LF-terminated line per entry,
fields separated by one space:

```text
loopex-manifest 1
release 0.5.0
platform darwin-arm64
minimum macos 15.0
source-commit <40 lowercase hex>
elixir 1.20.3
otp 29.0.5
erts 17.0.5
openssl 3.5.7
runtime mise-precompiled
files <decimal count>
<mode> <size> <sha256> <path>
...
```

On Linux the variable lines read `platform linux-x86_64`,
`minimum glibc 2.35` and `runtime ubuntu-22.04-source`. `openssl` is the
version `crypto:info_lib()` reports for the bundled runtime. Each file record
has `mode` `755` when any execute bit is set and `644` otherwise (the class
the source-archive manifest already uses, so an operator's umask cannot fail
verification), the decimal byte size, the lowercase SHA-256 and the path
relative to the top directory. Records cover every regular file except
`MANIFEST`, sorted by path bytes (`LC_ALL=C`). Paths use only
`A-Z a-z 0-9 . _ + @ - /`, have no empty, `.` or `..` component and never
name a symbolic link or any other non-regular file. The writer refuses
anything else, so the verifier never parses an ambiguous line.

**Verifier.** `/bin/sh <root>/bin/loopex-verify [<root>]` defaults `<root>`
to the parent of its own directory. It uses only `sh`, `uname`, `find`,
`sort`, `awk`, `stat`, `wc`, and `shasum -a 256` on macOS or `sha256sum` on
Linux, plus `sw_vers` or `getconf GNU_LIBC_VERSION`; it hashes in batches
through `find ... -exec ... {} +`. In order, it checks: the operating system
and `uname -m` match `platform` (`Darwin arm64` or `Linux x86_64`); the host
meets `minimum` (`sw_vers -productVersion` at least `15.0`, or glibc at least
`2.35`); the header's grammar; that no entry under the root is other than a
regular file or directory; that no file or directory is group- or
world-writable; and that the recomputed record list equals the manifest's,
byte for byte, naming the first differing path. Success prints
`loopex-verify: PASS <release> <platform> <count> files` and exits `0`; a
refusal prints its name and exits `1`; a usage error exits `2`.
`--inventory <root>` prints only the record lines for the writer, so one walk
implementation serves both. The trust anchor is the external checksum: the
verifier proves the extraction is complete and unmodified, not that an
archive whose checksum was never checked is authentic.

**Allowed native-library inventory.** Every one of the seven native objects
must satisfy its platform's rules; any other Mach-O or ELF file in the tree is
refused.

| Platform | Allowed dependencies | Also required |
| --- | --- | --- |
| `darwin-arm64` | Exactly these install names: `/usr/lib/libSystem.B.dylib`, `/usr/lib/libutil.dylib`, `/usr/lib/libncurses.5.4.dylib`, `/usr/lib/libz.1.dylib`, `/usr/lib/libc++.1.dylib`, `/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon`, `/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa` | No `LC_RPATH`; no `@rpath`, `@loader_path` or `@executable_path` name; `LC_BUILD_VERSION` platform `1` with `minos` at most `15.0`; architecture `arm64` only; `codesign --verify --strict` passes, so no step may rewrite a Mach-O after the toolchain produced it |
| `linux-x86_64` | `NEEDED` entries only from `libc.so.6`, `libm.so.6`, `libpthread.so.0`, `libdl.so.2`, `librt.so.1`, `libutil.so.1`, `ld-linux-x86-64.so.2`, all provided by glibc | No `RPATH` or `RUNPATH`; executables request `/lib64/ld-linux-x86-64.so.2`; the highest `GLIBC_` symbol version is at most `2.35`; no `GLIBCXX_`, `CXXABI_` or `GCC_` symbol version, because `libstdc++` and `libgcc` link statically |

The macOS list is the measured linkage of the mise OTP 29.0.5 objects the
archive carries (2026-10-13): `beam.smp` uses all seven names, the helpers
`libSystem` and `libutil`, and `crypto.so` and `asn1rt_nif.so` only
`libSystem`. `scripts/release/assert-linkage.sh <platform> <tree>` enforces
the table with these commands:

```sh
# darwin-arm64, per object f
otool -L "$f" | tail -n +2 | awk '{print $1}'      # each name in the allowed list
otool -l "$f" | grep -c LC_RPATH                    # 0
otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}'   # <= 15.0
lipo -archs "$f"                                    # arm64
codesign --verify --strict "$f"
# linux-x86_64, per object f (build environment, binutils present)
objdump -p "$f" | awk '$1=="NEEDED"{print $2}'      # each name in the allowed list
objdump -p "$f" | awk '$1=="RPATH"||$1=="RUNPATH"'  # empty
objdump -T "$f" | grep -oE '\((GLIBC|GLIBCXX|CXXABI|GCC)_[0-9.]+\)' | sort -u
readelf -l "$f" | sed -n 's/.*program interpreter: \(.*\)]/\1/p'
# linux-x86_64 smoke mode (clean container, no binutils)
ldd "$f"    # every line resolves under /lib/x86_64-linux-gnu, /usr/lib/x86_64-linux-gnu or /lib64, or is linux-vdso; no "not found"
```

The script runs on the toolchain's own objects before a build, on the staged
tree before the archive is written, and in the smoke lane on the extraction.

<a id="technical-adr-0038-build"></a>
### Build Recipe

Concept: [Context and decision](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-decision).

**Pins.** `scripts/release/toolchain.env` holds the release pins as shell
assignments: `ELIXIR=1.20.3`, `OTP=29.0.5`, `ERTS=17.0.5`,
`OPENSSL=3.5.7`, `MACOS_MINIMUM=15.0`, `GLIBC_MINIMUM=2.35`, the Ubuntu base
image as `ubuntu:22.04@sha256:<digest>`, and the SHA-256 of
`otp_src_29.0.5.tar.gz`, `openssl-3.5.7.tar.gz` and Elixir's
`elixir-otp-29.zip`. The digests are the values upstream publishes for those
exact versions and the image digest is the one pulled when the file is
written; changing any of them is a recipe change reviewed like code. The build
refuses when `ELIXIR` and `OTP` differ from the current pair in
`.tool-versions`, so the release always uses the current supported pair.
OpenSSL 3.5.7 is the version the macOS runtime embeds, so both platforms
carry the same OpenSSL.

**Release definition.** The umbrella `mix.exs` gains `releases: releases()`:

```elixir
defp releases do
  [
    loopex: [
      applications: [
        elixir: :none,
        sasl: :none,
        compiler: :load,
        crypto: :load,
        asn1: :load,
        public_key: :load,
        ssl: :load
      ],
      include_erts: true,
      include_executables_for: [],
      runtime_config_path: false,
      strip_beams: true,
      steps: [:assemble, &installed_layout/1]
    ]
  ]
end
```

`kernel` and `stdlib` keep Mix's `:permanent` default. `elixir` must be
`:none` or `:load` when `compiler` is `:load`, and Mix always adds `elixir`,
`sasl` and `iex`. The release version is `VERSION`. No runtime configuration,
`sys.config`, `vm.args` or start script is used, because nothing boots the
release as a release: the escripts boot ERTS with their own embedded
arguments. `installed_layout/1` is a private function in the umbrella
`mix.exs` that returns the release after, in order:

1. removing `lib/elixir-*`, `lib/iex-*`, `lib/sasl-*` (the escripts embed
   their own Elixir), every `lib/*/include`,
   `lib/crypto-*/priv/lib/otp_test_engine.so` and the whole of `releases/`,
   whose boot scripts, configuration and per-build random `COOKIE` are unused;
2. reducing `erts-*/bin` to `beam.smp`, `erl`, `erlexec`, `escript`,
   `erl_child_setup` and `inet_gethost`;
3. copying from the toolchain root (`:code.root_dir()`)
   `bin/no_dot_erlang.boot` and `releases/<otp_release>/OTP_VERSION` to the
   same relative paths;
4. copying from the source tree `apps/loopex_cli/bin/loopex` and
   `apps/loopex_cli/bin/loopex-verify` to `bin/`, `apps/loopex_cli/loopex`
   and `<build path>/loopex_provider` to `libexec/`, and `SOURCE_IDENTITY` and
   `LICENSE` to the root;
5. setting directory modes to `0755`, file modes under `bin/`, `libexec/`
   and `erts-*/bin/` to `0755`, and every other file's, the NIF libraries
   under `lib/*/priv/lib` included, to `0644`, and
   running `scripts/release/check-layout.sh <tree>`, raising
   `release_layout_unexpected: <path>` with the path it prints for a symbolic
   link, a path outside the manifest character set, an executable file
   outside `bin/`, `libexec/` and `erts-*/bin/`, or a native object outside
   the inventory.

It writes no manifest and no archive. A probe of this definition on
2026-10-13, with the M7 escript pair and the mise toolchain on the Mac, gave a
22 MiB runtime on which, under `env -i PATH=/usr/bin:/bin`, the CLI printed
its usage, the companion booted to its bootstrap refusal and
`crypto:info_lib()` reported OpenSSL 3.5.7. Without `bin/no_dot_erlang.boot`
the runner cannot boot, and without `compiler` Elixir does not start.

**Scripts.**

| Script | Runs | Inputs | Outputs |
| --- | --- | --- | --- |
| `scripts/release/build.sh <commit> <out-dir>` | On the build host | A commit and an existing empty directory outside the checkout | In `<out-dir>`: the archive, its `.sha256`, a copy of `MANIFEST` named `loopex-<label>-<platform>.MANIFEST`, `build.log`, `linkage.log` |
| `scripts/release/assemble.sh <src> <out-dir>` | Inside the build environment | A fresh source extraction | The same outputs |
| `scripts/release/check-layout.sh <tree>` | Inside the build environment, from `installed_layout/1` | A staged tree | The first unexpected path; exit `1` on refusal |
| `scripts/release/write-manifest.sh <platform> <tree>` | Inside the build environment | A staged tree | `<tree>/MANIFEST` |
| `scripts/release/assert-linkage.sh <platform> <tree> [--smoke]` | Build and smoke | A tree of native objects | A report on standard output; exit `1` on refusal |
| `scripts/release/smoke.sh <out-dir>` | The installed-artifact lane | Build outputs | The lane's retained evidence |
| `scripts/release/linux/Dockerfile`, `Dockerfile.smoke` | Linux build host | `toolchain.env` | The build and smoke images |

`build.sh` refuses an unsupported host (`Darwin arm64` and `Linux x86_64`
with Docker are the two supported), stages `git archive <commit>` into a
fresh extraction under the milestone guide's scoped-umask
[archive-extraction rule](../process/milestones-technical.md#technical-milestones-archive-extraction),
and requires the extraction's `SOURCE_IDENTITY` to name `<commit>`. It then
runs `assemble.sh` in the platform's build environment.

`assemble.sh` prints each step with its elapsed time and:

1. asserts the toolchain: `elixir` reports `1.20.3`, `OTP_VERSION` reads
   `29.0.5`, `:erlang.system_info(:version)` is `17.0.5`, `crypto:info_lib()`
   reports OpenSSL `3.5.7`, and `assert-linkage.sh` passes on the toolchain's
   copies of the seven native objects;
2. runs `mix local.hex --force` and `mix local.rebar --force` into the
   build's writable `MIX_HOME`, then `mix deps.get`, which verifies every
   package against `mix.lock`;
3. runs `MIX_ENV=prod mix cmd --app loopex_cli mix escript.build --relocatable`
   with no provider credential in the environment, then
   `elixir scripts/escript-inventory.exs` on the two escripts;
4. runs `MIX_ENV=prod mix release loopex --no-compile --path <stage>/loopex-<label>-<platform>`;
5. runs `assert-linkage.sh` on the staged tree, `write-manifest.sh`, and then
   the staged `bin/loopex-verify`, which must pass;
6. writes the archive with ownership `0:0` and no extended attributes
   (macOS: `COPYFILE_DISABLE=1 tar --no-mac-metadata --uid 0 --gid 0 -czf`;
   Linux: `tar --owner=0 --group=0 --numeric-owner -czf`), lists it with
   `tar -tzf`, requires its entry set to equal the manifest's paths plus
   `MANIFEST` and their directories, and writes the `.sha256` file.

Archive bytes are not claimed to be reproducible; the manifest's file digests
are what two builds of one commit are compared by.

**macOS build environment.** The Mac itself, with the runtime that
`mise install erlang@29.0.5` provides for Apple silicon (the precompiled
build) and `elixir@1.20.3-otp-29`. Measured on 2026-10-13: its `beam.smp`
declares `LC_BUILD_VERSION` `minos 15.0`, `sdk 15.5`; its `crypto.so` embeds
OpenSSL 3.5.7 and links only `libSystem`. `build.sh` runs `assemble.sh` under
`env -i HOME=<temporary> LANG=C.UTF-8
PATH=<mise where erlang>/bin:<mise where elixir>/bin:/usr/bin:/bin:/usr/sbin:/sbin`,
so no Homebrew or other prefix is reachable by name. No C code is compiled on
macOS.

**Linux build environment.** A container from `scripts/release/linux/Dockerfile`,
run on the Linux build host (Docker 29.8 on `serenity`); the host's own Arch
runtime (glibc 2.44, dynamic `libcrypto.so.3` 3.4) is never used. The image:

```text
FROM <pinned ubuntu:22.04 digest>
apt-get install --no-install-recommends build-essential autoconf m4 perl \
  curl ca-certificates unzip git binutils
# OpenSSL, static, no loadable modules; every tarball checked with sha256sum -c
./Configure linux-x86_64 no-shared no-module no-tests no-docs -fPIC \
  --prefix=/opt/openssl --libdir=lib --openssldir=/etc/ssl
make -j"$(nproc)" && make install_sw
# Erlang/OTP 29.0.5 from otp_src_29.0.5.tar.gz
./configure --prefix=/opt/erlang --with-ssl=/opt/openssl --disable-dynamic-ssl-lib \
  --without-termcap --enable-builtin-zlib --without-javac --without-jinterface \
  --without-wx --without-odbc --without-observer --without-debugger --without-et \
  --without-megaco LDFLAGS="-static-libstdc++ -static-libgcc"
make -j"$(nproc)" && make install
# Elixir 1.20.3 from elixir-otp-29.zip, unzipped into /opt/elixir
ENV PATH=/opt/elixir/bin:/opt/erlang/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8
# No Mix, Hex or Rebar step runs at image build time; /opt stays root-owned
# and read-only to the build user.
```

`--without-termcap` removes the terminal library (the escripts run without the
interactive shell), `--enable-builtin-zlib` removes `libz`, and the static
`libstdc++` and `libgcc` remove the C++ runtime the JIT would otherwise
need. The image's `PATH` names `/opt/elixir/bin` and `/opt/erlang/bin` before
any command runs in it, so every `mix`, `elixir` and `erl` invocation resolves
to the pinned toolchain. `build.sh` runs the image as the invoking user's UID
and GID, with the extraction and `<out-dir>` bind-mounted read-write, a fresh
mode-`0700` host temporary directory bind-mounted read-write at `/build-home`,
and no credential in the environment. That user cannot write `/opt`, so every
Mix, Hex and Rebar location is writable and confined to the build:
`HOME=/build-home`, `MIX_HOME=/build-home/mix`, `HEX_HOME=/build-home/hex`,
`REBAR_CACHE_DIR=/build-home/rebar3-cache` and
`XDG_CACHE_HOME=/build-home/cache`; `deps` and `_build` stay inside the mounted
extraction. On macOS the same variables are set under the `env -i` temporary
`HOME`. `assemble.sh` step 2 installs Hex and Rebar into those locations.
`build.sh` removes the temporary directory after the build. Hex and Rebar are
build-only tools; their versions appear in `build.log`.

<a id="technical-adr-0038-install"></a>
### Install, Upgrade and Removal

Concept: [Observable consequences](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-consequences).

**Install, macOS.** In the download directory:

```sh
shasum -a 256 -c loopex-0.5.0-darwin-arm64.tar.gz.sha256
tar -xzf loopex-0.5.0-darwin-arm64.tar.gz
/bin/sh loopex-0.5.0-darwin-arm64/bin/loopex-verify
xattr -dr com.apple.quarantine loopex-0.5.0-darwin-arm64
(umask 022; mkdir -p "$HOME/.local/opt") && mv loopex-0.5.0-darwin-arm64 "$HOME/.local/opt/loopex"
export PATH="$HOME/.local/opt/loopex/bin:$PATH"     # and in the shell profile
loopex version
```

Nothing from the archive executes before the `xattr` line: the verifier is
read by the base system's `/bin/sh`. The scoped `umask 022` creates any
missing `.local` and `.local/opt` as `0755` whatever the shell's umask, so
the install location's parents are never group- or world-writable, which
the location rule below requires. A downloaded archive carries the
quarantine attribute, extraction may propagate it, and Gatekeeper refuses the
ad hoc-signed `beam.smp` while it is present; the recursive removal clears it
whether or not it was propagated.

**Install, Linux.** The same sequence with `sha256sum -c` in place of
`shasum -a 256 -c` and without the `xattr` line. The base system must provide
glibc 2.35 or later, `/bin/sh`, `/bin/ps` (`procps`), `/usr/bin/awk`,
`/usr/bin/env`, `tar`, `gzip`, `sha256sum` and a certificate bundle at one of
the paths `public_key:cacerts_get/0` reads, such as
`/etc/ssl/certs/ca-certificates.crt`. macOS 15 provides every corresponding
tool and reads trust from the system keychain.

**Location.** The release runs from any directory the operator owns that is
not group- or world-writable; `$HOME/.local/opt/loopex` is the documented
default. It must not be inside the Loopex home (`$HOME/.loopex` under ADR
0037) or a state root. The release never writes into its install directory.

**Upgrade to a later build.** With the service stopped by ADR 0037's stop
command: verify and extract the new archive as above (on macOS including the
`xattr` line), then

```sh
mv "$HOME/.local/opt/loopex" "$HOME/.local/opt/loopex.previous"
mv loopex-<new>-<platform> "$HOME/.local/opt/loopex"
loopex version
```

and start the service. If it serves, delete `loopex.previous`. If the new
build refuses the root by name under ADR 0072, the root is byte-identical;
swap the two directories back and the previous build serves it again. No
command upgrades a root.

**Uninstall.** There is no uninstall command. With the installed command
still on the `PATH`:

```sh
loopex service stop
loopex auth status                  # lists each signed-in provider
loopex auth logout <provider>       # once for each provider it lists
rm -rf "$HOME/.local/opt/loopex"
```

and remove the `PATH` line. Logout runs first because only the installed
command can remove its own sign-in tokens: it deletes each route's token from
the keychain, the Secret Service or the owner-only file and revokes it where
ADR 0073 says the provider allows; a keychain item left behind would outlive
the program that can read it. After deleting the install, the operator can
confirm that no Loopex item remains: on macOS
`security find-generic-password -s loopex-oauth` finds none, and
on Linux `secret-tool search application loopex-oauth` lists none.

**Never touched.** No install, upgrade or uninstall step reads or writes a
state root, any workspace or any backup. The only home write is uninstall's
`auth logout`, which removes sign-in tokens and metadata under ADR 0073 and
leaves the configuration, the log and every root. Deleting the home is the
operator's separate act and no documented step performs it.

<a id="technical-adr-0038-smoke"></a>
### Smoke Proofs

Concept: [Observable consequences](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-consequences).

`scripts/check-release.sh` gains the lane `installed-artifact`, selectable
with `--only installed-artifact`. It runs `build.sh` for the candidate into the
retained-output directory, then `smoke.sh`. On a `Darwin arm64` host it
proves `darwin-arm64`; on a `Linux x86_64` host with Docker it proves
`linux-x86_64`. The closure matrix, as the M8 plan's decision D18 fixes it
in its revision of 2026-10-13, runs the full release check once on the
`Linux x86_64` host `serenity`, with the M8 attempts index whose writer is
pinned there; that run proves `linux-x86_64` with this lane and also runs
the `secret_service`, `cross_uid` and attended
`real-sign-in-*` lanes. The `Darwin arm64` host runs this lane with
`--only installed-artifact`, together with `--only macos_keychain` and the
attended outcome-6 record, `--only m8-operator`, on the same commit, and
each is recorded in the same M8 index as a required closure lane. Every one
of them is required: a lane that reports evidence unavailable, such as a
Linux host without Docker for this lane, blocks closure and is never a pass.
Both hosts' complete outputs are retained.

**Clean host.** On macOS the lane runs as the invoking user under
`HOME=<empty temporary>`, `LANG=C.UTF-8` and
`PATH=/usr/bin:/bin:/usr/sbin:/sbin` with every other variable unset except
the provider credential variables the lane names, `ANTHROPIC_API_KEY` and
`OPENAI_API_KEY`, which the release runner's `with_installed_credentials`
wrapper exports by name and never places in argv. The lane's `init`
configuration references exactly those names: `loopex daemon --config`
discards `LOOPEX_PROVIDER_API_KEY` unread under ADR 0071, so the release
credential reaches the installed service only under the name its
configuration references. Before it starts it
asserts that `command -v erl erlc escript elixir mix iex` finds nothing and
that no `ERL_*`, `ELIXIR_*`, `MIX_*` or `DYLD_*` variable is set. Libraries
that exist on the machine but that no object names cannot load, which the
linkage and loaded-image steps prove. On Linux the lane runs in a container of
`Dockerfile.smoke`: the pinned `ubuntu:22.04` image plus `procps` only, run as
an unprivileged UID with a temporary home, network enabled for the provider,
the host's certificate bundle bind-mounted read-only at
`/etc/ssl/certs/ca-certificates.crt` (installing `ca-certificates` would pull
in an OpenSSL), and the same two credential variables passed by name alone,
`docker run --env ANTHROPIC_API_KEY --env OPENAI_API_KEY`, so no value
enters argv, and the retained M7 root's archive that step 5 uses
bind-mounted read-only. It asserts the
same absent commands, records `dpkg -l`, and finds no `beam.smp` or `erl`
outside the install. The attended outcome-6 record on macOS uses a separate
macOS user account whose shell profile loads no mise or Homebrew.

**Steps**, each printing its elapsed time:

1. **Download and verify.** Check the archive with its `.sha256`. On macOS,
   set `com.apple.quarantine` (`0083;<hex now>;Safari;`) on the archive and,
   after `tar -xzf`, on every extracted entry, as a browser download and
   Archive Utility would leave them. Run `/bin/sh bin/loopex-verify`. On
   macOS run the documented `xattr -dr` and assert that `xattr -lr` shows no
   quarantine attribute. Move the tree to the documented location.
2. **Linkage and loaded images.** Run `assert-linkage.sh <platform> <root>
   --smoke`. Run a lane-written escript through the bundled
   `erts-*/bin/escript` that loads `crypto`, starts `ssl` and calls
   `public_key:cacerts_get/0`, under `DYLD_PRINT_LIBRARIES=1` on macOS or
   `LD_DEBUG=files` on Linux. Every loaded image must lie under the install,
   `/usr/lib/` or `/System/Library/` on macOS, or `/lib/x86_64-linux-gnu/`,
   `/usr/lib/x86_64-linux-gnu/` or `/lib64/` on Linux, and the reported
   OpenSSL must equal the manifest's. `loopex version` must equal the
   manifest header.
3. **Home and configuration.** Initialize the home with ADR 0037's `init`,
   configure two admitted provider environment references and exact model
   choices over ADR 0049's schema, validate, inspect origins and run the
   diagnostic command. No file credential or unaccepted provider-selection
   grammar is assumed.
4. **Converse through the service.** `loopex run` through the home's socket
   with no daemon running starts the service on demand under ADR 0037 and
   completes one real provider session. Detach, attach as observer with
   `attach --observe`, take control, and stop the service with ADR 0037's stop
   command. Start again on demand; list and resume the session; complete it.
   The status and diagnostic commands report readiness without resolving a
   credential. Every step uses the installed command.
5. **Backup, restore and refusal.** Stop the service, take a backup with
   `loopex store backup`, restore it into an empty root with
   `loopex store restore`, point the home at the restored root, start the
   service and list its sessions. Extract ADR 0072's
   [retained M7 root](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-m7-fixture),
   written by the `v0.4.0` build (D24), from the fresh-source extraction (on
   Linux, from its read-only mount) after checking its pinned digest, point the installed command at it, and
   prove ADR 0072's named `root_unmarked` refusal and a byte-identical root.
6. **Replace and remove.** Run the verifier again: it passes, proving that
   nothing wrote into the install. Stop the service, replace the install
   with a fresh verified extraction of the same archive by the upgrade
   sequence, start it and list the same sessions. Remove it by the uninstall
   sequence: stop it, run `loopex auth logout` for each provider
   `loopex auth status` lists, delete the install directory, and prove the
   home's configuration and roots are intact and, on macOS, that no Loopex
   keychain item remains, by the read-only query
   `security find-generic-password -s loopex-oauth` over the lane's
   keychains. The Linux lane signs in to nothing, and its container has no
   `secret-tool` or session bus, so it makes no keyring query. A before-and-after
   inventory proves that nothing was written outside the home, the workspace,
   the lane's temporary directory and the provider's transient `/tmp/lxp-*`
   namespaces, which must be gone. On Linux the inventory is `find / -xdev`
   in the container less `/proc`, `/sys` and `/dev`; on macOS it is the
   invoking user's home, `/private/tmp`, `$TMPDIR` and `/Users/Shared`.

Only after step 6 passes does `smoke.sh` print its last line,
`installed-artifact: PASS steps=6`, the line the release runner's
script-lane judge requires.

**Attended record.** M8 outcome 6's attended record runs on `darwin-arm64`
in the separate macOS user account above, from a verified extraction of the
candidate's archive, by an identified operator following the operator
runbook. Every step uses the installed command and the home `init` created.
After steps 1 to 3 it runs:

1. **Reconnect.** `loopex chat --service` starts the service on demand and
   begins a task with the first pinned provider. The operator closes that
   terminal while the run is active, opens another, runs
   `loopex chat --service --resume SESSION`, and sees the transcript and the
   result, with the run identity unchanged and nothing run twice.
2. **`m8.service-review`**, ADR 0071's attended helper case. The home's
   configuration enables delegation with M7's `m7.review` fixture profile:
   roles `investigate` and `review` on the second pinned provider, the parent
   on the first. Through `loopex chat --service` the operator asks for a
   review, detaches while a helper runs, reconnects with `--resume`, and sees
   each `task` result with its role, model, child session, outcome and
   separate and combined usage. The operator then asks again and runs
   `loopex service stop` while the second helper runs, starts the service by
   reconnecting, and sees the parent's `task` call carry the stop-only result.
   `loopex service status` reports `classifying` or `serving`, never a session
   admitted before classification completes.

It then completes step 5's backup and restore, without the retained-root
refusal, which the lane's own step 5 proves, and step 6, whose removal runs
`loopex auth logout` for every route the account signed in and then
asserts that no Loopex item remains in that account's keychains, by the
same read-only query. The record names the operator, the
archive digest, both providers and each session identifier. The release
runner's `m8-operator` lane hands the account the verified archive and
retains the record's transcript, checking that it names that archive's
digest.

**Evidence retained** outside the repository, each with its SHA-256 on the
closure evidence page: the archive, its `.sha256` file and manifest copy,
`build.log`, `linkage.log`, the smoke transcript, the loaded-image report, the
clean-host assertions, the two inventories and their difference, the
`dpkg -l` list on Linux, and the attended record's transcript with its
reconnect and `m8.service-review` sections, with provider credentials
redacted.

<a id="technical-adr-0038-failures"></a>
### Failure Modes and Refusals

Concept: [Context and decision](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-decision).

| Name | Raised when | Owner | Effect |
| --- | --- | --- | --- |
| `release_platform_unsupported` | The build host is not `Darwin arm64`, or not `Linux x86_64` with Docker | `scripts/release/build.sh` | No build |
| `release_output_exists` | `<out-dir>` is missing, not empty, or inside the checkout | `scripts/release/build.sh` | No build |
| `release_source_mismatch` | The extraction's `SOURCE_IDENTITY` does not name the requested commit | `scripts/release/build.sh` | No build |
| `release_input_digest_mismatch` | A downloaded OTP, OpenSSL or Elixir input differs from its pinned digest | `scripts/release/linux/Dockerfile` | No image |
| `release_toolchain_mismatch` | Elixir, OTP, ERTS or OpenSSL differ from the pins, or the pins differ from `.tool-versions`' current pair | `scripts/release/assemble.sh` | No build |
| `release_layout_unexpected` | A symbolic link, a path outside the character set, a misplaced executable, an unknown native object, or a build-tool name or source file in the staged tree | `scripts/release/check-layout.sh`, run by `installed_layout/1` in the umbrella `mix.exs` | `mix release` fails |
| `linkage_outside_base` | A dependency outside the platform's allowed list, or a `ldd` line that is `not found` or resolves elsewhere | `scripts/release/assert-linkage.sh` | Build or lane fails |
| `linkage_search_path` | An `LC_RPATH`, `RPATH`, `RUNPATH` or `@`-relative install name | `scripts/release/assert-linkage.sh` | Build or lane fails |
| `linkage_minimum_exceeded` | A Mach-O `minos` above `15.0`, a `GLIBC_` version above `2.35`, or any `GLIBCXX_`, `CXXABI_` or `GCC_` version | `scripts/release/assert-linkage.sh` | Build or lane fails |
| `linkage_signature_invalid` | `codesign --verify --strict` fails on a Mach-O | `scripts/release/assert-linkage.sh` | Build or lane fails |
| `release_archive_mismatch` | The written archive's entry set differs from the manifest | `scripts/release/assemble.sh` | No archive |
| `platform_mismatch` | Operating system or architecture differs from `platform` | `bin/loopex-verify` | Exit `1`; nothing runs |
| `platform_minimum_unmet` | macOS below `15.0` or glibc below `2.35` | `bin/loopex-verify` | Exit `1` |
| `manifest_unreadable` | `MANIFEST` is absent or its header or a record is malformed | `bin/loopex-verify`, `loopex version` | Exit `1` |
| `install_entry_unexpected` | An entry under the root is neither a regular file nor a directory | `bin/loopex-verify` | Exit `1` |
| `install_writable_by_others` | A file or directory is group- or world-writable | `bin/loopex-verify` | Exit `1` |
| `manifest_mismatch` | A record is missing, extra, or differs in mode class, size or digest; the first path is named | `bin/loopex-verify` | Exit `1` |
| `install_incomplete` | Installed mode without exactly one `erts-*/bin/escript` or an executable `libexec/loopex` | `bin/loopex` | Exit `127` |
| `provider_artifact_unavailable` | The companion is missing, its digest differs, or the interpreter is not an executable file | `ProviderConfiguration.verify_artifact/1` (existing) | The provider call is refused before launch |
| `invalid_provider_configuration` | The embedded launch pair mixes relative and absolute paths | `ProviderConfiguration.validate/1` (existing) | The provider call is refused |
| `clean_host_violation` | A toolchain command or variable is present in the smoke environment | `scripts/release/smoke.sh` | Lane fails |
| `loaded_image_outside_base` | The loaded-image probe shows an image outside the allowed locations | `scripts/release/smoke.sh` | Lane fails |
| `install_written` | The verifier fails after the workflow | `scripts/release/smoke.sh` | Lane fails |
| `outside_write` | The inventories differ outside the permitted locations | `scripts/release/smoke.sh` | Lane fails |

**Fast-check proofs.** Each refusal the fast check can reach without a
release build has a named test:

- `scripts/test/release-artifact-test.sh`, a `scripts/check.sh` step, on
  trees it writes with `write-manifest.sh`: the verifier's `PASS` on a
  supported host (`Darwin arm64` or `Linux x86_64`; elsewhere that case
  expects `platform_mismatch`), usage exit
  `2`, `--inventory` equal to the writer's records, and each of
  `platform_mismatch` and `platform_minimum_unmet` (a manifest naming the
  other platform or a minimum above the host's), `manifest_unreadable`
  (absent, bad header, bad record), `install_entry_unexpected` (a symbolic
  link, a FIFO), `install_writable_by_others` and `manifest_mismatch`
  (missing, extra, mode class, size, digest, first path named);
  `check-layout.sh`'s `release_layout_unexpected` for each listed case;
  `assert-linkage.sh`'s `linkage_outside_base`, `linkage_search_path` and
  `linkage_minimum_exceeded` on retained `otool` and `objdump` outputs under
  `scripts/fixtures/release/`, which stubs named `otool`, `lipo`,
  `codesign`, `objdump`, `readelf` and `ldd`, placed first on the `PATH`
  the test gives `assert-linkage.sh`, print; and the launcher: installed-mode selection,
  `$0` reached through a relative and an absolute symbolic link, the
  variables it unsets, `install_incomplete` exit `127` with no `escript`,
  two, or a non-executable `libexec/loopex`, and checkout mode still
  running `../loopex`.
- `apps/loopex_cli/test/provider_launch_test.exs`, through `options/2`
  with a path in a temporary tree: a relative pair is joined to the root
  two levels above that escript path, an absolute pair is returned
  unchanged, and a mixed pair is returned unchanged and
  `ProviderConfiguration.validate/1` refuses it `invalid_provider_configuration`.
- `apps/loopex_llm_reqllm/test/provider_build_test.exs` (extended):
  `--relocatable` writes the relative pair with unchanged digests, and a
  relocatable CLI run from a checkout refuses
  `provider_artifact_unavailable`.
- `apps/loopex_cli/test/version_command_test.exs`: `loopex version` prints
  the manifest header line in the installed mode, exits `1` with
  `manifest_unreadable` for a malformed header, and prints
  `loopex <VERSION> source` from a checkout.

`linkage_signature_invalid`, the build refusals and the smoke refusals run
on a real toolchain or install; the installed-artifact lane proves their
passing path.

A refused, unmarked or unknown root is ADR 0072's refusal and keeps its names
there. Deleting or replacing the install while the service runs is an operator
error the documentation forbids; the store's commit rules keep durable truth,
and restarting under the installed build recovers the service.

<a id="technical-adr-0038-compatibility"></a>
### Compatibility Mechanics

Concept: [Compatibility and rollback](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-compatibility).

**Surface 7.** The archive is the package. Its name pattern, top directory,
layout, `loopex-manifest 1` format, verifier behavior, launcher selection and
the version it declares become permanent at first publication. Nothing in it
is a separately versioned library; the applications inside are not published
to Hex and their versions are the release's. A later change that splits the
archive or changes the manifest format is a compatibility decision under the
vision's rule.

**ADR 0003.** The archive carries no build path: no Mix, Hex, `erlc`,
`elixirc`, `rebar3`, source or dependency tree, and nothing that fetches,
builds or loads an extension. The Erlang `compiler` library and Elixir's own
modules ship because the Elixir application declares and loads them. The
clarifying amendment below, decided by the maintainer, governs that reading.
Extension acquisition and installation remain deferred.

<a id="technical-adr-0038-compiler"></a>
**ADR 0003 amendment text.**

Concept: [The compiler clarification of ADR 0003](0038-installed-distribution-and-release-artifact.md#concept-adr-0038-compiler).

- **Clause amended.** ADR 0003 Technical depth, section "Exact Obligations
  and Deferred Questions"
  ([anchor](0003-extension-contract-boundary-technical.md#technical-adr-0003-decision)),
  obligation 4, second sentence: "A minimal runtime distribution carries no
  compiler, and shared-VM activation rejects loading from unvalidated paths."
- **Amended reading.** "A minimal runtime distribution carries no build
  toolchain: no Mix, Hex, `erlc`, `elixirc`, `rebar3`, source or dependency
  tree. The OTP `compiler` application may ship only as a runtime dependency
  that Elixir declares and requires to start; no Loopex code calls it to build
  or load a candidate. Shared-VM activation rejects loading from unvalidated
  paths."
- **Unchanged.** Obligation 4's first sentence ("A brain never fetches or
  compiles a candidate"), obligations 1 to 3 and 5, and every deferred
  question. ADR 0003's accepted bytes are not edited; the ADR index records
  this amendment when this record is accepted.
- **Why the application is needed.** `elixir.app` lists `compiler` in its
  `applications`, and `mix release` keeps it with mode `:load`. Without it
  the runner cannot start Elixir (measured in the build section above).
- **Proof.** The release layout check (step 5 of the release definition above)
  also raises `release_layout_unexpected` for any file named `mix`, `hex`,
  `erlc`, `elixirc` or `rebar3` and for any `.ex`, `.exs`, `.erl` or `.hrl`
  file, so no build toolchain or source enters the manifest. The `compiler`
  application's presence is expected, not refused.

**ADR 0019 and ADR 0034.** The companion remains a separate OS process behind
the Port and OS guard; the credential still crosses the private channel; the
composition-bound token resolved through host custody is unchanged. Only the
path resolution changes, and the digest verification before launch is kept.

**Recovery.** Before 1.0 there is no binary rollback or older-root upgrade,
under the maintainer's pre-1.0 current-contract rule. An unsupported root is
refused before any write, and recovery restores a backup under the build
whose format the root is in. Keeping the previous install directory until a
replacement serves is the only "switch back", and it is safe only because the
refused root was never written. No earlier build is assumed to contain a
restore command, an installed layout or the marker check.

**Rejected alternatives.**

- *Running the CLI as release code* through the release's `eval` entry would
  leave the escript form the release check's lanes test, move the
  standard-I/O encoding and signal handling off the escript path, and leave
  two copies of every application on the code path.
- *Copying the toolchain root by hand* would reimplement what `mix release`
  already does: the application closure from `.app` metadata, NIF `priv`
  copying, beam stripping and a relocatable `erl`.
- *A single native executable* (Burrito-style) adds a packer dependency, a
  self-extraction step at first run and a second launcher.
- *Hex publication* creates seven package surfaces at once and welds their
  versions; no consumer justifies it.
- *Service-manager installation* is host policy and a later milestone.
- *Homebrew or distribution packaging* depends on publication and on name
  clearance; it is not `0.5.0` scope.
- *A release without ERTS* would require an installed Erlang of the exact
  version and could not claim "no toolchain required".
- *Building from the development toolchain* is refused by measurement:
  Homebrew's OTP links its crypto library to Homebrew's OpenSSL (2026-09-21),
  and the Linux host's runtime links glibc 2.44 and dynamic OpenSSL, brotli,
  zstd and ncurses.
- *A JSON manifest checked by the release's own runtime* cannot run before the
  macOS quarantine step; a line format a shell script can check can.
- *A curl-piped install script* is a publication-time convenience and follows
  name clearance.

**Decided on 2026-10-13 by the maintainer.** The release label `0.5.0` with
`VERSION` advanced in the M8 candidate before its tested runs; the two
platforms; macOS 15.0 on Apple silicon using the precompiled Erlang/OTP 29.0.5
runtime mise installs; Linux x86-64 with a glibc 2.35 base built from source
in an `ubuntu:22.04` container with OpenSSL 3 linked statically, never from
the build host's runtime; the macOS quarantine-removal step after manifest
verification, without signing or notarization; and current-format roots only,
with recovery by backup and restore under the matching build; and the
clarifying reading of ADR 0003's "no compiler" as "no build toolchain", with
the OTP `compiler` application shipped as a runtime dependency of Elixir.

**Open for the maintainer.** None for M8. Publication, which this ADR does not
authorize, additionally needs public-name clearance and the third-party licence
notices for ERTS, Elixir, OpenSSL and the Hex dependencies that redistribution
requires.
