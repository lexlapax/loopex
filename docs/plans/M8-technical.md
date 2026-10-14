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
| [ADR 0037](../adr/0037-host-configuration-and-path-discovery.md#concept) | 2, 4; the `--service` start for 5 | [ADR 0003](../adr/0003-extension-contract-boundary.md#concept): one home-reading exception for `LoopexCli.Home`. [ADR 0049](../adr/0049-explicit-host-configuration.md#concept): `--config` optional when a home is selected. [ADR 0044](../adr/0044-run-model-and-reasoning-configuration.md#concept), applied: `daemon.readiness` joins the `loopex.experimental/4` manifest's `methods` inventory and result definitions, and the manifest digest is recomputed by ADR 0044's recipe and pinned. Reuses ADRs 0031, 0032 and 0046 | Before `LoopexCli.Home`, the configuration writers, `ServiceStart`, `Service`, `paths`, `doctor` or `daemon.readiness` |
| [ADR 0038](../adr/0038-installed-distribution-and-release-artifact.md#concept) | 1, 6; the installed refusal and restore step of 7 | [ADR 0003](../adr/0003-extension-contract-boundary.md#concept) obligation 4: "no compiler" read as "no build toolchain". Applies [ADR 0019](../adr/0019-host-owned-provider-protection.md#concept) and ADR 0034 to the relocated companion unchanged | Before the release definition in the umbrella `mix.exs`, `scripts/release/`, the launcher's installed mode, `loopex-verify`, `--relocatable` or `loopex version` |
| [ADR 0071](../adr/0071-daemon-attached-conversation.md#concept) | 4 (the service's configuration reader), 5 | [ADR 0049](../adr/0049-explicit-host-configuration.md#concept): nullable `trace` and `policy` in the status record. [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept): the activation ceiling, which counts helper children as decided on 2026-10-13, with any consequent [ADR 0046](../adr/0046-child-session-tool.md#concept) refusal-order clause ADR 0071 states. [ADR 0055](../adr/0055-remote-session-creation-options.md#concept): creation options on a helper-enabled service. Applies ADRs 0033, 0046, 0056 and 0069 | Before `daemon --config`, `AttachedChat`, `DaemonSession`, `ChatProjection`, the `ExitStatus` block 111 to 115, the `activation_permit` member of `Delegation.host/5`, or any helper-parent creation in the daemon |
| [ADR 0072](../adr/0072-store-readiness-marker-backup-and-restore.md#concept) | 3, 7 | [ADR 0051](../adr/0051-current-format-physical-restore.md#concept), two clauses: the absence of a backup CLI, and the latest-backup-only restriction relaxed by `--discard-later-work` for a lost source. Behind a new `Restore.restore/3`, which no ADR 0051 sentence governs, the delivered audit omits the disposable helper job index. Takes the operator backup and restore work out of Proposed ADR 0036 | Before `RootFormat`, the marker checks in `Placement` and `compose/1`, `StoreAdmin`, `LoopexCli.Store`, the `RestoreCodec` discard form, the golden-vector format test, the `ExitStatus` block 116 to 119, or status 124 |
| [ADR 0073](../adr/0073-provider-oauth-sign-in.md#concept) | 8; the sign-in precheck in 4 and the sign-in hint in 5 | [ADR 0018](../adr/0018-provider-attempt-authority-and-recovery.md#concept), [ADR 0021](../adr/0021-compacted-provider-accounting-provenance.md#concept) and [ADR 0043](../adr/0043-context-compaction-checkpoint.md#concept): the clauses ADR 0073 names for the sign-in refusal and the `chatgpt:` summary ceiling. [ADR 0019](../adr/0019-host-owned-provider-protection.md#concept): the host-held access token and the `token_exchange` invocation. [ADR 0029](../adr/0029-bounded-provider-failure-diagnostics.md#concept): the public `provider_sign_in_required` reason. [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept): custody rotation by a host refresher. [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept): sign-in routes resolve from composition-owned custody. [ADR 0048](../adr/0048-host-provider-routing-and-credential-bindings.md#concept): the `oauth` form, `vertex` members and same-account live rotation. [ADR 0049](../adr/0049-explicit-host-configuration.md#concept): the `oauth` binding form and `vertex` members as additive members of schema version 1. Also one sentence of Proposed ADR 0037 and this plan's credential non-goal. Its own decision 3 states the `adc` source as an explicit exception (D20) | Before any `SignIn.*` module other than ADR 0037's `SignIn.Separation`, binding-grammar change, Core category admission, schema or vector change, `loopex auth`, or the `ExitStatus` block 120 to 124, which also carries ADR 0072's 124 |

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
| W1 Integration | `apps/loopex_cli`: `Home`, `ConfigWriter`, `ConfigOptions`, `ConfigInspection`, `ConfigFile`, `ServiceStart`, `Service`, `Live`, `Daemon`, `HostOptions`, `Chat`, `ChatDriver`, `ChatProjection`, `ChatControl`, `AttachedChat`, `DaemonSession`, `DaemonClient` and the `LoopexCli` dispatch table. `apps/loopex_daemon`: `Command`, `ExitStatus`, `Service`, `ServiceReadiness`, `Request`, `SocketConnection`, `WireRecords`, `Owner`, `ConnectionRegistry`. `apps/loopex_protocol/priv/schema` and `priv/vectors`, `clients/node`. `LoopexComposition.Placement`'s lock primitive extraction. `Placement`'s process probe runs `ps -o lstart=` with `TZ=UTC0` beside `LC_ALL=C` (`placement.ex:555-557`), fixing a delivered defect: `lstart` prints local time, so two commands under different `TZ` values read a live owner's incarnation differently, and `owner_status/2` would treat a live lock as dead and reclaim it; `placement_probe_test.exs` gains a lock taken under `TZ=America/Los_Angeles` that a probe under `TZ=UTC` finds alive and does not reclaim. `LoopexComposition.Delegation.host/5` (new at step 4: `host/4`'s arguments plus an options keyword that admits no member until W2 adds `activation_permit`; its handle carries the readiness table) and `LoopexComposition.Delegation.Helper`'s readiness ETS table with its single writer (ADR 0037), with the classification code that keeps the failing session and code (ADR 0072's readiness code). The `scripts/check-release.sh` runner, `scripts/lib/release-lane.sh`, `Mix.Tasks.Loopex.M7Matrix` and `M7Evidence.CaseRunner` changes of the [release-check list](#technical-plan-release-check), with their tests, and the verification guide pair's matching text. `VERSION` at the candidate | The first installed workflow |
| W2 Daemon helpers (W1's integrator, after the attached conversation) | `LoopexCli.ChatConfiguration`'s split into `helper_roles/1`, `helper_catalog/3` and `helper_parent_genesis/3`; `LoopexCli.HostOptions.helpers/1`; `LoopexComposition.Delegation.create_parent_detailed/7`, the `activation_permit` member of `host/5`'s options (W1 lands `host/5` itself) and `Helper.create_parent/2`; `Loopex.Runtime.create_session_with_genesis_detailed/4`; helper hosting and activation counting in `LoopexDaemon.Service`, `Owner`, `ConnectionRegistry` (its one counted sum, `activations_counted/1`, used by client admission, the helper permit and the status report) and `SocketConnection.create_task/4` | After the first installed workflow, before the installed demonstration |
| W3 Packaging | The umbrella `mix.exs` `releases/0` and `installed_layout/1`; `scripts/release/` (`toolchain.env`, `build.sh`, `assemble.sh`, `write-manifest.sh`, `assert-linkage.sh`, `smoke.sh`, `linux/Dockerfile`, `linux/Dockerfile.smoke`); `apps/loopex_cli/bin/loopex` and `bin/loopex-verify`; `apps/loopex_llm_reqllm/lib/mix/tasks/loopex.provider.build.ex`'s `--relocatable`; `LoopexCli.ProviderLaunch.options/0`; the `loopex version` module; the `installed-artifact` lane in `scripts/check-release.sh` | The first installed workflow, with a locally built archive |
| W4 Backup and restore | `LoopexComposition.RootFormat`, `StoreAdmin`, `StoreAdmin.Codec`; the marker step in `Placement.acquire/2` and `LoopexComposition.compose/1`; `Restore.IO`'s `root_inventory` and `backup_copy` operations; `Restore.restore/3` and `Restore.IO.run/3`'s `:omit_job_index` option; ADR 0037's `LoopexComposition.SignIn.Separation.check/1`, landing at step 3 before W1's `LoopexCli.Home`, and `StoreAdmin.restore/3`'s check of an available source with it (D27); `Restore.Audit`'s session-identifying failure and, with `Restore.Workflow`'s baseline check, the omission of the disposable helper job index from the audit index in backup mode and through `restore/3`; `RootFormat`'s `format_history/0` pin, `apps/loopex_cli/test/root_format_vectors_test.exs` and its golden vectors; the retained M7-built root fixture under `apps/loopex_composition/test/fixtures/m7_root/` (D24); `Restore.Workflow`'s discard-form validation; `Loopex.Executor.Local.RestoreCodec`'s discard form; `LoopexCli.Store` and the marker checks for `sessions` and `artifact`; the `m7-adopt` lane (D26) in `scripts/check-release.sh` with its read-only child audit `m7_adopt_child_audit_test.exs` and `test/support/m7_child_audit.ex` | The marker first, before W1's daemon and CLI changes; adopt, backup and restore after the first installed workflow, before the installed demonstration |
| W5 Provider sign-in | `apps/loopex_llm_reqllm`: `Loopex.LLM.ReqLLM.SignIn.*`, the `Guards` provider table, `HostBindings`, `NativeRequest`'s per-route header seal, the `chatgpt` mapping, `drain/5`'s reply ceiling, `in_process.ex`'s sign-in resolution and the companion's `token_exchange` kind. `apps/loopex_composition`: every `LoopexComposition.SignIn.*` module except W4's `SignIn.Separation` (store, backends, refresh lock, `Route` edge), the credential plane's registration of sign-in custody, and `test/support/fake_oauth_server.ex`. `apps/loopex` (Core): the `provider_sign_in_required` admission in `SessionCoordinator`, `ProviderAttempt` and `SessionState`. `apps/loopex_protocol`: `Session.Outcome` and `Session.CompactResult`. `apps/loopex_cli`: `LoopexCli.Auth` and its sign-in hint function. The `real-sign-in-*`, `secret_service` and `macos_keychain` lanes in `scripts/check-release.sh` (D18) | After the first installed workflow and after W1's `daemon.readiness` schema change; before the installed demonstration |

Shared files and their single owner:

- `LoopexDaemon.ExitStatus` and `apps/loopex_daemon/test/command_test.exs`:
  W1. The blocks land in this order, each once its ADR is accepted: 111 to
  115 (114 retired) under ADR 0071; then 116 to 119 under ADR 0072, at step
  3; then 120 to 124 together, ADR 0073's 120 to 123 and ADR 0072's 124
  (`root_adopting`), at step 6, before W4's adopt and W5's sign-in rejoin
  merge. Landing 124 with 120 to 123 keeps every interim table gap-free. At
  each step `command_test.exs` expects the cumulative set exactly: 65 to 115
  without 114, then 65 to 119 without 114, then 65 to 124 without 114. The
  daemon's mapping of `root_adopting` and its `daemon_root_format_test.exs`
  case land with 124; `store adopt`, the only writer of the `adopting`
  marker, merges after them.
- `apps/loopex_protocol/priv/schema`, `priv/vectors`, the pinned digest in
  `LoopexCli.DaemonClient`, `clients/node/contract-manifest.mjs` and
  `clients/node/daemon-client.mjs`: W1. `daemon.readiness` lands first; W5's
  failure reason rebases on it and the integrator lands the regenerated
  manifests and schema proof.
- `LoopexComposition.Placement`: W1 extracts the lock primitive into one
  shared private module before anything else uses it; W4 then owns
  `Placement.acquire/2`'s marker step; W5's refresh lock and W1's
  configuration-writer lock call the primitive.
- `LoopexComposition.SignIn.Separation`: W4 alone, landing with the marker
  at step 3 because its marked-ancestor rule reads ADR 0072's marker and
  W1's `LoopexCli.Home` (step 4) and W4's `StoreAdmin.restore/3` call it.
  W5's store and refresher call `check/1` on the context they were given
  and add no member. No walk calls it (D27).
- `LoopexComposition.Delegation` and `Delegation.Helper`: W1 lands `host/5`
  and the readiness table at step 4, because `daemon.readiness` needs the
  handle's table; W2 adds the `activation_permit` option member, the permit
  binding and the refusal order at step 6.
- The `LoopexCli` dispatch table, `scripts/check-release.sh` lane list and
  `scripts/check.sh`: W1 wires each workstream's entry module or lane at its
  rejoin. The runner changes D18 needs are the integrator's, listed under
  [release-check changes](#technical-plan-release-check).
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
  delivered `restore/2` only to leave the disposable job index out of the
  audit, and `lookup/3`. It adds no second copy, audit or transition.
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
  keychain. The attended `real-sign-in-*` lanes are no exception: each signs
  in under a temporary `HOME` with `--store file` (ADR 0073's owner-only file
  backend), and the keychain and Secret Service backends are proved only by
  the `macos_keychain` and `secret_service` lanes on a temporary keychain and
  a private session bus.

<a id="technical-plan-order"></a>
### Implementation Order

Concept: [Workstreams](M8.md#concept-plan-workstreams).

Each step names its first dependency; steps on one line may run in parallel
in separate worktrees.

1. **Acceptance.** The plan pair and each ADR it depends on, as listed in the
   prerequisites. Unrelated work does not wait.
2. **Foundation (W1).** Extract the placement lock primitive; add the
   `ExitStatus` 111 to 115 block once ADR 0071 is accepted.
3. **Root marker and separation (W4)** under ADRs 0072 and 0037:
   `RootFormat` with its golden-vector test, `Placement.acquire/2` and
   `compose/1` admission, the read-only checks, daemon statuses 116 to 119,
   every existing fixture that opens a root brought to a marked root, and the
   whole of `SignIn.Separation`, which W1's `Home` calls at step 4. The
   retained M7-built root fixture (D24) is produced here, so the marker
   refusal tests run against it. **Packaging (W3)** starts in parallel under
   ADR 0038.
4. **Home and service (W1)** under ADRs 0037 and 0071: `Home`, writers,
   `daemon --config`, `ServiceStart`, `Delegation.host/5` with the helper
   owner's readiness table and its single writer, `daemon.readiness`,
   `service`, `paths` and `doctor`, then `AttachedChat` with `DaemonSession`
   and `ChatProjection`. **Provider sign-in (W5)** starts in parallel under ADR
   0073 with the token store, refresh, routes and the reply ceiling, behind
   the fake OAuth server.
5. **First installed workflow.** W1 and W3 rejoin: install a locally built
   archive, `init`, `chat --service`, detach, reconnect, `service stop`.
6. **Exit statuses 120 to 124 (W1)**, then **daemon helpers (W2)** under
   ADR 0071 decision 10 and its activation counting, adding the
   `activation_permit` member to `host/5`. **Adopt, backup and restore
   (W4)**, after status 124. **Sign-in rejoin (W5)**: the public reason in
   Core and the protocol, the start-on-demand precheck, the daemon's use of
   statuses 120 to 123 and the hints.
7. **Failure matrices.** Process races, fault cuts, restart and signal cases
   for every workstream, on both toolchain pairs.
8. **Demonstration and candidate.** `VERSION` advanced to `0.5.0`,
   documentation and the evidence scaffold, then the closure matrix of D18:
   the full release check on `serenity`, which runs `installed-artifact` for
   `linux-x86_64`, `secret_service`, `cross_uid` and the
   attended `real-sign-in-*` lanes whose clients exist, and on macOS arm64
   the `macos_keychain`, `installed-artifact` and attended `m8-operator`
   lanes with `--only`, the last carrying the outcome-6 record with
   `m8.service-review`, all recorded in the one M8 attempts index.

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
| ADR 0051 delivers host-embedded `LoopexComposition.Restore.restore/2` and `lookup/3`; the host owns backup creation, the capture record, plan construction and the attestation; there is no command | `store backup` produces the backup and capture record; `store restore` builds the plan from the operator's statements and calls the delivered `lookup/3` and `restore/3`, the entry point ADR 0072 adds beside `restore/2` to leave the job index out of the audit | ADR 0072 |
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

**Closure matrix (D18, revised).** The full `bash scripts/check-release.sh`
runs once on the Linux x86-64 host `serenity`, with the M8 attempts index
whose writer is pinned to `serenity`. Besides the delivered lanes it runs,
each required: `installed-artifact` for `linux-x86_64`; `secret_service`, the
`:secret_service` keyring cases under `dbus-run-session`; the delivered
`cross_uid` lane, which the
[verification guide](../process/verification.md#concept) requires for a
daemon change; and the attended `real-sign-in-openai`,
`real-sign-in-gemini` and `real-sign-in-anthropic` lanes. On the macOS arm64
host the same candidate runs three required lanes with `--only`:
`macos_keychain`, `installed-artifact` for `darwin-arm64`, and `m8-operator`,
the attended outcome-6 record. Each macOS lane is recorded in the same M8
index as a required closure lane, so closure is the `serenity` full PASS and
a PASS of each of the three. A lane that reports evidence unavailable blocks
closure; it is never a pass and never a deferral without the maintainer's
recorded decision. Both hosts' complete outputs are retained.

| # | Fast-check proof | Release check |
| --- | --- | --- |
| 1 | The existing escript, provider-companion and launcher suites stay green with the relocatable launch pair; `apps/loopex_cli/test/service_start_test.exs` proves the installed command is resolved from the escript's own location | `installed-artifact` (ADR 0038): build with pinned inputs and the linkage table, manifest and verifier, a quarantined download cleared by the documented step on macOS, clean-host assertions, loaded-image probe and `loopex version`, with every Mix, Hex and Rebar step resolved from the pinned toolchain's `PATH` into writable build-only locations, on `darwin-arm64` and in a clean Ubuntu 22.04 `linux-x86_64` container. The closure matrix (D18) runs it inside the full release check on `serenity` and with `--only installed-artifact` on macOS |
| 2 | `apps/loopex_cli/test/home_test.exs`, `config_inspection_test.exs` (extended), `config_writer_test.exs` | Installed lane step 3 |
| 3 | `apps/loopex_composition/test/store_backup_test.exs`, `store_restore_command_test.exs` (both attestation forms, `--resume`, every refusal, the lookup answer after an unresolved result), `restore_workflow_test.exs` (extended: a backup holding the helper job index committed by `restore/3` with `omit_job_index: true` and that index copied byte for byte, while `restore/2` refuses it as delivered, and malformed `restore/3` options refused `invalid_plan`), `store_backup_test.exs` also proving that backup writes nothing to the job index and copies it, `delegation_readiness_code_test.exs`; `apps/loopex_executor_local/test/restore_codec_test.exs` (extended); `apps/loopex_cli/test/store_command_test.exs`; `apps/loopex_daemon/test/readiness_closed_root_test.exs` | Installed lane step 5, the restore half |
| 4 | `apps/loopex_cli/test/service_start_test.exs`, `service_command_test.exs`, `service_detach_pty_test.exs`, `live_service_test.exs`, `daemon_configuration_test.exs`; `apps/loopex_daemon/test/readiness_method_test.exs`, `command_test.exs` (extended); the Node contract lane decoding `daemon.readiness`. Under ADR 0037: readiness asked while a helper classification slice is held answers within 1,000 ms with a truthful `classifying` state from a nonblocking source, without a second writer of helper truth; `service status` emits one closed JSON result from its named reads, including helper activations; the `ExitStatus` table uses every status 65 to 124 except the retired 114 exactly once | Installed lane step 4's status and diagnostic commands |
| 5 | `apps/loopex_cli/test/attached_chat_grammar_test.exs`, `attached_chat_test.exs`, `attached_chat_detach_test.exs`, `attached_chat_signal_test.exs`, `attached_chat_lease_test.exs`, `attached_chat_reconnect_test.exs`, `live_daemon_test.exs` (extended), `daemon_helpers_test.exs`, `daemon_helper_restart_test.exs`, `chat_configuration_test.exs` (extended), with ADR 0071's helper-child activation-counting cases, including the helper permit's atomic registry operation at the real `ConnectionRegistry` boundary (an activated-without-session and an unknown disposition, preserved through a post-create parent-binding failure) and the one counted sum in both directions (held permits refuse a client reservation `activation_ceiling_reached`, and client activations refuse a permit); `apps/loopex_daemon/test/helper_route_guard_test.exs` (extended); `apps/loopex/test/runtime_create_with_genesis_detailed_test.exs` | Attended: the reconnect case and `m8.service-review` in the outcome-6 record |
| 6 | — | `installed-artifact` steps 1 to 6 on each host with complete output and archive evidence; the attended record, `--only m8-operator` on macOS, by an identified operator in a separate user account, following the runbook through install, `chat --service`, close and reconnect, `m8.service-review` (M7's `m7.review` profile through the service, a detach while a helper runs, and `service stop` during a second helper with the stop-only result after restart), backup, restore and removal, where removal runs `loopex auth logout` for every signed-in route before deleting anything and then asserts that no Loopex keychain item remains; the Linux installed lane's removal step asserts that no Loopex Secret Service item remains |
| 7 | `apps/loopex_composition/test/root_format_test.exs` (concurrent marker publication with a deterministic gate at the link-before-unlink cut), `placement_root_format_test.exs`, `composition_root_format_test.exs`, `store_adopt_test.exs` (D17: the `adopting` marker refused by every entrypoint, `--old-writer stopped` required, a real synchronized `Placement.acquire/2` and daemon start attempted immediately after the `adopting` publication refused while adopt holds the lock and attempted immediately after the rename admitted only after adopt releases, two concurrent adopters of which exactly one proceeds, a real M7-style lock-taking writer (a separate process on the delivered `Placement.acquire/2` path, as the M7 daemon and CLI take it) refused `placement_active` while adopt holds the lock, the synthetic writers that take no lock labelled as non-cooperating writers, an old-build writer before and after the audit manifest, a kill before the rename and `root_changed` leaving `adopting`, a kill after the rename leaving a committed current root, a rerun redoing the full audit) and, on the retained root the `v0.4.0` build wrote (D24), refusal by every entrypoint with the root byte-identical, then an adopt through `StoreAdmin.test_adopt/3` with the workspace reference the fixture's genesis records, whose full audit passes and which changes nothing but the marker: the audit-and-marker proof with the workspace check bypassed; `apps/loopex_cli/test/root_format_vectors_test.exs` (the golden vectors of format 1 decoded and re-encoded by the real codecs, their boundary vectors, the completeness check and the `format_history/0` pin; D28); `apps/loopex_cli/test/store_marker_entrypoints_test.exs`; `apps/loopex_daemon/test/daemon_root_format_test.exs` | Installed lane step 5: the retained M7-written root (D24) refused by name and byte-identical, and a backup taken by the candidate restored under it and served. `m7-adopt` in the `serenity` full check (D26), the product path: the `v0.4.0` release built in a temporary tree writes and stops a root on a live temporary workspace with a conversation and one helper run, the candidate's own `loopex store adopt --old-writer stopped` adopts it with no test seam, and the candidate's `doctor` reports `marker: current`, its offline `sessions` lists the conversation, the only session the M7 build catalogued, a read-only audit (`m7_adopt_child_audit_test.exs`) checks the helper child's journal and terminal record against the helper run log, and every M7 record stays byte-identical, as ADR 0072's [`m7-adopt` lane](../adr/0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-m7-adopt) states |
| 8 | `apps/loopex_llm_reqllm/test/sign_in_profiles_test.exs`, `sign_in_routes_test.exs`, `chatgpt_reply_ceiling_test.exs`, `provider_bridge_test.exs` (extended), `sign_in_id_token_test.exs`; `apps/loopex_composition/test/sign_in_adc_test.exs`, `sign_in_store_test.exs`, `sign_in_refresh_test.exs`, `credential_plane_test.exs` (extended), `chatgpt_summarizer_test.exs`; `apps/loopex/test/sign_in_required_settlement_test.exs`. Under ADR 0073 these cover: ID-token signature verification against the provider's JWKS (forged, unknown-key and rotation negatives) and the validated subject paired with the token generation, refusing a mismatch in either direction after a different-account write cut and a restart before metadata publication; the ADC source and Google's refresh-response merge; one shared streaming reply ceiling proved through both the companion and the in-process caller, summarization included; and the terminal, no-accounting sign-in refusal on any legal attempt, including a route that becomes unavailable between attempts. The auth directory, the ADC directory and every state root, backup, destination and available restore source stay separate by resolved path under [ADR 0037's path-separation rule](../adr/0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation) (D27), refused before any token or root write, with overrides and a changed `HOME`, which `auth_separation_test.exs` proves with a credential-shaped canary; `apps/loopex_protocol/test/sign_in_required_vectors_test.exs`; `apps/loopex_cli/test/auth_command_test.exs`, `daemon_sign_in_test.exs`, `ask_sign_in_test.exs`; `apps/loopex_daemon/test/command_test.exs` (extended); the Node client decoding the new vectors. The tagged `sign_in_keychain_test.exs` (`:macos_keychain`, temporary keychain) and `sign_in_secret_service_test.exs` (`:secret_service`, under `dbus-run-session`) are excluded from the fast check and run in release lanes | `macos_keychain` with `--only` on macOS and `secret_service` in the `serenity` full check (D18), each required to execute its cases. Mounts are outside the separation guarantee (D27), so no release lane creates one. Attended, in the `serenity` full check, each gated on its provider's client and each under a temporary `HOME` with the store it names: `real-sign-in-openai` (`auth login openai --store file`, whose model list, fetched before the login's write, must be recorded non-empty within its bounds and name the lane's model (D25); one `chatgpt:` conversation through the installed service; a forced refresh; logout with revocation; then a second `auth login openai` under the generation floor, which must authorize under the floor's issued client and write a generation above the floor, with its model list recorded again; ADR 0073 verification items 1 and 11 to 15); `real-sign-in-gemini` (the same for `vertex:`, through the `loopex` source with `--store file` and through the `adc` source, which writes only metadata, from a file real `gcloud` wrote under that `HOME`, against a maintainer-owned project); `real-sign-in-anthropic` (refused `sign_in_unavailable` until a sanctioned registration exists, writing nothing; that tested refusal is the disabled route's proof under D16). No real sign-in lane uses a keychain or the Secret Service. Tokens are redacted from retained outputs |

ADR 0073's sixteen
[verification items](../adr/0073-provider-oauth-sign-in-technical.md#technical-adr-0073-verification)
each carry their own disposition in ADR 0073: 1 to 10 (refresh-token
invalidation, partner client, allowed models, launch date, scope
classification, token lifetime, ADC field names, regional Vertex host,
Anthropic's terms, and each provider's ID-token issuer, JWKS URI and signing
algorithm), 11 and 12 (the ID token's audience and the issued client
returned at the callback; the nonce and a later authorize under the issued
client), 13 (`resource` on refresh), 14 and 15 (the plan token's model
listing and its bounds) and 16 (the keychain tool's maximum input line).
Each is checked in W5 where it lands and recorded there, items 1 and 11 to
15 by `real-sign-in-openai` and 16 by the tagged `sign_in_keychain_test.exs`,
and none becomes a silent default.

Under D16, closing outcome 8 requires positive proof from
`real-sign-in-openai` and `real-sign-in-gemini`. The deliberately disabled
Anthropic route is proved by its tested refusal in `real-sign-in-anthropic`,
which needs no deferral. If the OpenAI or Google client is unavailable at
closure, that lane is evidence unavailable, not a pass, and closing outcome 8
without its positive proof is a deferral that needs the maintainer's recorded
decision.

The two repository checks apply with the release-check changes below and the
closure matrix above. The evidence page is `docs/evidence/M8-closure-runs.md`,
created and indexed on its actual candidate, with complete immutable outputs
outside the repository. Under the M7
[scaffold rule](M7-technical.md#technical-plan-evidence) it fixes the
campaign and genesis digest of the M8 index and the committed pre-candidate
head digest and count, and predeclares `Pending` slots for the index path,
the final head digest and count, and, for each run root (the `serenity` run's
`$retain/m7-runs` and the macOS run's `--writer-retain`), one cell holding
the count and SHA-256 of its ordered invocation-log reference list.

<a id="technical-plan-release-check"></a>
### Release-Check Changes

Concept: [Verification](M8.md#concept-plan-verification).

W1 makes these changes to `scripts/check-release.sh`,
`scripts/lib/release-lane.sh`, the release recorder
`Mix.Tasks.Loopex.M7Matrix`
(`apps/loopex_cli/lib/mix/tasks/loopex.m7_matrix.ex`) and the trusted
wrapper's `Mix.Tasks.Loopex.M7Evidence.CaseRunner`, with the verification
guide pair's matching text, before the first M8 lane is recorded. They
reuse the delivered writer `M7Evidence.AttemptWriter` and event codec
`M7Evidence.AttemptEvents` unchanged: no new event, member, mechanical
result or verdict, and no import of results written elsewhere.
Line numbers are those of `4c05628f`, unchanged at `7b4293a6`; `matrix.ex`
below is `loopex.m7_matrix.ex`.

1. **M8 campaign and its committed anchor.** The full matrix and every
   indexed M8 lane take `--attempts-index FILE` naming one M8 index, campaign
   `m8-closure-1`. Like every index, it starts with the delivered genesis
   (campaign and codec version 1) and writer designation (writer
   `maintainer-serenity`, host `serenity`, ownership epoch 1)
   (`attempt_events.ex:47-48`); it has no other header, and neither the
   concept file nor the release label is an index member. It is created once
   on `serenity`, from a clean checkout of the M8 branch, by
   `mix loopex.m7_matrix --create --campaign m8-closure-1 --attempts-index
   FILE --writer maintainer-serenity --host serenity --markers DIR`.
   `--create` takes its campaign from `--campaign` instead of the delivered
   `campaign/0`, which reads the M7 fixture manifest (`matrix.ex:269-274`);
   it takes no `--case` and admits no lane, writes the two records through
   `AttemptWriter.create/4`, and prints `index-head: m8-closure-1 2 SHA256`
   with the designation record's digest. The next commit appends that line to
   `docs/plans/M8.md`'s Progress and Evidence section, below its table, as
   the M7 plan places its heads. Until that commit is checked out, every
   admission refuses `committed_attempt_head_unavailable`
   (`attempt_heads.ex:81-82`). From then on the M7 plan's
   [head-recording rule](M7-technical.md#technical-plan-evidence) applies
   unchanged with `docs/plans/M8.md` as the Concept file: the commit after
   an indexed lane ends or a matrix stops appends its head, and a completed
   closure matrix's final head goes only into the evidence scaffold's
   `Pending` slots named above.

   A consumed non-pass (`fail`, `unavailable`, or a `started` case never
   finished) ends campaign `m8-closure-N`: continuation refuses
   `consumed_lane_failure`, a join refuses `consumed_matrix_failure`, and a
   later candidate's new matrix refuses `post_head_consumed_case`
   (`attempt_events.ex:256-274`, `:416-417`). No production code appends the
   `reviewed` or `authorized_next_candidate` records the delivered
   authorization rule reads, and none is added. The next candidate instead
   gets a new index file, created as above with `--campaign
   m8-closure-<N+1>`, and its own anchor line; `AttemptHeads.select/2`
   ignores the earlier campaign's lines (`attempt_heads.ex:58-63`). The
   ended index stays retained.
   The recorder's `--concept` (`:255`) names `docs/plans/M8.md`, and
   `CaseRunner`, which reads `docs/plans/M7.md` today (`case_runner.ex:120`),
   gains `--concept FILE`, which the runner passes for the M7 conversation
   lanes (`:452-454`), so they admit against M8's heads. M8 runs never write
   the M7 index, which stays the record of M7's runs. The delivered M7 lanes
   (`m7-rollback`, `m7-provider`, `m7-operator`) stay in the full matrix as
   delivered-product lanes recorded in the M8 index.

   The recorder also gains `--checkout DIR`. Before it opens the index it
   refuses when `--host` differs from its own host name up to the first dot
   (`:inet.gethostname/0`), or when DIR is not a clean Git checkout whose
   `HEAD` is `--candidate`, the check `CaseRunner` makes of its own root
   (`case_runner.ex:206-213`). The runner passes its own clean checkout.
   `--create` makes both checks, with `--candidate` the M8 branch commit it
   runs from.
   With the delivered owner check, which refuses any writer or host other
   than the designated one (`attempt_writer.ex:627-637`), a full matrix
   started anywhere but `serenity` refuses before staging, because the
   recorder starts before the fresh-source extraction (`:268`). The `PASS
   (closure-incomplete: cross_uid not run)` branch (`:471-472`) is removed.
2. **Release version.** `release_version` (`:110`) becomes `0.5.0`, the
   `VERSION` the candidate carries. The runner refuses before staging when
   the checkout's `VERSION` differs, and the extraction check (`:329`) is
   unchanged. The index pins no version.
3. **Lane registration.** `--only` (`release-lane.sh:21`) admits
   `installed-artifact`, `secret_service`, `macos_keychain`,
   `real-sign-in-openai`, `real-sign-in-gemini`, `real-sign-in-anthropic`,
   `m7-adopt` and `m8-operator`. `secret_service` and `cross_uid` refuse a
   selection on a host other than Linux, and `macos_keychain` and
   `m8-operator` on a host other than macOS, before staging. The full
   matrix's lane list (`:240-246`) gains `installed-artifact`,
   `secret-service`, `real-sign-in-openai`, `real-sign-in-gemini`,
   `real-sign-in-anthropic` and `m7-adopt` beside the delivered `cross-uid`,
   which stays a full-matrix lane. `m7-adopt` (D26), which W4 owns, is
   unattended and runs ADR 0072's
   [product-path adoption](../adr/0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-m7-adopt):
   it builds the `v0.4.0` commit `9fe9618b0fbd89bdbcd5fc7e75ab0a5abb1ebe20`
   in a temporary tree under the current toolchain pair, which that tag's
   `.tool-versions` names; runs its chat under `with_m7_credentials`, since
   the M7 build has no credential-free chat provider; and runs the
   candidate's adopt, `doctor`, offline `sessions` and the read-only child
   audit under `without_credential`. Each tagged lane must execute its stated case count.
   A lane that executes none, or whose host refuses its session
   bus or Docker, is evidence unavailable, recorded as item 7 states and
   never printed as a pass.
4. **macOS lanes in the same index, through the `serenity` writer.** The
   index has one writer and nothing is imported. The three macOS lanes run in
   one invocation on the candidate commit: `--only macos_keychain --only
   installed-artifact --only m8-operator`, with `--attempts-index`,
   `--writer`, `--host` and `--markers` naming the `serenity` index, writer
   and marker directory, and four new options: `--writer-ssh DEST`,
   `--writer-checkout DIR`, `--writer-retain DIR` and `--join-matrix ID`. An
   indexed macOS run selects exactly those three lanes and needs all four
   options, which refuse with any other selection; `--attempts-index` with a
   selection is admitted only for that set, `m7-provider` or `m7-rollback`
   (replacing `release-lane.sh:70-73`). The runner starts the recorder on
   `serenity` as its coprocess (`release_matrix_start`,
   `release-lane.sh:97-112`) through `ssh -T -o BatchMode=yes -o
   ServerAliveInterval=15 -o ServerAliveCountMax=4 DEST` under
   `without_credential`, each argument quoted for the remote shell. It runs
   `mise x elixir@E erlang@O -- mix loopex.m7_matrix`, E and O the current
   pair in the candidate's `.tool-versions`, since a non-interactive SSH shell
   does not activate the toolchain shim, in `--writer-checkout`, a clean
   checkout of the candidate on `serenity`, with `--checkout` that
   directory, `--concept` its `docs/plans/M8.md` and `--run-root` the
   `--writer-retain` directory. The join starts only after the `serenity`
   run has exited, because the M7 conversation lanes open the writer after
   the recorder closes (`check-release.sh:440`).
   The line protocol is the delivered one, so every `started` reply follows
   the synced append on `serenity`, and no macOS lane runs before its reply.
   Both hosts are the maintainer's, the trust the M7 single-writer procedure
   already assumes; the connection carries no provider value.

   The recorder admits lane `macos-closure` through a new `--lane ID`
   option, whose default stays the delivered `release-matrix`
   (`matrix.ex:79`). Its three ordered cases are `macos_keychain`,
   `installed-artifact` and `m8-operator`, each pinned to the digest of its
   label, `Darwin arm64` and the runner script's digest (`:252`, `:264`). A
   new `--join` mode tries `:continue` and, when the lane has no history,
   `:join` on the matrix `--join-matrix` names, which is the ID the
   `serenity` run printed (`:267`). It follows `CaseRunner`'s `:auto`
   (`case_runner.ex:359-379`) but never falls back to `:new`. The delivered
   join rule refuses a matrix with no record on this candidate
   (`attempt_events.ex:285-293`), and the matrix-failure rule refuses a join
   after any consumed failure in the matrix (`attempt_events.ex:268-274`).
   After each lane the runner copies its retained log over the same
   destination into `--writer-retain` as `<attempt>.log`, the attempt ID of
   its `started` reply (the recorder writes `<attempt>.json` beside it,
   `matrix.ex:133`), created exclusively. It checks the copy's SHA-256 on
   `serenity`; on a mismatch or copy failure it retries, up to three times,
   under a new exclusive name `<attempt>.<n>.log`, holding the recorder
   open, then finishes the case with the verified path and the log's local
   SHA-256, or with `unavailable` once the retries are spent (item 7).

   The final lines (`:469-474`) become: a full run prints `PASS (serenity
   matrix ID; closure also needs macos-closure joined to it)`; an indexed
   macOS run prints `PASS (macos-closure joined to matrix ID)`; an unindexed
   selection keeps `PASS (selection-only: not full closure evidence)`.
   Closure is read from the index: on one candidate and matrix, every case of
   the `release-matrix` lane, of the M7 conversation lanes and of
   `macos-closure` completed `pass`.
5. **Attended lanes.** `m8-operator` and the three `real-sign-in-*` lanes are
   attended. Like the delivered attended rows (`:372-374`), they keep the
   invoking terminal as standard input and read any manifest on another
   descriptor; each refuses before staging, as evidence unavailable, when
   standard input is not a terminal. Their complete transcripts pass through
   the lane redactor, which ADR 0073 extends to the stored sign-in record's
   values, into the retained directory, and the index records each
   transcript's SHA-256 when the lane finishes. `m8-operator`'s record is
   made in the separate macOS user account ADR 0038 names: the lane hands
   that account the verified archive, waits at the terminal while the
   operator follows the runbook there, then takes the record's transcript,
   checks that it names the digest of the archive it handed over, and
   writes it to the lane command's standard output, so it passes through the
   redactor into `$retain/m8-operator.log` before that log's
   `lane-evidence:` line (`release-lane.sh:344-357`) and the one log item 7
   records carries it. The `real-sign-in-*` lanes run on the `serenity` host
   itself, not in the clean container, against the `linux-x86_64` archive
   the same run's `installed-artifact` lane built and verified, each under a
   temporary `HOME` with `--store file`. The delivered refusal of attended
   rows under `--only` stays for `real-provider-1`, `real-provider-2` and
   `m7-operator`.
6. **Credentials.** `:28` keeps every provider value unexported, and `loopex
   daemon --config` discards `LOOPEX_PROVIDER_API_KEY` unread (ADR 0071), so
   no installed lane can pass that name through. A new wrapper,
   `with_installed_credentials`, a subshell like `with_m7_credentials`
   (`:156`), assigns the held `LOOPEX_PROVIDER_API_KEY` value to
   `ANTHROPIC_API_KEY`, keeps `OPENAI_API_KEY`, unsets
   `LOOPEX_PROVIDER_API_KEY` and `OPENROUTER_API_KEY`, and exports only those
   two names, which the installed lane's `init` configuration references.
   Values never enter argv: on macOS the subshell unsets every exported
   variable outside the clean-host allowlist instead of passing assignments
   to `env -i`, and on Linux `docker run --env NAME` passes each name alone.
   The `real-sign-in-*` and `m8-operator` lanes take no runner key: they run
   under `without_credential`, and `m8-operator`'s operator supplies the
   pinned providers' keys in the separate account by the runbook's
   environment step. The wrapper self-check (`:163-198`) gains an
   `installed=` probe that requires exactly those two names and no
   `LOOPEX_PROVIDER_API_KEY`.
7. **Lane results.** The recorder's `finish` (`matrix.ex:147-159`) becomes
   `finish KEY pass|fail|unavailable LOG SHA256`, and every result uses the
   codec's existing values (`attempt_events.ex:61-62`). When LOG is a
   readable file on the writer's host whose SHA-256 is SHA256, the case is
   recorded `completed` with evidence the invocation record and LOG, and
   mechanical result `pass`, `assertion_failed` for `fail` as delivered, or
   `evidence_incomplete_post_dispatch` for `unavailable`. Otherwise, whatever
   result was sent, it is recorded `completed` with
   `evidence_incomplete_post_dispatch` and the invocation record alone, which
   the codec admits (`attempt_events.ex:772-777`), and the reply is
   `finished KEY unavailable`; no pass is recorded without its log's bytes.
   `lane` (`release-lane.sh:312-330`) sends `unavailable` when the lane's
   redactor and tee succeeded and its summary counted no executed case, and
   `fail` for every other non-pass. Each new lane's host probe (session
   bus or Docker) runs before its `start`; a refusal retains a
   refusal log and sends the delivered `stop KEY LOG`, which records that
   case and every later case of the lane `not_dispatched` with
   `evidence_incomplete_pre_dispatch`
   (`matrix.ex:161-186`). Once the host is fixed, the lane continues on the
   same commit, with `--resume-matrix` on `serenity` or the same
   `--join-matrix` on macOS, without dispatching a completed case again. The
   runner prints evidence unavailable and exits 2 for an unavailable or
   stopped case, or when the M7 wrapper exits 2, as it does when its writer
   open refuses `attempt_writer_contention` (`case_runner.ex:151-152`, `:236`,
   replacing the RED exit at `check-release.sh:466`), and exits 1 for a
   failure.

   Interruptions, replays and duplicates keep the delivered barriers:

   - An unsynced `start` is never acknowledged, so its lane never runs.
   - A runner killed, or an SSH connection lost, after a `started` reply
     ends the recorder's standard input once no process holds it; the
     recorder closes the writer at end of input (`matrix.ex:67`,
     `:123-124`), or the lock goes with its VM. Until then the recorder
     keeps the lock and every other invocation refuses. A dropped connection
     the `serenity` side has not noticed can hold it indefinitely; the remedy
     is to kill the remote `mix loopex.m7_matrix`, which is safe while it
     waits for input, since every acknowledged record is synced and the lock
     goes with its VM. The case stays `started` without completion, a
     consumed attempt: the campaign ends as item 1 states.
   - A failed copy is retried as item 4 states; a partial copy keeps its
     exclusive name and no retry or later attempt reuses it. Only when the
     retries are spent does `finish` record the case unavailable.
   - While a lost connection holds the `serenity` lock, every other
     invocation on either host refuses `attempt_writer_contention`
     (`attempt_writer.ex:215-221`), so two recorders never write.
   - A second `finish` of a completed case, with the same or another result,
     refuses `invalid_attempt_append`, because the case history admits no
     transition from `completed` to `completed` (`attempt_events.ex:566`,
     `attempt_writer.ex:557-566`), and nothing is appended.
   - An invocation of a lane that ended with every case passing answers
     `plan ended` and runs nothing (`matrix.ex:104`); one that ended in a
     failure refuses.
   - A writer checkout at another commit refuses before the index opens, and
     a join for a candidate the matrix never ran refuses
     `matrix_join_unavailable`. A case pin whose digest differs from its
     recorded history refuses `attempt_selection_pin_mismatch`
     (`attempt_events.ex:259-260`). A macOS lane selected on Linux refuses
     before staging (item 3), and a writer `--host` other than the writer's
     own host name refuses before the index opens (item 1).
8. **Proof.** In the fast check, with real index files, the real writer
   lock and real Git checkouts in temporary directories:

   - `apps/loopex_cli/test/m7_matrix_test.exs` (extended). Creation prints
     the designation's head line, and admission refuses
     `committed_attempt_head_unavailable` until the concept carries it; with
     the concept also carrying `m8-closure-1` lines at greater sequences, an
     `m8-closure-2` index admits against its own line alone. A wrong
     `--host`, or a dirty writer checkout or one at another commit, refuses
     before the index opens, for `--create` as for admission; a writer or
     host other than the designated one refuses
     `not_current_attempt_writer`. A `--join` lane for a candidate with no
     matrix record refuses `matrix_join_unavailable` and creates no lane; a join after a consumed matrix failure refuses; a
     changed case digest refuses `attempt_selection_pin_mismatch`.
     `unavailable` records `evidence_incomplete_post_dispatch` with its log.
     A `pass` whose log is missing, truncated or of another digest records
     `evidence_incomplete_post_dispatch` without it. A second `finish` of a
     completed case, pass after pass or fail after pass, refuses and leaves
     the index byte-identical; an ended lane answers `plan ended`; a second
     recorder on the index refuses `attempt_writer_contention`. A recorder
     in a separate OS process that is killed after its `started` reply, and
     one whose standard input closes there, each leave the case `started`
     and the lock free, and continuation refuses `consumed_lane_failure`.
   - `apps/loopex_cli/test/m7_matrix_runner_test.exs` (new). The runner's
     own `lane` and recorder helpers from `scripts/lib/release-lane.sh`, in
     a disposable tree as `scripts/test/check-release-test.sh` builds one,
     drive a real recorder in a separate OS process against a real index,
     with only the SSH transport replaced by that local process and a
     separate writer directory. No lane command runs before its `started`
     record is in the index; a copied log is recorded with the digest the
     runner sent; a copy that fails once is retried under a new name and
     the case passes, and one that fails every retry records the case
     unavailable; a lane that counts no case records `unavailable` and
     prints evidence unavailable, never PASS; and a host-probe refusal records `not_dispatched` for that
     case and the later ones, which continue on the same commit.
   - `apps/loopex_cli/test/m7_case_runner_test.exs` (extended). `--concept`
     admits against the named file's heads and refuses when that file has
     none for the index's campaign.
   - `scripts/test/check-release-test.sh` (extended). The macOS selection
     rules, the four new options' refusals, `--attempts-index` refused with
     any other selection, an M7 wrapper exit 2 printed as evidence
     unavailable with exit 2, and the final lines.

   The closure run itself proves the SSH transport.

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
| Root format number | Any change to a durable member, shape or encoding of a root, nested and delegated shapes included, advances `loopex-root-format N` in any release, a patch included, and existing roots are refused until a separately decided migration exists (D28); `root_format_vectors_test.exs` checks the golden vectors of format 1 against the real codecs and pins their digest to the number, so a codec change without a new number fails the fast check (ADR 0072) |
| Durable records and host ledger | Delivered M7 versions as the current format; the settled-attempt record and run terminal admit the `provider_sign_in_required` category; the format-1 session vectors include that admission; no older-reader or older-root promise |
| Backup layout and its records | New experimental current-format contracts under ADR 0072: `loopex_store_backup_capture_v1`, `loopex_store_restore_attestation_v1` and `loopex_store_restore_continuation_v1` |
| Restore transition | Accepted ADR 0051 with ADR 0072's two clause amendments: the commands are its operator front end, and the discard attestation form admits an older backup for a lost source. `Restore.restore/3`, beside the unchanged `restore/2`, takes one option that leaves the disposable helper job index out of its audit index, as adopt and backup do, while copying it under the complete manifest; `restore/2` refuses it as delivered. ADR 0051's walks and outcomes are unchanged. A latest-form plan's bytes are unchanged |
| Daemon protocol | `loopex.experimental/4` gains `daemon.readiness` in its ADR 0044 manifest's `methods` inventory, and the `provider_sign_in_required` reason, each with schema, vectors and pinned digests updated in place |
| Foreground protocol and embedded API | `loopex.experimental/3` gains the `provider_sign_in_required` reason. Under ADR 0073: the `chat_terminal_outcome` definition gains its `failed_reasons` list; `LoopexProtocol.Session.CompactResult` admits the category; `session-snapshot.v3.json`, `standalone-compact-result.v1.json` and `standalone-compact-completion.v1.json` each gain it in `failure.simple.categories`, with vectors; and ADR 0018's Model callback result union widens by `{:error, {:not_dispatched, "provider_sign_in_required"}}`, which every Model adapter's caller must accept. The embedded API is otherwise unchanged except an undocumented `Loopex.Runtime.create_session_with_genesis_detailed/4` and ADR 0072's `LoopexComposition.Restore.restore/3` beside the unchanged `restore/2` |
| Configuration | ADR 0049's schema version 1 and resolver; discovery and writers by ADR 0037, the daemon's reader by ADR 0071, the `oauth` form and `vertex` members by ADR 0073 |
| Credentials | Environment references unchanged; sign-in tokens in the operating system's keyring or an owner-only file under `<home>/auth/`, and gcloud's Application Default Credentials directory, separate by resolved path from every state root, backup, restore destination and available restore source under [ADR 0037's path-separation rule](../adr/0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation), checked before any store command reads or writes those paths, so no backup's complete copy contains them. Separation is that path rule only (D27): no mount table is read, and a mount of any kind that makes credential storage reachable inside a walked tree, or a credential file copied into a root, is outside the guarantee under ADR 0037's [operator limit](../adr/0037-host-configuration-and-path-discovery-technical.md#technical-0037-operator-limit): do not mount credential storage into or over a Loopex state root, backup or restore destination. The `adc` source reads gcloud's own file under ADR 0073's stated exception to its decision 3 (D20) |
| Existing commands | The foreground `chat` keeps its grammar and exit semantics. `run`, `resume`, `attach` and `sessions` keep theirs; with `--service`, `run` and `resume` start the service on demand |
| Daemon exit statuses | 65 to 110 unchanged; 111 to 115 (114 retired), 116 to 119, 120 to 123 and 124 (`root_adopting`) added, so the table uses every status 65 to 124 except 114 exactly once; they land in three blocks, the last being 120 to 124, so every interim table is gap-free |
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
The fast-check proof uses a real one (D24), with the workspace check
bypassed because an extracted workspace cannot match the recorded one: ADR 0072's
[retained M7 root](../adr/0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-m7-fixture),
written by the `v0.4.0` build at commit
`9fe9618b0fbd89bdbcd5fc7e75ab0a5abb1ebe20` and retained by W4 as a
repository test fixture. The product command is proved by the `m7-adopt`
release lane (D26) on a root the same build writes on a live workspace in
the release run.
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
