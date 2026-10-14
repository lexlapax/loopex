<a id="technical-depth"></a>
## Technical depth

Concept: [M8 installed durable operator](M8.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](M8.md#concept-plan-purpose).

Concept: [Design decisions](M8.md#concept-plan-decisions).

M7 is Closed. Its closure row names tested implementation commit
`70ed6675`, and tag `v0.4.0` names administrative closure commit `9fe9618b`;
`VERSION` still reads `0.3.0`. Its implemented schema,
wire generations, provider custody, host ledger, record inventory, restore
transition and source identity are M8's baseline, as delivered rather than as
planned.

Each decision below is accepted before the implementation that depends on it,
not before unrelated work. None leaves a value to be fixed at acceptance.

| Decision | Outcomes | Accepted text it amends or clarifies | Acceptance point |
| --- | --- | --- | --- |
| [ADR 0037](../adr/0037-host-configuration-and-path-discovery.md#concept) | 2, 4; the `--service` start for 5 | [ADR 0003](../adr/0003-extension-contract-boundary.md#concept): one home-reading exception for `LoopexCli.Home`. [ADR 0049](../adr/0049-explicit-host-configuration.md#concept): `--config` optional when a home is selected. Reuses ADRs 0031, 0032 and 0046 | Before `LoopexCli.Home`, the configuration writers, `ServiceStart`, `Service`, `paths`, `doctor` or `daemon.readiness` |
| [ADR 0038](../adr/0038-installed-distribution-and-release-artifact.md#concept) | 1, 6; the installed refusal and restore step of 7 | [ADR 0003](../adr/0003-extension-contract-boundary.md#concept) obligation 4: "no compiler" read as "no build toolchain". Applies [ADR 0019](../adr/0019-host-owned-provider-protection.md#concept) and ADR 0034 to the relocated companion unchanged | Before the release definition in the umbrella `mix.exs`, `scripts/release/`, the launcher's installed mode, `loopex-verify`, `--relocatable` or `loopex version` |
| [ADR 0071](../adr/0071-daemon-attached-conversation.md#concept) | 4 (the service's configuration reader), 5 | [ADR 0049](../adr/0049-explicit-host-configuration.md#concept): nullable `trace` and `policy` in the status record. [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept): the activation ceiling, which counts helper children as decided on 2026-10-13, with any consequent [ADR 0046](../adr/0046-child-session-tool.md#concept) refusal-order clause ADR 0071 states. [ADR 0055](../adr/0055-remote-session-creation-options.md#concept): creation options on a helper-enabled service. Applies ADRs 0033, 0046, 0056 and 0069 | Before `daemon --config`, `AttachedChat`, `DaemonSession`, `ChatProjection`, the `ExitStatus` block 111 to 115, or any helper-parent creation in the daemon |
| [ADR 0072](../adr/0072-store-readiness-marker-backup-and-restore.md#concept) | 3, 7 | [ADR 0051](../adr/0051-current-format-physical-restore.md#concept), three clauses: the absence of a backup CLI, the latest-backup-only restriction relaxed by `--discard-later-work` for a lost source, and manifest walks stopping on a host-supplied credential-directory identity (major device, inode and filesystem path) or on a mount inside the walked tree (on Linux one the mount table lists; on macOS a device change), or on a FUSE filesystem or an overlay over credential storage at or above the walked root (D21), passed through a new `Restore.restore/3` (D19). Takes the operator backup and restore work out of Proposed ADR 0036 | Before `RootFormat`, the marker checks in `Placement` and `compose/1`, `StoreAdmin`, `LoopexCli.Store`, the `RestoreCodec` discard form or the `ExitStatus` block 116 to 119 and 124 |
| [ADR 0073](../adr/0073-provider-oauth-sign-in.md#concept) | 8; the sign-in precheck in 4 and the sign-in hint in 5 | [ADR 0018](../adr/0018-provider-attempt-authority-and-recovery.md#concept), [ADR 0021](../adr/0021-compacted-provider-accounting-provenance.md#concept) and [ADR 0043](../adr/0043-context-compaction-checkpoint.md#concept): the clauses ADR 0073 names for the sign-in refusal and the `chatgpt:` summary ceiling. [ADR 0019](../adr/0019-host-owned-provider-protection.md#concept): the host-held access token and the `token_exchange` invocation. [ADR 0029](../adr/0029-bounded-provider-failure-diagnostics.md#concept): the public `provider_sign_in_required` reason. [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept): custody rotation by a host refresher. [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept): sign-in routes resolve from composition-owned custody. [ADR 0048](../adr/0048-host-provider-routing-and-credential-bindings.md#concept): the `oauth` form, `vertex` members and same-account live rotation. [ADR 0049](../adr/0049-explicit-host-configuration.md#concept): the `oauth` binding form and `vertex` members as additive members of schema version 1. Also one sentence of Proposed ADR 0037 and this plan's credential non-goal. Its own decision 3 states the `adc` source as an explicit exception (D20) | Before any `SignIn.*` module, binding-grammar change, Core category admission, schema or vector change, `loopex auth`, or the `ExitStatus` block 120 to 123 |

Accepted decisions constrain M8 without being reopened beyond those named
amendments: [ADR 0051](../adr/0051-current-format-physical-restore.md#concept)
owns the restore transition, its inputs, limits and outcomes;
[ADR 0066](../adr/0066-owned-artifact-transfer-opening.md#concept) owns
transfer accounting; and
[ADR 0070](../adr/0070-pre-1-superseded-surface-retirement.md#concept) owns
the retired surfaces.

The store engine decision (ADR 0036) and typed policy inputs (ADR 0035) are not
M8 prerequisites and are deliberately not linked here; the first follows from
the accepted proposal P2. No typed policy input, API-key file or command
source, or publication enters through these prerequisites. Public-name
clearance remains a separate decision.

<a id="technical-plan-ownership"></a>
### Ownership and Rejoin

Concept: [Workstreams](M8.md#concept-plan-workstreams).

Paths are relative to the repository root; tests named in the
[evidence mapping](#technical-plan-evidence) belong to the workstream that
owns the code they prove. A path in two rows below is a shared file: the
integrator owns it, and the second change lands at rejoin.

| Workstream | Owns | Rejoins at |
| --- | --- | --- |
| W1 Integration | `apps/loopex_cli`: `Home`, `ConfigWriter`, `ConfigOptions`, `ConfigInspection`, `ConfigFile`, `ServiceStart`, `Service`, `Live`, `Daemon`, `HostOptions`, `Chat`, `ChatDriver`, `ChatProjection`, `ChatControl`, `AttachedChat`, `DaemonSession`, `DaemonClient` and the `LoopexCli` dispatch table. `apps/loopex_daemon`: `Command`, `ExitStatus`, `Service`, `ServiceReadiness`, `Request`, `SocketConnection`, `WireRecords`, `Owner`, `ConnectionRegistry`. `apps/loopex_protocol/priv/schema` and `priv/vectors`, `clients/node`. `LoopexComposition.Placement`'s lock primitive extraction. `LoopexComposition.Delegation.Helper`'s classification code (ADR 0072's readiness code). `VERSION` at the candidate | The first installed workflow |
| W2 Daemon helpers (W1's integrator, after the attached conversation) | `LoopexCli.ChatConfiguration`'s split into `helper_roles/1`, `helper_catalog/3` and `helper_parent_genesis/3`; `LoopexCli.HostOptions.helpers/1`; `LoopexComposition.Delegation.create_parent_detailed/7`, `host/5` and `Helper.create_parent/2`; `Loopex.Runtime.create_session_with_genesis_detailed/4`; helper hosting and activation counting in `LoopexDaemon.Service`, `Owner`, `ConnectionRegistry` (its one counted sum, `activations_counted/1`, used by client admission, the helper permit and the status report) and `SocketConnection.create_task/4` | After the first installed workflow, before the installed demonstration |
| W3 Packaging | The umbrella `mix.exs` `releases/0` and `installed_layout/1`; `scripts/release/` (`toolchain.env`, `build.sh`, `assemble.sh`, `write-manifest.sh`, `assert-linkage.sh`, `smoke.sh`, `linux/Dockerfile`, `linux/Dockerfile.smoke`); `apps/loopex_cli/bin/loopex` and `bin/loopex-verify`; `apps/loopex_llm_reqllm/lib/mix/tasks/loopex.provider.build.ex`'s `--relocatable`; `LoopexCli.ProviderLaunch.options/0`; the `loopex version` module; the `installed-artifact` lane in `scripts/check-release.sh` | The first installed workflow, with a locally built archive |
| W4 Backup and restore | `LoopexComposition.RootFormat`, `StoreAdmin`, `StoreAdmin.Codec`; the marker step in `Placement.acquire/2` and `LoopexComposition.compose/1`; `Restore.IO`'s `root_inventory` and `backup_copy` operations; `Restore.restore/3` and `Restore.IO.run/3`'s `:guard` option; `SignIn.Separation.identities/1`, `mount_table/1`, `location/2`, `mount_class/1`, `overlay_backing/1` and `mount_list/1`; `Restore.Audit`'s session-identifying failure; `Restore.Workflow`'s discard-form validation; `Loopex.Executor.Local.RestoreCodec`'s discard form; `LoopexCli.Store` and the marker checks for `sessions` and `artifact`; the `bind_mount` lane in `scripts/check-release.sh` (D18) | The marker first, before W1's daemon and CLI changes; adopt, backup and restore after the first installed workflow, before the installed demonstration |
| W5 Provider sign-in | `apps/loopex_llm_reqllm`: `Loopex.LLM.ReqLLM.SignIn.*`, the `Guards` provider table, `HostBindings`, `NativeRequest`'s per-route header seal, the `chatgpt` mapping, `drain/5`'s reply ceiling, `in_process.ex`'s sign-in resolution and the companion's `token_exchange` kind. `apps/loopex_composition`: `LoopexComposition.SignIn.*` (store, backends, refresh lock, `Route` edge), the credential plane's registration of sign-in custody, and `test/support/fake_oauth_server.ex`. `apps/loopex` (Core): the `provider_sign_in_required` admission in `SessionCoordinator`, `ProviderAttempt` and `SessionState`. `apps/loopex_protocol`: `Session.Outcome` and `Session.CompactResult`. `apps/loopex_cli`: `LoopexCli.Auth` and its sign-in hint function. The `real-sign-in-*`, `secret_service` and `macos_keychain` lanes in `scripts/check-release.sh` (D18) | After the first installed workflow and after W1's `daemon.readiness` schema change; before the installed demonstration |

Shared files and their single owner:

- `LoopexDaemon.ExitStatus` and `apps/loopex_daemon/test/command_test.exs`:
  W1. Each ADR's block lands with its ADR, in this order: 111 to 115 (114 retired), then
  116 to 119 and 124, then 120 to 123, each block once its ADR is accepted.
- `apps/loopex_protocol/priv/schema`, `priv/vectors`, the pinned digest in
  `LoopexCli.DaemonClient`, `clients/node/contract-manifest.mjs` and
  `clients/node/daemon-client.mjs`: W1. `daemon.readiness` lands first; W5's
  failure reason rebases on it and the integrator lands the regenerated
  manifests and schema proof.
- `LoopexComposition.Placement`: W1 extracts the lock primitive into one
  shared private module before anything else uses it; W4 then owns
  `Placement.acquire/2`'s marker step; W5's refresh lock and W1's
  configuration-writer lock call the primitive.
- The `LoopexCli` dispatch table, `scripts/check-release.sh` lane list and
  `scripts/check.sh`: W1 wires each workstream's entry module or lane at its
  rejoin. The lane list is the integrator's duty under D18: `--only` accepts
  `installed-artifact`, `bind_mount`, `secret_service` and `macos_keychain`;
  `bind_mount` and `secret_service` refuse a selection on a host other than
  Linux and `macos_keychain` on a host other than macOS, as `cross_uid` does;
  the full matrix runs `macos_keychain` on macOS, and each tagged lane must
  execute its named case count, so a run with none reports evidence
  unavailable, never a pass.
- The chat, attached chat and `ask` sign-in hint: W5 provides the line in
  `LoopexCli.Auth`; W1 calls it from the drivers at W5's rejoin.
- `LoopexCli.ServiceStart`'s precheck of sign-in routes: W1, calling W5's
  metadata reader after W5's rejoin. Until then the schema refuses `oauth`
  bindings.

Constraints that hold across workstreams:

- **One resolver.** No second configuration resolver, role schema or provider
  schema. Discovery and writers wrap ADR 0049's reader; ADR 0073's members are
  additive to schema version 1.
- **One session owner.** The attached conversation is a client. It owns no
  runtime, no durable conversation state and no alternate loop.
- **One restore.** The restore command calls
  `LoopexComposition.Restore.restore/3`, which ADR 0072 adds beside the
  delivered `restore/2` to pass its walk guard, and `lookup/3`. It adds no
  second copy, audit or transition.
- **One lock algorithm.** The configuration-writer lock (ADR 0037), the
  sign-in refresh lock (ADR 0073) and `store adopt`'s hold on the root's
  `placement.lock` (ADR 0072) use the extracted placement primitive, never
  `Placement.acquire/2`, whose first step admits a state root under ADR 0072
  and would refuse the unmarked root adopt is marking or mark a lock directory.
- **Closed schema.** The M9 capacity option needs a versioned successor to ADR
  0049's closed schema or its explicit amendment. M8 adds no capacity member.
- **Helper concurrency.** One active helper per parent conversation, with
  independent parents permitted to overlap, in the foreground and the service.
  The service adds no service-wide slot; the router's 4,096 shared rows and
  ADR 0032's activation ceiling bound it.
- **No credential in tests or logs.** Every test uses temporary `HOME`,
  `LOOPEX_HOME` and keychains; no test touches a real keyring or login
  keychain.

<a id="technical-plan-order"></a>
### Implementation Order

Concept: [Workstreams](M8.md#concept-plan-workstreams).

Each step names its first dependency; steps on one line may run in parallel
in separate worktrees.

1. **Acceptance.** The plan pair and each ADR it depends on, as listed in the
   prerequisites. Unrelated work does not wait.
2. **Foundation (W1).** Extract the placement lock primitive; add
   `ExitStatus` blocks as their ADRs are accepted.
3. **Root marker (W4)** under ADR 0072: `RootFormat`, `Placement.acquire/2`
   and `compose/1` admission, the read-only checks, daemon statuses 116 to
   119 and 124, and every existing fixture that opens a root brought to a marked root.
   **Packaging (W3)** starts in parallel under ADR 0038.
4. **Home and service (W1)** under ADRs 0037 and 0071: `Home`, writers,
   `daemon --config`, `ServiceStart`, `daemon.readiness`, `service`, `paths`
   and `doctor`, then `AttachedChat` with `DaemonSession` and
   `ChatProjection`. **Provider sign-in (W5)** starts in parallel under ADR
   0073 with the token store, refresh, routes and the reply ceiling, behind
   the fake OAuth server.
5. **First installed workflow.** W1 and W3 rejoin: install a locally built
   archive, `init`, `chat --service`, detach, reconnect, `service stop`.
6. **Daemon helpers (W2)** under ADR 0071 decision 10 and its activation
   counting. **Adopt, backup and restore (W4)**. **Sign-in rejoin (W5)**: the
   public reason in Core and the protocol, the start-on-demand precheck, the
   daemon statuses 120 to 123 and the hints.
7. **Failure matrices.** Process races, fault cuts, restart and signal cases
   for every workstream, on both toolchain pairs.
8. **Demonstration and candidate.** The closure matrix of D18: the full
   release check on macOS arm64, and on Linux x86-64 the `installed-artifact`,
   `bind_mount`, `secret_service` and `cross_uid` lanes, the attended record with `m8.service-review`, the `real-sign-in-*`
   lanes whose clients exist, `VERSION` advanced to `0.5.0`, documentation and
   the evidence scaffold.

<a id="technical-plan-inherited"></a>
### What M8 Inherits From M7

Concept: [Scope and non-goals](M8.md#concept-plan-scope).

Each delivered fact creates an obligation that its owning ADR now fixes.

| Delivered M7 fact | M8 obligation | Owner |
| --- | --- | --- |
| `loopex chat` owns a foreground durable runtime and accepts no daemon socket | Outcome 5 maps every conversation action onto a delivered `loopex.experimental/4` member and the controller lease | ADR 0071 |
| The foreground server serves only `loopex.experimental/3`; the daemon serves only `loopex.experimental/4`, whose methods include `session.acquire_control`, `session.release_control`, `session.configure` and `session.compact` | The attached command and the Node client lane use `/4`; the one addition is `daemon.readiness`, with schema, vectors and pinned digests | ADRs 0071 and 0037 |
| Daemon clients detach and reattach at a cursor without cancelling the run, proved by `m7.daemon-detach` | The attached conversation reuses that path; quitting, end of input and interrupt detach | ADR 0071 |
| The daemon's startup flags are `--state-root`, `--workspace`, `--provider-launch`, `--policy`, `--cleanup-grace-ms` and `--socket`, with environment fallbacks; it reads one credential from `LOOPEX_PROVIDER_API_KEY` into ADR 0070's one-route plane and reads no configuration file | `daemon --config FILE` reads ADR 0049's file before any lock; flags precede the file; `LOOPEX_PROVIDER_API_KEY` is discarded unread; `--provider-launch` with a file refuses 112; the provider launch comes from the build | ADR 0071 |
| The daemon opens the helper owner, classifies, recovers stop-only and guards helper history, but creates no helper parent and refuses no file | The service captures roles before any lock, freezes the catalog after placement, creates helper parents through `create_parent_detailed/7`, and counts helper children toward its activation limit | ADR 0071 |
| The foreground conversation aborts active work on quit, end of input and interrupt | Attached, the same three detach and the run continues | ADR 0071 |
| The daemon asks about a workspace `AGENTS.md` before it listens, and no flag admits project resources non-interactively | A start on demand runs with `/dev/null` input and leaves them unadmitted; `service start` at a terminal asks and passes the digest-bound `--admit-project-resources` | ADR 0037 |
| The daemon activates at most 64 sessions per lifetime | Unchanged; helper children count toward it; the refusal is shown to the operator and documented for a long-running service | ADR 0071 |
| Trace controls exist on `chat` and `ask` only; the daemon exposes none | The file's `trace` member starts the service's trace; failure exits 115; attached chat refuses trace flags | ADR 0071 |
| Durable admission stays closed until helper-history classification completes, bounded at 60,000 ms per start and resumable | Readiness reports `serving`, `classifying` with its two counts, `closed` with the named session, or `unavailable` with a code; a start waits at most 75,000 ms | ADR 0037 |
| One unreadable session history closes the durable host until the root is restored from backup | The readiness report names the session and code; `store restore --source lost` recovers it, with `--discard-later-work` for an older backup | ADR 0072 |
| ADR 0051 delivers host-embedded `LoopexComposition.Restore.restore/2` and `lookup/3`; the host owns backup creation, the capture record, plan construction and the attestation; there is no command | `store backup` produces the backup and capture record; `store restore` builds the plan from the operator's statements and calls the delivered `lookup/3` and `restore/3`, the guarded entry point ADR 0072 adds beside `restore/2` | ADR 0072 |
| Replay refuses an unknown record kind as `invalid_private_history`; a root with only the retired catalogue is refused; the Store takes its writer marker and may repair a torn tail before replay | The marker check runs before the placement lock and before composition starts a Store; `store adopt` audits an unmarked root in full before marking it | ADR 0072 |
| Per-connection transfer accounting with a 1,073,741,824-byte cumulative allowance is enforced under ADR 0066 | None | — |
| Hosted provider routes take only environment references; the public model failure is `model_call_failed` | Sign-in routes with host-held tokens, and the public `provider_sign_in_required` reason before dispatch | ADR 0073 |
| `config show` and chat's startup report give value origins from a closed set: `flag`, `env`, `file#pointer`, `default` and `committed` | A discovered file reuses `file#pointer`; inspection prints which file was selected and why; a sign-in binding shows its form and source only | ADRs 0037 and 0073 |

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M8.md#concept-plan-outcomes).

Concept: [Verification](M8.md#concept-plan-verification).

Test files are new unless marked extended. "Fast" means `bash
scripts/check.sh`; release lanes run under `bash scripts/check-release.sh
--only LANE` before a merge that changes their boundary and once in the
closure matrix. Every case uses temporary `HOME`, `LOOPEX_HOME` and
workspaces.

**Closure matrix (D18).** The full `bash scripts/check-release.sh` runs once
on the macOS arm64 candidate host. It carries the attended outcome-6 record,
`installed-artifact` for `darwin-arm64` and the `macos_keychain` lane. On the
Linux x86-64 host the same candidate runs, each with `--only` and each
required: `installed-artifact` for `linux-x86_64`; `bind_mount`, ADR 0037's
`auth_separation_bind_test.exs` cases inside
`unshare --user --map-root-user --mount`; and `secret_service`, the
`:secret_service` keyring cases under `dbus-run-session`. The Linux host also
runs the delivered `cross_uid` lane, which the
[verification guide](../process/verification.md#concept) requires for a
daemon change and the macOS full check cannot run. A lane that reports
evidence unavailable blocks closure; it is never a pass and never a deferral
without the maintainer's recorded decision. Both hosts' complete outputs are
retained.

| # | Fast-check proof | Release check |
| --- | --- | --- |
| 1 | The existing escript, provider-companion and launcher suites stay green with the relocatable launch pair; `apps/loopex_cli/test/service_start_test.exs` proves the installed command is resolved from the escript's own location | `installed-artifact` (ADR 0038): build with pinned inputs and the linkage table, manifest and verifier, a quarantined download cleared by the documented step on macOS, clean-host assertions, loaded-image probe and `loopex version`, with every Mix, Hex and Rebar step resolved from the pinned toolchain's `PATH` into writable build-only locations, on `darwin-arm64` and in a clean Ubuntu 22.04 `linux-x86_64` container. The closure matrix (D18) runs it inside the full release check on macOS and with `--only installed-artifact` on Linux |
| 2 | `apps/loopex_cli/test/home_test.exs`, `config_inspection_test.exs` (extended), `config_writer_test.exs` | Installed lane step 3 |
| 3 | `apps/loopex_composition/test/store_backup_test.exs`, `store_restore_command_test.exs` (both attestation forms, `--resume`, every refusal, the lookup answer after an unresolved result), `restore_workflow_test.exs` (extended: the restore guard through the public `Restore.restore/3`, refused before the commit, malformed guards refused `invalid_plan`, and a committed restore with cleanup pending whose cleanup walk stops and later finishes), `delegation_readiness_code_test.exs`; `apps/loopex_executor_local/test/restore_codec_test.exs` (extended); `apps/loopex_cli/test/store_command_test.exs`; `apps/loopex_daemon/test/readiness_closed_root_test.exs` | Installed lane step 5, the restore half |
| 4 | `apps/loopex_cli/test/service_start_test.exs`, `service_command_test.exs`, `service_detach_pty_test.exs`, `live_service_test.exs`, `daemon_configuration_test.exs`; `apps/loopex_daemon/test/readiness_method_test.exs`, `command_test.exs` (extended); the Node contract lane decoding `daemon.readiness`. Under ADR 0037: readiness asked while a helper classification slice is held answers within 1,000 ms with a truthful `classifying` state from a nonblocking source, without a second writer of helper truth; `service status` emits one closed JSON result from its named reads, including helper activations; the `ExitStatus` table uses every status 65 to 124 except the retired 114 exactly once | Installed lane step 4's status and diagnostic commands |
| 5 | `apps/loopex_cli/test/attached_chat_grammar_test.exs`, `attached_chat_test.exs`, `attached_chat_detach_test.exs`, `attached_chat_signal_test.exs`, `attached_chat_lease_test.exs`, `attached_chat_reconnect_test.exs`, `live_daemon_test.exs` (extended), `daemon_helpers_test.exs`, `daemon_helper_restart_test.exs`, `chat_configuration_test.exs` (extended), with ADR 0071's helper-child activation-counting cases, including the helper permit's atomic registry operation at the real `ConnectionRegistry` boundary (an activated-without-session and an unknown disposition, preserved through a post-create parent-binding failure) and the one counted sum in both directions (held permits refuse a client reservation `activation_ceiling_reached`, and client activations refuse a permit); `apps/loopex_daemon/test/helper_route_guard_test.exs` (extended); `apps/loopex/test/runtime_create_with_genesis_detailed_test.exs` | Attended: the reconnect case and `m8.service-review` in the outcome-6 record |
| 6 | — | `installed-artifact` steps 1 to 6 on each host with complete output and archive evidence; the attended record on macOS by an identified operator in a separate user account, following the runbook through install, `chat --service`, close and reconnect, `m8.service-review` (M7's `m7.review` profile through the service, a detach while a helper runs, and `service stop` during a second helper with the stop-only result after restart), backup, restore and removal |
| 7 | `apps/loopex_composition/test/root_format_test.exs` (concurrent marker publication with a deterministic gate at the link-before-unlink cut), `placement_root_format_test.exs`, `composition_root_format_test.exs`, `store_adopt_test.exs` (D17: the `adopting` marker refused by every entrypoint, `--old-writer stopped` required, a real synchronized `Placement.acquire/2` and daemon start attempted immediately after the `adopting` publication refused while adopt holds the lock and attempted immediately after the rename admitted only after adopt releases, two concurrent adopters of which exactly one proceeds, a real M7-style lock-taking writer (a separate process on the delivered `Placement.acquire/2` path, as the M7 daemon and CLI take it) refused `placement_active` while adopt holds the lock, the synthetic writers that take no lock labelled as non-cooperating writers, an old-build writer before and after the audit manifest, a kill before the rename and `root_changed` leaving `adopting`, a kill after the rename leaving a committed current root, a rerun redoing the full audit); `apps/loopex_cli/test/store_marker_entrypoints_test.exs`; `apps/loopex_daemon/test/daemon_root_format_test.exs` | Installed lane step 5: an unmarked M7-written root refused by name and byte-identical, and a backup taken by the candidate restored under it and served |
| 8 | `apps/loopex_llm_reqllm/test/sign_in_profiles_test.exs`, `sign_in_routes_test.exs`, `chatgpt_reply_ceiling_test.exs`, `provider_bridge_test.exs` (extended); `apps/loopex_composition/test/sign_in_store_test.exs`, `sign_in_refresh_test.exs`, `credential_plane_test.exs` (extended), `chatgpt_summarizer_test.exs`; `apps/loopex/test/sign_in_required_settlement_test.exs`. Under ADR 0073 these cover: ID-token signature verification against the provider's JWKS (forged, unknown-key and rotation negatives) and the validated subject paired with the token generation, refusing a mismatch in either direction after a different-account write cut and a restart before metadata publication; the ADC source and Google's refresh-response merge; one shared streaming reply ceiling proved through both the companion and the in-process caller, summarization included; and the terminal, no-accounting sign-in refusal on any legal attempt, including a route that becomes unavailable between attempts. The auth directory, the ADC directory and the state root stay physically separate under [ADR 0037's path-separation rule](../adr/0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation), refused before any token or root write, with overrides and a changed `HOME`, and under its [physical walk check](../adr/0037-host-configuration-and-path-discovery-technical.md#technical-0037-physical-walk), which `auth_separation_test.exs` proves with a credential-shaped canary; `apps/loopex_protocol/test/sign_in_required_vectors_test.exs`; `apps/loopex_cli/test/auth_command_test.exs`, `daemon_sign_in_test.exs`, `ask_sign_in_test.exs`; `apps/loopex_daemon/test/command_test.exs` (extended); the Node client decoding the new vectors. The tagged `sign_in_keychain_test.exs` (`:macos_keychain`, temporary keychain) and `sign_in_secret_service_test.exs` (`:secret_service`, under `dbus-run-session`) are excluded from the fast check and run in release lanes | `macos_keychain` in the macOS full check and `secret_service` on Linux (D18), each required to execute its cases. `bind_mount` on Linux (D18): `auth_separation_bind_test.exs` inside `unshare --user --map-root-user --mount`, real mounts (a directory subtree, a bound ADC file and a bound token file, a superseded token inode, a same-device directory bind and a `tmpfs`, each listed in the mount table) each refused before any token file is copied; under D21 an overlay at the root, or above it, whose lower directory is the ADC directory or the token directory's parent refused for backup, adopt and restore (`BACKUP` and `DESTINATION`) before any read or copy, an overlay with escaped lower directory paths, an overlay whose shown options name no lower directory path refused, an ordinary overlay root still admitted, and a FUSE mount at the root refused where the lane's host offers unprivileged FUSE, else that case reporting the evidence unavailable; and a committed restore whose cleanup meets a mount left committed with cleanup pending; a host that refuses the namespace reports evidence unavailable, which blocks closure. Attended, each gated on its provider's client: `real-sign-in-openai` (login, one `chatgpt:` conversation through the installed service, a forced refresh, logout with revocation); `real-sign-in-gemini` (the same for `vertex:` through the `loopex` and `adc` sources against a maintainer-owned project); `real-sign-in-anthropic` (refused `sign_in_unavailable` until a sanctioned registration exists; that tested refusal is the disabled route's proof under D16). Tokens are redacted from retained outputs |

ADR 0073's nine verification items (refresh-token invalidation, partner
client, allowed models, launch date, scope classification, token lifetime,
ADC field names, regional Vertex host, Anthropic's terms) each carry their
own disposition in ADR 0073; each is checked in W5 where it lands and recorded
there, and none becomes a silent default.

Under D16, closing outcome 8 requires positive proof from
`real-sign-in-openai` and `real-sign-in-gemini`. The deliberately disabled
Anthropic route is proved by its tested refusal in `real-sign-in-anthropic`,
which needs no deferral. If the OpenAI or Google client is unavailable at
closure, that lane is evidence unavailable, not a pass, and closing outcome 8
without its positive proof is a deferral that needs the maintainer's recorded
decision.

The two repository checks and the closure matrix apply unchanged. The evidence
page is `docs/evidence/M8-closure-runs.md`, created and indexed on its actual
candidate, with complete immutable outputs outside the repository.

<a id="technical-plan-open"></a>
### Open for the Maintainer

Concept: [Design decisions](M8.md#concept-plan-decisions).

These are actions with providers, not design gaps. Each gates only its
`real-sign-in-*` lane; nothing else in M8 waits on them.

1. **OpenAI client.** Confirm that Loopex registers by Sign in with ChatGPT's
   dynamic registration as a locally run open-source app, and approve the
   `agent_name_hint` it presents; if OpenAI requires a partner client, submit
   its interest form. Gates `real-sign-in-openai`.
2. **Google client.** Create Loopex's Google OAuth desktop client in a
   maintainer-owned Google Cloud project and decide when to pass verification
   for the `cloud-platform` scope. Until verification, users see an
   unverified-app screen, the app is capped at 100 users, and in Testing status
   refresh tokens expire after 7 days. The `adc` source does not need it.
   Gates the `loopex`-source half of `real-sign-in-gemini`.
3. **Anthropic sanction.** Ask Anthropic whether it will sanction an OAuth
   client registration for Loopex and on what terms. Until it does, `claude:`
   stays disabled and `real-sign-in-anthropic` proves the refusal.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Non-goals](M8.md#concept-plan-scope).

Concept: [Rollout](M8.md#concept-plan-rollout).

| Surface | Boundary |
| --- | --- |
| Local storage container | Retained until M9's explicit engine migration; the `loopex-root-format 1` marker identifies the root format and proves nothing about other builds |
| Durable records and host ledger | Delivered M7 versions as the current format; the settled-attempt record and run terminal admit the `provider_sign_in_required` category; no older-reader or older-root promise |
| Backup layout and its records | New experimental current-format contracts under ADR 0072: `loopex_store_backup_capture_v1`, `loopex_store_restore_attestation_v1` and `loopex_store_restore_continuation_v1` |
| Restore transition | Accepted ADR 0051 with ADR 0072's three clause amendments: the commands are its operator front end; the discard attestation form admits an older backup for a lost source; and `Restore.restore/3`, beside the unchanged `restore/2`, carries a host guard under which every manifest walk stops on a protected credential-directory identity (major device, inode and filesystem path) or a mount inside the walked tree, on Linux one the mount table lists and on macOS a device change (D19), or a FUSE filesystem or an overlay over credential storage at or above the walked root (D21), with ADR 0051's outcomes. A latest-form plan's bytes are unchanged |
| Daemon protocol | `loopex.experimental/4` gains `daemon.readiness` and the `provider_sign_in_required` reason, each with schema, vectors and pinned digests updated in place |
| Foreground protocol and embedded API | `loopex.experimental/3` gains the `provider_sign_in_required` reason; the embedded API is unchanged except an undocumented `Loopex.Runtime.create_session_with_genesis_detailed/4` and ADR 0072's `LoopexComposition.Restore.restore/3` beside the unchanged `restore/2` |
| Configuration | ADR 0049's schema version 1 and resolver; discovery and writers by ADR 0037, the daemon's reader by ADR 0071, the `oauth` form and `vertex` members by ADR 0073 |
| Credentials | Environment references unchanged; sign-in tokens in the operating system's keyring or an owner-only file under `<home>/auth/`, and gcloud's Application Default Credentials directory, physically separate from the state root under [ADR 0037's path-separation rule](../adr/0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation), and refused by its [physical walk check](../adr/0037-host-configuration-and-path-discovery-technical.md#technical-0037-physical-walk) whenever a backup, adopt or restore walk meets either directory or a mount inside the walked tree (D19: on Linux a mount the mount table lists, so a root on an overlay or btrfs filesystem is admitted; on macOS a device change), or a FUSE filesystem, or an overlay whose backing directories overlap either directory or cannot be read, at or above the walked root (D21), so a root, backup or destination containing a mount is refused and no backup's complete copy contains them. That holds for local filesystems, bind mounts, checked overlays and refused FUSE; a network or virtual filesystem that exports the host's own credential directories back to it is not detected, the limit the maintainer accepted with D21. The `adc` source reads gcloud's own file under ADR 0073's stated exception to its decision 3 (D20) |
| Existing commands | The foreground `chat` keeps its grammar and exit semantics. `run`, `resume`, `attach` and `sessions` keep theirs; with `--service`, `run` and `resume` start the service on demand |
| Daemon exit statuses | 65 to 110 unchanged; 111 to 115 (114 retired), 116 to 119, 120 to 123 and 124 (`root_adopting`) added, so the table uses every status 65 to 124 except 114 exactly once |
| Installed archive | New experimental packaging contract under ADR 0038 |

<a id="technical-plan-migration"></a>
### Current-Format Roots and Recovery

Concept: [Rollout and compatibility](M8.md#concept-plan-rollout).

No record is migrated and no older root is upgraded. The
[pre-1.0 rule](../process/agent-context-map.md#disposition-pre1-current-contract-2026-10-02)
retires older-root upgrade, historical-reader and cross-version rollback
proof; that retirement is a scope change, not passing evidence. Current-format
restart, uncertain-effect nonredispatch, authority, cleanup and backup and
restore remain required.

The candidate publishes `STATE_ROOT/loopex-root-format`, exactly
`loopex-root-format 1` and a line feed, into an absent or empty root before
any other write, by hard-link publication that never replaces. Every path that
opens a root checks it before the placement lock and again before composition
starts a Store. It refuses `root_unmarked`, `root_format_unknown` or
`root_marker_unreadable` before any lock, writer marker, socket or Store
repair, and refuses `root_adopting` the same way; the daemon exits 116 to 119, or 124 for `root_adopting`.

A root the M6 or M7 source builds wrote carries no marker and is refused. `loopex
store adopt`, given `--old-writer stopped`, then adopts it in two phases (D17).
It first publishes an `adopting` marker that every `0.5.0` entrypoint refuses,
then audits the root read-only with ADR 0051's decoders and audit, and only
when every record decodes and the final manifest is unchanged makes the marker
current. It changes no record. Adopt holds the root's placement lock from
before it publishes `adopting` through the rename to current, which is the
commit; a concurrent adopt or start, including a delivered M7 daemon or CLI
start, which takes the same lock, is refused meanwhile. An adopt killed or
refused before the rename, `root_changed` included, leaves `adopting`, and a
rerun redoes the full audit; one killed after the rename leaves a committed
current root. No invocation treats an unaudited changed root as adopted.
`--old-writer stopped` remains required because M7 code does not read the
marker, so an M7 process can open the root once adopt releases the lock, and
an embedded or non-cooperating host may take no lock. A root whose records adopt cannot decode,
such as one holding only the retired catalogue, is recovered by the M7 build's
host-embedded ADR 0051 restore, about which M8 claims nothing.

Recovery from a refused or unservable root uses the build whose format the
root is in. A backup taken by `0.5.0` restores under `0.5.0`. Never remove
records to make any build start. Engine migration and interrupted import are
M9 work.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Scope](M8.md#concept-plan-scope).

ADR 0038 owns the platform-specific OTP archive, bundled ERTS, relative
provider companion lookup and manifest. The release label is `0.5.0` (D3). The
M8 candidate advances `VERSION` to `0.5.0` before its tested runs, and the
label is then used consistently in `VERSION`, the build layout, the manifest,
the daemon readiness record and the artifacts, so the eventual tag and
`VERSION` agree. M6's released `0.3.0` and M7's source release `v0.4.0` are
not repurposed.

The two supported hosts (D4) are `darwin-arm64`, macOS 15.0 or later, built on
the Mac with mise's precompiled Erlang/OTP 29.0.5, and `linux-x86_64`, glibc
2.35 or later, built from source in a pinned `ubuntu:22.04` container with
OpenSSL 3.5.7 statically linked (D9). The archive carries no build toolchain;
the OTP `compiler` application ships only as Elixir's runtime dependency
(D10). The macOS archive is not signed or notarized: the operator guide
verifies the archive against its checksum and manifest, then removes the
quarantine attribute with a documented command. Sign-in keyrings are reached
through `/usr/bin/security` and `/usr/bin/secret-tool` as subprocesses, so no
native library enters the linkage set. Service-manager units, distribution
packages and publication are outside M8.
