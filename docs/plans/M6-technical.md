<a id="technical-depth"></a>
## Technical depth

Concept: [M6 installed durable operator](M6.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](M6.md#concept-plan-purpose).

Concept: [Design decisions](M6.md#concept-plan-decisions).

Concept: [Non-goals](M6.md#concept-plan-non-goals).

M6 waits on three decisions and one closure. Each decision is accepted before
the implementation that depends on it, not before unrelated work, and none
may be outstanding at closure. Acceptance binds a design and its evidence
obligations, not the evidence itself; the obligations are discharged at
outcome closure. The repository status check reads the links in this
section, so a decision named only in prose declares nothing.

| Decision | Acceptance point | What its acceptance settles |
| --- | --- | --- |
| [ADR 0036](../adr/0036-daemon-grade-store-engine-and-migration.md#concept) | Before any adapter, migration, backup or restore code is written; its engine cell is filled from the retained experiment record first | Outcomes 3 and 6: the engine, the migration contract, the reader boundary, backup and restore, the definite capacity refusal |
| [ADR 0037](../adr/0037-host-configuration-and-path-discovery.md#concept) | Before the configuration layer, the default home or any lifecycle command is written | Outcomes 2 and 4: the schema, precedence, provenance, writes, the ADR 0003 amendment |
| [ADR 0038](../adr/0038-installed-distribution-and-release-artifact.md#concept) | Before any release build, manifest, launcher change or install lane is written | Outcomes 1 and 5: the archive, the launcher promotion, the companion placement, the manifest, the platforms, the install and rollback contract |

**The closure prerequisite.** M5 must close first: the register admits M6 as
an `Open` successor beside an `Accepted` M5 and refuses to accept M6 before M5
is `Closed`. Every M6 fixture starts from the exact `0.2` root layout, daemon
and workflow M5's tested candidate proves, so writing M6 code against an
unclosed M5 would bind it to bytes that can still change.

**Deferrals.** ADR 0035 remains Proposed and wholly deferred; no M6 outcome
waits on it and M6 runs no part of it. Publication of `0.3.0` is a separate
maintainer decision after closure and is gated on public-name clearance,
which is not a repository artifact.

<a id="technical-plan-ownership"></a>
### Ownership and Rejoin

Concept: [Scope](M6.md#concept-plan-scope).

| Workstream | Owns | Depends on | Rejoin order |
| --- | --- | --- | --- |
| A. Distribution | `mix.exs` release configuration, `apps/loopex_cli/bin/loopex` release branch, the provider build task's relative paths and `ProviderConfiguration` resolution, `MANIFEST.json` and checksum production, `loopex version` | ADR 0038 | First: the artifact is what every later lane runs |
| B. Configuration and lifecycle | The configuration module family in `apps/loopex_cli`, `init`, `config`, `paths`, `doctor`, `daemon status`, exit classes | ADR 0037 | Second: `doctor` and `store` commands report the adapter's facts, so B lands its grammar before C fills the store rows |
| C. Store adapter and migration | The new adapter application, the format version, `store migrate`, `backup`, `restore`, the definite capacity refusal on both adapters, the listing-index rebuild | ADR 0036 with its engine cell filled | Third |
| D. Documentation | The operator guide from a downloaded archive, the developer pages M6 changes, the closure evidence scaffold | A, B, C as they land | Last |

One integrator owns rejoin, conflicts and post-rejoin verification. Parallel
writers use one worktree each with non-overlapping paths. The single
acceptance demonstration script is written by the integrator before A lands
and is the rejoin check for every workstream.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M6.md#concept-plan-outcomes).

Concept: [How each outcome is verified](M6.md#concept-plan-verification).

| # | Witness files | What they prove | Lane |
| --- | --- | --- | --- |
| 1 | `apps/loopex_cli/test/launcher_release_test.exs` (new), `apps/loopex_cli/test/release_manifest_test.exs` (new), `apps/loopex_llm_reqllm/test/provider_relocation_test.exs` (new); `scripts/check-release.sh` installed-artifact lanes | The launcher's release branch preserves the interrupt contract and the checkout branch; the manifest lists every file with a digest that `version --verify` recomputes; the companion launches from a relocated release root and refuses a digest mismatch; a toolchain-free host runs the archive | fast; release |
| 2 | `apps/loopex_cli/test/config_schema_test.exs` (new), `apps/loopex_cli/test/config_precedence_test.exs` (new), `apps/loopex_cli/test/config_write_test.exs` (new) | Closed schema with exact-path refusals and version refusal; precedence per value with origin; atomic replacement, lock reclaim and prior-file preservation under a forced failed write; the effective view redacts references; the same effective configuration after restart | fast |
| 3 | The shared Store conformance suite and fault matrix run on the new adapter; `apps/<adapter>/test/open_replay_bounds_test.exs` (new), `apps/<adapter>/test/capacity_refusal_test.exs` (new) on both adapters, `apps/<adapter>/test/migration_test.exs` (new) with the interrupted-migration matrix, `apps/<adapter>/test/backup_restore_test.exs` (new) | Conformance and fault answers identical to the local adapter; open and replay within the stated bounds on the largest fixture; the definite refusal is definite on every adapter under every injection; convergence from every forced cut; restore verifies every digest and refuses a non-empty target | fast; the largest fixture in the release check's long-duration lane |
| 4 | `apps/loopex_cli/test/lifecycle_commands_test.exs` (new), the exit-status map cases in the M5 daemon suite extended | Each command's grammar, output and exit class; every diagnosis named in the outcome is produced from the command output alone | fast |
| 5 | `scripts/check-release.sh` installed-artifact lanes on both platforms | The M5 workflow through the installed command with the real provider, detach, observer attach, takeover, restart, list, resume, completion | release |
| 6 | `apps/<adapter>/test/reader_boundary_test.exs` (new); the installed-artifact lane's migrate, run, restore-under-previous-release, run sequence | The `0.2` reader refuses `0.3` by name and writes nothing; the `0.3` reader opens `0.2` read-only for `doctor` and listing; the pre-migration backup serves its sessions under the previous release | fast; release |

**Evidence rules.** Every derived number in this plan, the open and replay
bounds, the fixture sizes and the exit-class values, has an executed witness
before closure. Case names stay under 255 bytes. Every release lane retains
its complete output outside the repository with a stable reference and a
SHA-256 digest, recorded in `docs/evidence/M6-closure-runs.md`, which the
tested candidate creates and indexes as a scaffold.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

| Surface | M6 change | Label |
| --- | --- | --- |
| Private journal and store schema | New container format with a format version; record content and public event families unchanged | Private; migrated explicitly |
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

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

The vision's migration list, discharged:

| Item | M6 answer |
| --- | --- |
| Supported source and target versions | `0.2` roots to `0.3` roots, one direction |
| Forward migration | `loopex store migrate`, explicit, offline, idempotent, verified before publish, source retained |
| Interrupted-migration detection and recovery | A marker written first and removed last; every forced cut converges on the next run; the matrix in ADR 0036 |
| Backup and restore or downgrade policy | `store backup` and `store restore`; restore is the downgrade |
| Previous-binary reopening boundary | `0.2` refuses `0.3` with `store_format_unsupported` and writes nothing |
| Extension-state fixtures | Not applicable; no extension state exists |
| Exact packaged rollback procedure | Switch back to the previous release directory and restore the pre-migration backup; proved in the installed-artifact lane in that order |

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

Add exactly one application, the store adapter ADR 0036 names, with role
`:store`, depending inward on core only; the dependency budget's inventory and
cases change in the same reviewed change. If ADR 0036 selects SQLite, the
native dependency enters that application alone and the release build for
each platform compiles it on that platform; core's dependency list stays
`:telemetry` alone either way. Add the `mix release` configuration at the
umbrella root, with ERTS included and the application list drawn from the
role table. `VERSION` moves to `0.3.0`. The M5 source archive, its
`SOURCE_IDENTITY` and `scripts/source-archive-manifest.sh` are reused
unchanged; the release build runs only from such an extraction.

**Minimalism budget.** Every new module names the concrete command or
contract it serves. No configuration framework, no schema library, no packer
and no service layer enters the tree; the schema is one closed map validated
by direct code, the manifest is one JSON document produced by one script,
and the launcher change is one branch in an existing shell script.
