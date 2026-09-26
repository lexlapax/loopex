<a id="technical-depth"></a>
## Technical depth

Concept: [M7 installed durable operator](m7-installed-durable-operator.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](m7-installed-durable-operator.md#concept-plan-purpose).

Concept: [Design decisions](m7-installed-durable-operator.md#concept-plan-decisions).

Concept: [Non-goals](m7-installed-durable-operator.md#concept-plan-non-goals).

M7 waits on three decisions and one closure. Each decision is accepted before
the implementation that depends on it, not before unrelated work, and none
may be outstanding at closure. Acceptance binds a design and its evidence
obligations, not the evidence itself; the obligations are discharged at
outcome closure. The repository status check reads the links in this
section, so a decision named only in prose declares nothing.

| Decision | Acceptance point | What its acceptance settles |
| --- | --- | --- |
| [ADR 0036](../adr/0036-daemon-grade-store-engine-and-migration.md#concept) | Before any format marker, reader boundary, backup or restore code is written; its engine cell is filled from the retained experiment record first, so the experiment harness is workstream C's first task and is not adapter code | Outcomes 3 and 6: the engine the successor builds, the marker, the reader boundary, backup and restore; the migration contract and the definite capacity refusal as the successor's obligations |
| [ADR 0037](../adr/0037-host-configuration-and-path-discovery.md#concept) | Before the configuration layer, the default home or any lifecycle command is written | Outcomes 2 and 4: the schema, profiles and roles, the two credential reference forms, precedence, provenance, writes, the ADR 0003 amendment |
| [ADR 0038](../adr/0038-installed-distribution-and-release-artifact.md#concept) | Before any release build, manifest, launcher change or install lane is written; its build-environment section is filled with the retained toolchain build recipe and the allowed base-library set per platform first | Outcomes 1 and 5: the archive, the build environment, the launcher promotion, the companion placement, the manifest, the platforms and their minimum base, the install and rollback contract |

**The closure prerequisite.** M6 closes first. Every M7 fixture starts from the
local store's unchanged `0.2` root layout, the M5 daemon and workflow, and
the M6 profiles and command forms that closed baseline proves.

**Deferrals.** ADR 0035 remains Proposed and wholly deferred; no M7 outcome
waits on it and M7 runs no part of it. Publication of `0.4.0` is a separate
maintainer decision after closure and is gated on public-name clearance,
which is not a repository artifact.

<a id="technical-plan-ownership"></a>
### Ownership and Rejoin

Concept: [Scope](m7-installed-durable-operator.md#concept-plan-scope).

| Workstream | Owns | Depends on | Rejoin order |
| --- | --- | --- | --- |
| A. Distribution | The release toolchain build recipes and build-environment definitions under `scripts/release/`, `mix.exs` release configuration, `apps/loopex_cli/bin/loopex` release branch, the provider build task's relative paths and `ProviderConfiguration` resolution, `MANIFEST.json` and checksum production, the linkage assertion, `loopex version` | ADR 0038 | First: the artifact is what every later lane runs |
| B. Configuration and lifecycle | The configuration module family in `apps/loopex_cli`, `init`, `config`, `paths`, `doctor`, `daemon status`, `daemon stop`, `daemon logs`, start-on-demand in the session commands, exit classes | ADR 0037 | Second: `doctor` and `store` commands report the store's facts, so B lands its grammar before C fills the store rows |
| C. Store readiness | The ADR 0036 experiment harness and retained record, the format marker, the reader boundary, `store backup`, `store restore`, all in `apps/loopex_store_local` and `apps/loopex_cli`; no new application | ADR 0036 with its engine cell filled | Third |
| D. Documentation | The operator guide from a downloaded archive, the developer pages M7 changes, the closure evidence scaffold | A, B, C as they land | Last |

One integrator owns rejoin, conflicts and post-rejoin verification. Parallel
writers use one worktree each with non-overlapping paths. The single
acceptance demonstration script is written by the integrator before A lands
and is the rejoin check for every workstream.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](m7-installed-durable-operator.md#concept-plan-outcomes).

Concept: [How each outcome is verified](m7-installed-durable-operator.md#concept-plan-verification).

| # | Witness files | What they prove | Lane |
| --- | --- | --- | --- |
| 1 | `apps/loopex_cli/test/launcher_release_test.exs` (new), `apps/loopex_cli/test/release_manifest_test.exs` (new), `apps/loopex_llm_reqllm/test/provider_relocation_test.exs` (new), `scripts/release/assert-linkage.sh` (new) with its fixture test; `scripts/check-release.sh` installed-artifact lanes | The launcher's release branch preserves the interrupt contract and the checkout branch; the manifest lists every file with a digest that `version --verify` recomputes; the companion launches from a relocated release root and refuses a digest mismatch; every shared object and the emulator in the archive resolve only inside the archive or to the platform's allowed base set; a host with no toolchain and no third-party OpenSSL runs the archive through a real provider call | fast; release |
| 2 | `apps/loopex_cli/test/config_schema_test.exs` (new), `apps/loopex_cli/test/config_precedence_test.exs` (new), `apps/loopex_cli/test/config_write_test.exs` (new), `apps/loopex_cli/test/config_credential_test.exs` (new) | Closed schema with exact-path refusals and version refusal; profiles with a default model and role aliases; precedence per value with origin, `--provider` and `--role` included; atomic replacement, lock reclaim and prior-file preservation under a forced failed write; the effective view redacts references; a file reference refuses a wrong mode, owner, size or a symbolic link and is re-read per invocation; the same effective configuration after restart | fast |
| 3 | `apps/loopex_store_local/test/format_marker_test.exs` (new), `apps/loopex_store_local/test/backup_restore_test.exs` (new); the ADR 0036 experiment harness under `apps/loopex_store_local/experiments/` with its retained record referenced from the ADR | The marker is written last on first `0.4` open and never rewritten; a root without a marker is a `0.2` root; backup produces one archive whose manifest lists every file with size and SHA-256; restore verifies every digest and refuses a non-empty or live target; the experiment record carries the measurements ADR 0036 names on both toolchain pairs | fast; the experiment once per pair before ADR 0036 acceptance |
| 4 | `apps/loopex_cli/test/lifecycle_commands_test.exs` (new), `apps/loopex_cli/test/daemon_on_demand_test.exs` (new), the exit-status map cases in the M5 daemon suite extended | Each command's grammar, output and exit class; every diagnosis named in the outcome is produced from the command output alone; two clients starting the daemon at once yield one daemon and both proceed; a client whose start loses the placement lock attaches to the winner; `daemon stop` performs the M5 drain and `daemon logs` prints only the bounded redacted log | fast |
| 5 | `scripts/check-release.sh` installed-artifact lanes on both platforms | The M5 workflow through the installed command with the real provider, detach, observer attach, takeover, restart, list, resume, completion | release |
| 6 | `apps/loopex_store_local/test/reader_boundary_test.exs` (new); the installed-artifact lane's backup, switch to the previous release, restore, run sequence | The `0.4` reader refuses a marker naming an unknown format with `store_format_unsupported` and writes nothing; the `0.2` binary opens a root `0.4` has written; a backup taken under `0.4` restores under the previous release and serves its sessions | fast; release |

**Evidence rules.** Every derived number in this plan, the open and replay
bounds, the fixture sizes and the exit-class values, has an executed witness
before closure. Case names stay under 255 bytes. Every release lane retains
its complete output outside the repository with a stable reference and a
SHA-256 digest, recorded in `docs/evidence/M7-closure-runs.md`, which the
tested candidate creates and indexes as a scaffold.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Rollout and compatibility](m7-installed-durable-operator.md#concept-plan-rollout).

| Surface | M7 change | Label |
| --- | --- | --- |
| Private journal and store schema | Unchanged; a format marker file is added beside the log and ignored by `0.2` | Private; unchanged |
| Public session protocol | None; generation 2 served unchanged | Experimental, unchanged |
| Executor protocol | None | Unchanged |
| Embedded Elixir API | None; the composition's required options and refusals are unchanged | Unchanged |
| Configuration schema | New, `schema_version` 1 | Experimental |
| Released archive contents | New, surface 7 in the vision's list; inert until publication | Experimental, permanent at first publication |
| Toolchain | Releases built on the current pair; the floor pair still passes the fast check | Unchanged |

The released offline commands keep reading `LOOPEX_HOME` and flags exactly as
today when no home is initialized, so every documented M2 to M5 invocation
still works from a source tree.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Rollout and compatibility](m7-installed-durable-operator.md#concept-plan-rollout).

The vision's migration list, discharged:

| Item | M7 answer |
| --- | --- |
| Supported source and target versions | `0.2` roots open unchanged under `0.4`; there is no `0.4` root format |
| Forward migration | None in `0.4.0`; the marker names the current format so the successor's `store migrate` has a boundary to start from |
| Interrupted-migration detection and recovery | Not applicable in `0.4.0`; the successor's contract is ADR 0036's marker-first, remove-last rule and its matrix |
| Backup and restore or downgrade policy | `store backup` and `store restore` on the closed root; a backup restores under either release |
| Previous-binary reopening boundary | `0.2` opens a root `0.4` has written because the format is unchanged; `0.4` refuses a marker naming a format it does not know with `store_format_unsupported` and writes nothing |
| Extension-state fixtures | Not applicable; no extension state exists |
| Exact packaged rollback procedure | Switch back to the previous release directory; if the root was damaged, restore the backup; proved in the installed-artifact lane in that order |

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Rollout and compatibility](m7-installed-durable-operator.md#concept-plan-rollout).

No new application and no new dependency in any application: the marker,
the reader boundary, backup and restore live in `apps/loopex_store_local` and
the commands in `apps/loopex_cli`. If the maintainer pulls the ADR 0036
adapter into M7 at acceptance, exactly one application is added with role
`:store`, depending inward on core only, and the dependency budget's
inventory and cases change in the same reviewed change; if that adapter is
SQLite, the native dependency enters that application alone and each
platform's release build compiles it on that platform. Core's dependency list
stays `:telemetry` alone either way. Add the `mix release` configuration at
the umbrella root, with ERTS included and the application list drawn from the
role table. The release toolchain is built by retained recipes under
`scripts/release/`, one per platform, each producing an OTP whose crypto and
SSL link statically and whose emulator needs no terminal library, inside the
build environment ADR 0038 fixes; the ordinary development toolchain is not a
release toolchain. `VERSION` moves to `0.4.0`. The M5 source archive, its
`SOURCE_IDENTITY` and `scripts/source-archive-manifest.sh` are reused
unchanged; the release build runs only from such an extraction.

**Minimalism budget.** Every new module names the concrete command or
contract it serves. No configuration framework, no schema library, no packer
and no service layer enters the tree; the schema is one closed map validated
by direct code, the manifest is one JSON document produced by one script,
the build recipes are shell scripts that invoke the toolchain's own build,
and the launcher change is one branch in an existing shell script.
