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
| [ADR 0037](../adr/0037-host-configuration-and-path-discovery.md#concept) | 2, 4; the `--service` start for 5 | [ADR 0003](../adr/0003-extension-contract-boundary.md#concept): one home-reading exception for `LoopexCli.Home`. [ADR 0049](../adr/0049-explicit-host-configuration.md#concept): `--config` optional when a home is selected, and `loopex ask` accepts it, taking only `providers` for the providers they name (D54, D57). [ADR 0044](../adr/0044-run-model-and-reasoning-configuration.md#concept), applied: `daemon.readiness` joins the `loopex.experimental/4` manifest's `methods` inventory and result definitions, and the manifest digest is recomputed by ADR 0044's recipe and pinned. Reuses ADRs 0031, 0032 and 0046 | Before the placement lock primitive's extraction with its link publication (step 2), `SignIn.Separation` (step 3), `LoopexCli.Home`, the configuration writers, `ServiceStart` with its service record, status 125, `Service`, `paths`, `doctor`, `daemon.readiness`, or `ask`'s `--config` in `AskOptions` and `Ask.prepare/2` |
| [ADR 0038](../adr/0038-installed-distribution-and-release-artifact.md#concept) | 1, 6; the installed refusal and restore step of 7 | [ADR 0003](../adr/0003-extension-contract-boundary.md#concept) obligation 4: "no compiler" read as "no build toolchain". Applies [ADR 0019](../adr/0019-host-owned-provider-protection.md#concept) and ADR 0034 to the relocated companion unchanged | Before the release definition in the umbrella `mix.exs`, `scripts/release/`, the launcher's installed mode, `loopex-verify`, `--relocatable` or `loopex version` |
| [ADR 0071](../adr/0071-daemon-attached-conversation.md#concept) | 4 (the service's configuration reader), 5 | [ADR 0049](../adr/0049-explicit-host-configuration.md#concept): nullable `trace` and `policy` in the status record. [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept): the activation ceiling, which counts helper children as decided on 2026-10-13, with any consequent [ADR 0046](../adr/0046-child-session-tool.md#concept) refusal-order clause ADR 0071 states. [ADR 0055](../adr/0055-remote-session-creation-options.md#concept): creation options on a helper-enabled service. Applies ADRs 0033, 0046, 0056 and 0069 | Before `daemon --config`, `AttachedChat`, `DaemonSession`, `ChatProjection`, the `ExitStatus` block 111 to 115, `Helper.bind_activation_permit/2`, or any helper-parent creation in the daemon |
| [ADR 0072](../adr/0072-store-readiness-marker-backup-and-restore.md#concept) | 3, 7 | [ADR 0051](../adr/0051-current-format-physical-restore.md#concept), two clauses: the absence of a backup CLI, and the latest-backup-only restriction relaxed by `--discard-later-work` for a lost source. M8's `Restore.restore/2` leaves the disposable helper job index out of its audit index (D29), which no ADR 0051 sentence governs; [ADR 0056](../adr/0056-host-helper-ledger-recipe.md#concept)'s complete helper-namespace audit is narrowly amended for it (D35). [ADR 0016](../adr/0016-configured-cancellation-observation.md#concept): `store adopt` may replace an executor ledger generation bound through the selected alias with a fresh-epoch generation bound to the physical path, carrying its open authority unchanged (D45, D48), the resource-pack receipts ledger only with an empty open index (D55). Takes the operator backup and restore work out of Proposed ADR 0036 | Before the `loopex-placement-v2` lock record and the `loopex_store_writer_v3` writer marker (D33, step 2), `RootFormat`, the marker checks in `Placement` and `compose/1`, `StoreAdmin`, `LoopexCli.Store`, the `RestoreCodec` discard form, the format-1 fixture test, the `ExitStatus` block 116 to 119, or status 124 |
| [ADR 0073](../adr/0073-provider-oauth-sign-in.md#concept) | 8; the sign-in precheck in 4 and the sign-in hint in 5 | [ADR 0018](../adr/0018-provider-attempt-authority-and-recovery.md#concept), [ADR 0021](../adr/0021-compacted-provider-accounting-provenance.md#concept) and [ADR 0043](../adr/0043-context-compaction-checkpoint.md#concept): the clauses ADR 0073 names for the sign-in refusal and the `chatgpt:` summary ceiling. [ADR 0019](../adr/0019-host-owned-provider-protection.md#concept): the host-held access token and the `token_exchange` and `model_list` invocations. [ADR 0029](../adr/0029-bounded-provider-failure-diagnostics.md#concept): the public `provider_sign_in_required` reason. [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept): `fatal:sign_in_route_lost` joins the closed `daemon.stopping` reasons (D42). [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept): custody rotation by a host refresher, the public reason for missing sign-in custody, and `:expired` for custody holding no value past its deadline. [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept): sign-in routes resolve from host-opened custody, the ephemeral startup option `:sign_in_routes`, the pre-call sign-in refusal, `ask`'s status-1 codes `sign_in_route_lost`, `provider_sign_in_required` and `sign_in_unavailable` (D38, D50), and the host-VM credential audience widened to refresh tokens, ID tokens and the code exchange in `ask` and `auth` (D37), whose one common exception text replaces at acceptance the seven copies ADR 0039 requires in the vision pair and `AGENTS.md` (D40), with the other vision credential passages qualified (D56). [ADR 0048](../adr/0048-host-provider-routing-and-credential-bindings.md#concept): the `oauth` form, `vertex` members, same-account live rotation, and its ephemeral clause: in the ephemeral profile a sign-in route resolves from custody its host opened, holding the access token while the host's routes run, while environment routes keep caller-only resolution. [ADR 0049](../adr/0049-explicit-host-configuration.md#concept): the `oauth` binding form and `vertex` members as additive members of schema version 1, durable chat's acceptance of an `oauth` binding beside `env`, and `provider_sign_in_required` as a failed terminal's reason. Also one sentence of Proposed ADR 0037 and this plan's credential non-goal. Its own decision 3 states the `adc` source as an explicit exception (D20) | Before any `SignIn.*` module other than ADR 0037's `SignIn.Separation`, binding-grammar change, Core category admission, schema or vector change, `loopex auth`, or the `ExitStatus` block 120 to 125, which also carries ADR 0072's 124 and ADR 0037's 125 |

Accepted decisions constrain M8 without being reopened beyond those named
amendments: [ADR 0051](../adr/0051-current-format-physical-restore.md#concept)
owns the restore transition, its inputs, limits and outcomes;
[ADR 0066](../adr/0066-owned-artifact-transfer-opening.md#concept) owns
transfer accounting; and
[ADR 0070](../adr/0070-pre-1-superseded-surface-retirement.md#concept) owns
the retired surfaces. Maintainer decisions amend accepted text. Directly,
for M8 only: D30 amends
[ADR 0065](../adr/0065-private-attempts-io-prerequisite.md#concept)'s
no-replacement-on-lost-acknowledgement clause and D49 its
refuse-until-resolved rule for a torn index, and D47 omits
[ADR 0057](../adr/0057-attempts-event-bodies.md#concept)'s authorization
step. Through ADR 0072, D35 narrows ADR 0056's helper-namespace audit and D48
ADR 0016's migration rule; through ADR 0073, D42 adds a `daemon.stopping`
reason to ADR 0032, and D37, D40 and D56 widen ADR 0039's host-VM
credential audience together with the vision text that repeats or
contradicts it.

The store engine decision (ADR 0036) and typed policy inputs (ADR 0035) are not
M8 prerequisites and are deliberately not linked here; the first follows from
the accepted proposal P2. No typed policy input, API-key file, keychain or
command source, or publication enters through these prerequisites. Public-name
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
| W1 Integration | `apps/loopex_cli`: `Home` (new), `ConfigWriter` (new), `ConfigOptions`, `ConfigInspection`, `ConfigFile`, `ServiceStart` (new), `LoopexCli.Service` (new), `Live`, `Daemon`, `HostOptions` (new), `Chat`, `ChatDriver`, `ChatProjection` (new), `ChatControl`, `AttachedChat` (new), `DaemonSession` (new), `DaemonClient` and the `LoopexCli` dispatch table; in the chat and `ask` drivers (`Chat`, `ChatDriver`, `Ask`, `DurableAsk`, `EphemeralAsk`), at W5's rejoin: `Chat` composing through `CredentialHost.open/3` and a borrowed plane; `LoopexCli.CredentialCache` passing bindings and the sign-in context to `open/3`; `ask`'s `--config`, whose file's `providers` apply to the providers they name while every other provider keeps `ask`'s environment route (`AskOptions`, `Ask.prepare/2`, D54, D57); D50's refusals, D52's selection-time refusal and D58's refusal of an `oauth` binding in foreground `run`, `resume` and `skill`; the stop on a lost sign-in route through a CLI `lost` function that shares `Interrupt`'s private `halt_owning_nothing/0` (`interrupt.ex:1719-1725`), made `halt_owning_nothing/2` taking its note and status, so it exits 1 (D38); and the graceful route stop on their normal exit (D41). `apps/loopex_daemon`: `Command`, `ExitStatus`, `Service` (with ADR 0071's stop-order steps and, at W5's rejoin, its route start in `start_binding_plane/1`, `component_kind/1`, its `:sign_in_routes` step and running class, D42), `ServiceReadiness` (new), `Request`, `SocketConnection`, `WireRecords`, `Owner`, `ConnectionRegistry`. `apps/loopex_protocol/priv/schema` and `priv/vectors`, `clients/node`. `LoopexComposition.Placement`'s lock primitive extraction, which writes a lock record whole under its owner handle's name and publishes it by linking that handle to the lock's name, never by writing in place (ADR 0037's lock publication). It writes the guard owner entry as the same v2 record, reads a v1 guard entry by liveness only, treats a v1 placement lock record or v1 guard entry, or a v2 Store writer marker, naming the reader's own OS PID as stale, judging a v2 record and a v3 marker by incarnation, and, holding the guard, removes every other `placement.lock.guard.claim-ID` whose leading PID the probe reports absent (ADR 0072's lock records). At step 2, before step 4's service record, the lock record becomes `loopex-placement-v2` (D33; `placement.ex:39`): the probe runs `ps -o lstart=` with `TZ=UTC0` beside `LC_ALL=C` (`placement.ex:555-557`), applied after the launch exclusions so no exclusion unsets it, `TZ` joining `LC_ALL` in `Loopex.LLM.ReqLLM.HostBindings`' `@reserved` (`host_bindings.ex:21`), so two commands under different `TZ` values agree on a live owner, and a v1 record is read by liveness only; `placement_probe_test.exs` gains a lock taken under `TZ=America/Los_Angeles` that a probe under `TZ=UTC` finds alive and does not reclaim, and D33's cross-version cases, which need the real `v0.4.0` build, are the `m7-adopt-lock` lane (ADR 0072). `Loopex.Store.Local.WriterLock`'s probe (`writer_lock.ex:316-319`) gets the same `TZ=UTC0`, `TZ` joins `LC_ALL` among its refused exclusion names, and `Loopex.LLM.ReqLLM.HostBindings` reserves `TZ` beside `LC_ALL` (`host_bindings.ex:21`, a file shared with W5); the writer marker becomes `loopex_store_writer_v3`, a v2 marker read by liveness only, because an embedded runtime writes a store without taking the placement lock (`loopex_cli.ex:1674-1679`), so a `v0.4.0` command asking for stale-writer recovery must never read a live M8 writer's marker as dead (D33; ADR 0072's lock records); `writer_lock_holder_test.exs` gains the same cross-`TZ` case; and `WriterLock.holder_status/1` (new, public) answers whether a marker's holder is live, for ADR 0072's restore check. The `readiness` member of the handle `LoopexComposition.Delegation.open/4` and `host/4` return (new at step 4) and `LoopexComposition.Delegation.Helper`'s readiness ETS table with its single writer (ADR 0037), with the classification code that keeps the failing session and code (ADR 0072's readiness code). The `scripts/check-release.sh` runner, `scripts/lib/release-lane.sh`, `scripts/attended-release.sh` (forwarding a repeated `--only` and the four macOS options of item 4 besides its eight M7 options, each of which it forwards at most once, `attended-release.sh:73-80`, with `scripts/test/attended-release-test.sh`), `Mix.Tasks.Loopex.M7Matrix` and `M7Evidence.CaseRunner` changes of the [release-check list](#technical-plan-release-check), with their tests, and in the same change the text they make untrue: the verification guide pair (including `docs/process/verification.md:43` and `:62-65`, where release lanes run under `--only` only unattended and the full check runs once), the milestone guide's closure-tooling step (`docs/process/milestones-technical.md:152-159`), `DEVELOPMENT.md:129-202`, which names the retained M7 attempts index and the removed `closure-incomplete` ending, and `AGENTS.md:188` and `:298-305` (the M7 attempts index, `--only` for unattended lanes only, and one release-check run); the `AGENTS.md` change is the maintainer's to approve. `VERSION` and `release_version` at step 8, with `DEVELOPMENT.md`'s version text. Current-state pages its own changes make untrue, each corrected in the change that lands it: `docs/operator/daemon.md:53-64` (credential only from `LOOPEX_PROVIDER_API_KEY`) with `daemon --config`, `docs/operator/daemon.md:339-356` (status table) with each `ExitStatus` block, `docs/operator/daemon.md:291-296` and `docs/developer/daemon-technical.md:98-99` (stop bound) with ADR 0071's stop-order steps, the sum gaining 60,000 ms with a sign-in route, 65,000 ms with a helper owner and up to 1,000 ms for the stopping mark (D44), `docs/developer/compatibility-surfaces.md:318` and `docs/operator/coding-sessions.md:626` and `:651` (`chat` requires `--config` and has no `--service`) with `Home` and `AttachedChat`, `docs/operator/daemon.md:237` (no `--config`), `docs/developer/daemon-technical.md:172` and `docs/developer/compatibility-surfaces.md:195` (the daemon's credential only from `LOOPEX_PROVIDER_API_KEY`) with `daemon --config`, `docs/operator/README.md:4` and `docs/developer/getting-started.md:12` (a source checkout only) with the first installed workflow, `docs/operator/runtime.md:190-200` and `docs/developer/runtime-and-embedding.md:1040-1046` (`loopex_store_writer_v2`) with the writer marker, and `docs/developer/compatibility-surfaces.md:309-317` (`ask`'s flags) and `docs/operator/getting-started.md:440-445` (durable `ask`'s credential) with `ask`'s `--config` | The first installed workflow |
| W2 Daemon helpers (W1's integrator, after the attached conversation) | `LoopexCli.ChatConfiguration`'s split into `helper_roles/1`, `helper_catalog/3` and `helper_parent_genesis/3`; `LoopexCli.HostOptions.helpers/1`; `LoopexComposition.Delegation.create_parent_detailed/7`, `Helper.bind_activation_permit/2`, `Helper.quiesce/1` and `Helper.create_parent/2`; in `Helper`'s reserve path, the permit refusal and the delivered `helper_index_unavailable` refusal, which today returns the state holding the `jobs` row added at `helper.ex:480` (`:515`), both returning the owner state as it was before `:480` (ADR 0071); `Loopex.Runtime.create_session_with_genesis_detailed/4`; helper hosting and activation counting in `LoopexDaemon.Service`, `Owner`, `ConnectionRegistry` (its one counted sum, `activations_counted/1`, used by client admission, the helper permit and the status report) and `SocketConnection.create_task/4` | After the first installed workflow, before the installed demonstration |
| W3 Packaging | The umbrella `mix.exs` `releases/0` and `installed_layout/1`; `scripts/release/` (`toolchain.env`, `build.sh`, `assemble.sh`, `check-layout.sh`, `write-manifest.sh`, `assert-linkage.sh`, `smoke.sh`, `linux/Dockerfile`, `linux/Dockerfile.smoke`) and the fast-check tests ADR 0038 [names](../adr/0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-failures); `apps/loopex_cli/bin/loopex`, including its crash-dump case extended from `ask` to `auth` (`bin/loopex:60-67`, D37), and `bin/loopex-verify`; `apps/loopex_llm_reqllm/lib/mix/tasks/loopex.provider.build.ex`'s `--relocatable`; `LoopexCli.ProviderLaunch.options/0` with its test seam; the `loopex version` module; the `installed-artifact` lane in `scripts/check-release.sh`, registered at step 6 after W4's and W5's rejoins, because its steps 5 and 6 run `store backup`, `store restore`, `auth status` and `auth logout` | The first installed workflow, with a locally built archive |
| W4 Backup and restore | `LoopexComposition.RootFormat`, `StoreAdmin` and `StoreAdmin.Codec` (all new); the marker step in `Placement.acquire/2` and `LoopexComposition.compose/1`; `Restore.IO`'s `root_inventory`, `backup_copy`, `{:adopt_manifest, root, max_total}` and `{:ledger_rebind, ledger_root, expected_sha256, bytes, mode}` operations; the `:ledger_placements` test override and the host-supplied catalogue check ADR 0072 names; `scripts/fixtures/m7-root-archive.exs`; the current-state text the store commands make untrue, corrected with them: `docs/operator/runtime.md:235-236`, `:248` and `:262-265`, `docs/operator/coding-sessions.md:706-709` and `docs/operator/how-a-run-works-technical.md:100-116`, whose root-contents table gains `loopex-root-format`; ADR 0037's `LoopexComposition.SignIn.Separation.check/1`, landing at step 3 before W1's `LoopexCli.Home`, and `StoreAdmin.restore/3`'s check of an available source with it (D27); `Restore.Audit`'s session-identifying failure and, with `Restore.Workflow`'s baseline check, `docs/operator/runtime.md` and `docs/operator/how-a-run-works-technical.md`, whose job-index refusal statements D29 makes untrue, corrected in the change that lands it; the unconditional omission of the disposable helper job index from the audit index in every mode, `restore/2`'s included (D29); the retained format-1 root `apps/loopex_cli/test/fixtures/root_format/format-1.tar` with its producer and `apps/loopex_cli/test/root_format_fixture_test.exs`; the retained M7-built root fixture under `apps/loopex_composition/test/fixtures/m7_root/` (D24); `Restore.Workflow`'s discard-form validation; `apps/loopex_composition/test/restore_helper_root_test.exs` (changed by D29); `store adopt`'s ledger rebinding of a root bound through an alias path (D45), which rebinds the resource-pack receipts ledger only with an empty open index, rewriting its path-derived executor identity (D55); `Loopex.Executor.Local.RestoreCodec`'s discard form; `LoopexCli.Store` (new) and the marker checks for `sessions` and `artifact`; the `m7-adopt` lane (D26), with `scripts/m7-adopt-lane.sh` (new), its one wrapped command (ADR 0072), and the `m7-adopt-lock` lane (D33, D34) in `scripts/check-release.sh`, with their `m7_adopt_child_audit_test.exs` and `test/support/m7_child_audit.ex`, the latter listed in `apps/loopex_composition/mix.exs`'s `test_ignore_filters` (`:16-23`) and `:m7_adopt` excluded at `test/test_helper.exs:153`; and `apps/loopex_cli/mix.exs`'s `test_ignore_filters` predicate (`:20`), widened to `test/fixtures/` for the format-1 producer | The marker first, before W1's daemon and CLI changes; adopt, backup and restore after the first installed workflow, before the installed demonstration |
| W5 Provider sign-in | `apps/loopex_llm_reqllm`: `Loopex.LLM.ReqLLM.SignIn.*`, the `Loopex.LLM.ReqLLM.InProcess.Guards` provider table, `HostBindings`, `NativeRequest`'s per-route header seal, the `chatgpt` mapping, `drain/5`'s reply ceiling, `in_process.ex`'s sign-in resolution, the guardian's custody-phase clause in `provider_bridge.ex` and, for `token_exchange`, its guardian and frame receiver made `:sensitive` and excluded from tracing, `CredentialCustody.resolve/1`'s deadline-first clause, the companion's `token_exchange` and `model_list` kinds, and `apps/loopex_llm_reqllm/test/support/fake_oauth_server.ex`, with `LoopexComposition.Model`'s `chatgpt` switch check and the configured-model and maintenance-model admission check of durable and ephemeral composition in `apps/loopex_composition`. `apps/loopex_composition`: every `LoopexComposition.SignIn.*` module except W4's `SignIn.Separation` (store, backends, refresh lock, `Route` edge), `LoopexComposition.CredentialPlane`'s start and registration of sign-in custody and `binding_plane/2`'s `sign_in_routes`, `LoopexComposition.CredentialHost.open/3`, `close/1` and its route keeper, `Edges`' plane check and its `provider_sign_in_required` refusal of an `oauth` `:provider_bindings`, `Ephemeral.start_session/1`'s `:sign_in_routes` option, and the `:sign_in_test_executables` seam. `apps/loopex` (Core): the `provider_sign_in_required` admission in `SessionCoordinator`, `ProviderAttempt` and `SessionState`. `apps/loopex_protocol`: `Session.Outcome` and `Session.CompactResult`. The delivered closed validators of a failed reason that must admit it: `Loopex.LLM.ReqLLM.InProcess.CleanupOwner` (`in_process/cleanup_owner.ex`), `LoopexComposition.Ephemeral.SessionOwner`, `LoopexCli.AskResult` (also its status-1 codes `sign_in_route_lost`, `provider_sign_in_required` and `sign_in_unavailable`, D38 and D50), `LoopexCli.DurableAsk.FollowReader`, and `clients/node/terminal-outcome.mjs` and `compact-result.mjs`. `apps/loopex_cli`: `LoopexCli.Auth` (new) and its sign-in hint function. The `real-sign-in-*`, `secret_service` and `macos_keychain` lanes in `scripts/check-release.sh` (D18). Current-state pages its changes make untrue, each corrected in the change that lands it: `docs/operator/runtime.md:436-439` and `docs/operator/coding-sessions.md:341` (`ask`'s and the commands' failure lines), `docs/developer/runtime-and-embedding.md:712-725` (`CredentialHost` and the ephemeral options) and `docs/developer/app-server-protocol-technical.md:400-401` (the `daemon.stopping` reasons, D42) | After the first installed workflow and after W1's `daemon.readiness` schema change; before the installed demonstration |

Shared files and their single owner:

- `LoopexDaemon.ExitStatus` and `apps/loopex_daemon/test/command_test.exs`:
  W1. The blocks land in this order, each once its ADR is accepted: 111 to
  115 (114 retired) under ADR 0071; then 116 to 119 under ADR 0072, at step
  3; then 120 to 125 together, ADR 0073's 120 to 123, ADR 0072's 124
  (`root_adopting`) and ADR 0037's 125 (`service_record_write_failed`, D31),
  at step 4 with the service record, before W4's adopt and W5's sign-in
  rejoin merge. Landing 124 and 125 with 120 to 123 keeps every interim table
  gap-free. At each step `command_test.exs` expects the cumulative set
  exactly: 65 to 115 without 114, then 65 to 119 without 114, then 65 to 125
  without 114. The daemon's mapping of `root_adopting` and its
  `daemon_root_format_test.exs` case land with 124; `store adopt`, the only writer of the `adopting`
  marker, merges after them.
- `apps/loopex_protocol/priv/schema`, `priv/vectors`, the pinned digest in
  `LoopexCli.DaemonClient`, `clients/node/contract-manifest.mjs` and
  `clients/node/daemon-client.mjs`: W1. `daemon.readiness` lands first; W5's
  failure reason and the `daemon.stopping` reason `fatal:sign_in_route_lost`
  (D42), with their vectors, schema test and Node client decoding, rebase on
  it, and the integrator lands the regenerated manifests and schema proof.
- `LoopexComposition.Placement`: W1 extracts the lock primitive into one
  shared private module before anything else uses it; W4 then owns
  `Placement.acquire/2`'s marker step; W5's refresh lock and W1's
  configuration-writer lock call the primitive.
- `LoopexComposition.SignIn.Separation`: W4 alone, landing with the marker
  at step 3 because its marked-ancestor rule reads ADR 0072's marker and
  W1's `LoopexCli.Home` (step 4) and W4's `StoreAdmin.restore/3` call it.
  W5's store and refresher call `check/1` on the context they were given
  and add no member. No walk calls it (D27).
- `LoopexComposition.Delegation` and `Delegation.Helper`: W1 lands the
  readiness table and the handle's `readiness` member at step 4, because
  `daemon.readiness` needs it; W2 adds `Helper.bind_activation_permit/2`,
  `Helper.quiesce/1` and the refusal order at step 6.
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
- **One restore.** The restore command calls the delivered
  `LoopexComposition.Restore.restore/2`, whose audit M8 changes to leave
  the disposable job index out of its index (D29), and `lookup/3`. It adds no second copy,
  audit, transition or entry point.
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
  a private session bus. The one contact with a real keychain is the
  read-only absence query of the macOS installed lane's and `m8-operator`'s
  removal steps, which writes nothing and asks only for the items of its
  own home (`-a <home-digest>:<route>`, ADR 0073); under the installed
  lane's temporary `HOME` it is a smoke of the removal procedure that
  cannot fail, and the keychain backend's proof is `macos_keychain`; the
  Linux installed lane signs in to nothing and makes no keyring query.

<a id="technical-plan-order"></a>
### Implementation Order

Concept: [Workstreams](M8.md#concept-plan-workstreams).

Each step names its first dependency; steps on one line may run in parallel
in separate worktrees.

1. **Acceptance.** The plan pair and each ADR it depends on, as listed in the
   prerequisites. The acceptance change also carries, for the maintainer's
   approval, D40's text edit: ADR 0073's common exception text replaces ADR
   0039's seven copies in `docs/vision.md`, `docs/vision-technical.md` and
   `AGENTS.md`, and ADR 0073's qualifiers of `docs/vision-technical.md`
   §12.7's three credential sentences and §6.1's custody cell and of
   `docs/vision.md` §12's credential sentence (D56). It also carries, for the
   maintainer's approval, the `AGENTS.md:188` and `:298-305` release-check
   text that W1 lands with its runner changes at step 2. Unrelated work does
   not wait.
2. **Foundation (W1).** Extract the placement lock primitive with the
   `loopex-placement-v2` record, and move the Store writer marker to
   `loopex_store_writer_v3` (D33); add the `ExitStatus` 111 to 115 block
   once ADR 0071 is accepted. Land the recorder and runner changes of the
   [release-check list](#technical-plan-release-check), each new lane's
   registration landing later with its lane, then create campaign
   `m8-closure-1` on `serenity` and commit its anchor line (item 1). From
   here on the indexed selections item 4 admits record in it; every other
   pre-merge `--only` lane runs unindexed, as selection-only evidence.
3. **Root marker and separation (W4)** under ADRs 0072 and 0037:
   `RootFormat`, `Placement.acquire/2` and
   `compose/1` admission, the read-only checks, daemon statuses 116 to 119,
   every existing fixture that opens a root brought to a marked root, and the
   whole of `SignIn.Separation`, which W1's `Home` calls at step 4. The
   retained M7-built root fixture (D24) is produced here, so the marker
   refusal tests run against it. **Packaging (W3)** starts in parallel under
   ADR 0038.
4. **Home and service (W1)** under ADRs 0037 and 0071: `Home`, writers,
   `daemon --config`, `ServiceStart` with the service record, its stopping mark (D44) and the
   `ExitStatus` 120 to 125 block, the helper
   owner's readiness table and its single writer, `daemon.readiness`,
   `service`, `paths` and `doctor`, ADR 0071's stop-order steps
   `:helper_quiesce`, stopping the slice loop, and `:delegation`, the slice
   loop starting after composition with no permit until step 6, then
   `AttachedChat` with `DaemonSession` and `ChatProjection`. **Provider sign-in (W5)** starts in parallel under ADR
   0073 with the token store, refresh, routes and the reply ceiling, behind
   the fake OAuth server.
5. **First installed workflow.** W1 and W3 rejoin: install a locally built
   archive, `init`, `chat --service`, detach, reconnect, `service stop`.
6. **Daemon helpers (W2)** under
   ADR 0071 decision 10 and its activation counting, adding
   `Helper.bind_activation_permit/2` and `Helper.quiesce/1`, which completes
   `:helper_quiesce` for helper creation; from here the slice loop starts
   after the permit bind. **Adopt, backup and restore
   (W4)**, after status 124, then the retained format-1 fixture, its
   producer and `root_format_fixture_test.exs`, which need `store backup`
   to produce the fixture's capture. **Sign-in rejoin (W5)**: the public reason in
   Core and the protocol, the start-on-demand precheck, the daemon's use of
   statuses 120 to 123, its `:sign_in_routes` stop step and the
   `sign_in_route: :sign_in_route_lost` running class (D42) with
   `daemon_sign_in_test.exs`, the
   route-lost stop and graceful route stop in chat and `ask` (D38, D41), and
   the hints. After the W4 and W5 rejoins, the `installed-artifact` lane is
   registered (W3), since its steps 5 and 6 run their commands; W5's
   pre-merge `real-sign-in-*` runs follow that registration, since they use
   its archive (item 3).
7. **Failure matrices.** Process races, fault cuts, restart and signal cases
   for every workstream, on both toolchain pairs.
8. **Demonstration and candidate.** `VERSION` and the runner's
   `release_version` advanced to `0.5.0` in one commit, documentation and the
   evidence scaffold, then the closure matrix of D18: the full release check
   on `serenity`, which runs `installed-artifact` for `linux-x86_64`,
   `secret_service`, `cross_uid`, `m7-adopt`, `m7-adopt-lock` and the
   attended `real-sign-in-*` lanes, less any lane deferred before the
   candidate under D36, with `real-sign-in-anthropic` passing by refusing
   (D16), and on macOS arm64
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
| ADR 0051 delivers host-embedded `LoopexComposition.Restore.restore/2` and `lookup/3`; the host owns backup creation, the capture record, plan construction and the attestation; there is no command | `store backup` produces the backup and capture record; `store restore` builds the plan from the operator's statements and calls `restore/2`, whose audit M8 changes to leave the job index out of its index (D29, D35), and `lookup/3` | ADR 0072 |
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
daemon change; `m7-adopt` and `m7-adopt-lock` (D26, D33, D34); and the
attended `real-sign-in-openai`, `real-sign-in-gemini`,
`real-sign-in-gemini-adc` and `real-sign-in-anthropic` lanes. On the macOS arm64
host the same candidate runs three required lanes with `--only`:
`macos_keychain`, `installed-artifact` for `darwin-arm64`, and `m8-operator`,
the attended outcome-6 record. Each macOS lane is recorded in the same M8
index as a required closure lane, so closure is the `serenity` full PASS and
a PASS of each of the three. A required lane that reports evidence
unavailable blocks closure and is never a pass. Under D36 a deferral of
`real-sign-in-openai` or `real-sign-in-gemini` is the maintainer's decision
before the candidate, which then omits that lane from the runner's
full-matrix lane list, so it is not pinned, and ships that provider's
sign-in route disabled, refused `sign_in_unavailable` as `claude:` is (D43);
a deferred Google client disables only `vertex:`'s `loopex` source, and
`real-sign-in-gemini-adc` still runs. `real-sign-in-anthropic` is always
present. Both hosts' complete outputs are retained.

| # | Fast-check proof | Release check |
| --- | --- | --- |
| 1 | The existing escript, provider-companion and launcher suites stay green with the relocatable launch pair; the refusal proofs ADR 0038 [names](../adr/0038-installed-distribution-and-release-artifact-technical.md#technical-adr-0038-failures): `scripts/test/release-artifact-test.sh` for the verifier, layout, linkage and launcher refusals, `apps/loopex_cli/test/provider_launch_test.exs` and `version_command_test.exs`, and `apps/loopex_llm_reqllm/test/provider_build_test.exs` (extended) for `--relocatable`; `apps/loopex_cli/test/service_start_test.exs` proves the installed command is resolved from the escript's own location | `installed-artifact` (ADR 0038): build with pinned inputs and the linkage table, manifest and verifier, a quarantined download cleared by the documented step on macOS, clean-host assertions, loaded-image probe and `loopex version`, with every Mix, Hex and Rebar step resolved from the pinned toolchain's `PATH` into writable build-only locations, on `darwin-arm64` and in a clean Ubuntu 22.04 `linux-x86_64` container. The closure matrix (D18) runs it inside the full release check on `serenity` and in [item 4](#technical-plan-release-check)'s single indexed macOS invocation |
| 2 | `apps/loopex_cli/test/home_test.exs`, `config_inspection_test.exs` (extended), `config_writer_test.exs` | Installed lane step 3 |
| 3 | `apps/loopex_composition/test/store_backup_test.exs`, `store_restore_command_test.exs` (both attestation forms, `--resume`, every refusal, the lookup answer after an unresolved result), `restore_workflow_test.exs` (extended: a backup holding the helper job index committed by `restore/2` with that index copied byte for byte and in every manifest, while a non-job-index unknown member under `delegation/` still refuses `invalid_current_history`), `store_backup_test.exs` also proving that backup writes nothing to the job index and copies it, `restore_helper_root_test.exs` (changed: its job-index damage case commits, D29), `delegation_readiness_code_test.exs`; `apps/loopex_executor_local/test/restore_codec_test.exs` (extended); `apps/loopex_cli/test/store_command_test.exs`; `apps/loopex_daemon/test/readiness_closed_root_test.exs` | Installed lane step 5, the restore half |
| 4 | `apps/loopex_cli/test/service_start_test.exs`, `service_command_test.exs`, `service_detach_pty_test.exs`, `live_service_test.exs`, `daemon_configuration_test.exs`; `apps/loopex_daemon/test/readiness_method_test.exs`, `readiness_slice_test.exs`, `command_test.exs` (extended); `apps/loopex_cli/test/service_status_test.exs`; the Node contract lane decoding `daemon.readiness`. Under ADR 0037: readiness asked while a helper classification slice is held answers within 1,000 ms with a truthful `classifying` state from a nonblocking source, without a second writer of helper truth; `service status` emits one closed JSON result from its named reads, including helper activations; the `ExitStatus` table uses every status 65 to 125 except the retired 114 exactly once | Installed lane step 4's status and diagnostic commands |
| 5 | `apps/loopex_cli/test/attached_chat_grammar_test.exs`, `attached_chat_test.exs`, `attached_chat_detach_test.exs`, `attached_chat_signal_test.exs`, `attached_chat_lease_test.exs`, `attached_chat_reconnect_test.exs`, `live_daemon_test.exs` (extended), `daemon_helpers_test.exs`, `daemon_helper_restart_test.exs`, `chat_configuration_test.exs` (extended), `daemon_helper_activation_test.exs`, with ADR 0071's helper-child activation-counting cases, including the helper permit's atomic registry operation at the real `ConnectionRegistry` boundary (an activated-without-session and an unknown disposition, preserved through a post-create parent-binding failure) and the one counted sum in both directions (held permits refuse a client reservation `activation_ceiling_reached`, and client activations refuse a permit); `apps/loopex_composition/test/delegation_activation_permit_test.exs`, `delegation_create_parent_detailed_test.exs`; `apps/loopex_daemon/test/helper_activation_registry_test.exs`, `helper_parent_activation_test.exs`, `helper_route_guard_test.exs` (extended); `apps/loopex/test/runtime_create_with_genesis_detailed_test.exs` | Attended: the reconnect case and `m8.service-review` in the outcome-6 record |
| 6 | — | `installed-artifact` steps 1 to 6 on each host with complete output and archive evidence; the attended record, `m8-operator` in [item 4](#technical-plan-release-check)'s single indexed macOS invocation, by an identified operator in a separate user account, following the runbook through install, `chat --service`, close and reconnect, `m8.service-review` (M7's `m7.review` profile through the service, a detach while a helper runs, and `service stop` during a second helper with the stop-only result after restart), backup and restore without the retained-root refusal, which the unattended lane proves, and removal, which runs `loopex auth logout` for every signed-in route before deleting anything and then asserts, by the read-only per-home query, that no Loopex keychain item of that home remains; the Linux installed lane signs in to nothing and makes no keyring query |
| 7 | `apps/loopex_composition/test/root_format_test.exs` (concurrent marker publication with a deterministic gate at the link-before-unlink cut), `placement_root_format_test.exs`, `composition_root_format_test.exs`, `store_adopt_test.exs` (D17: the `adopting` marker refused by `admit/1`, `Placement.acquire/2`, `compose/1` and `StoreAdmin`'s backup and restore, `--old-writer stopped` required, a real `Placement.acquire/2` in a separate OS process attempted immediately after the `adopting` publication refused while adopt holds the lock and attempted immediately after the rename admitted only after adopt releases, two concurrent adopters of which exactly one proceeds, a lock-taking writer in a separate OS process refused while adopt holds the lock (the daemon's 124 and 76 at the same hooks in `daemon_root_format_test.exs`), the synthetic writers that take no lock labelled as non-cooperating writers, an old-build writer before and after the audit manifest, a kill before the rename and `root_changed` leaving `adopting`, a kill after the rename leaving a committed current root, a rerun redoing the full audit) and, on the retained root the `v0.4.0` build wrote (D24), refusal by `admit/1`, `Placement.acquire/2`, `compose/1` and `store backup` with the root byte-identical, then an adopt through `StoreAdmin.test_adopt/3` with the workspace reference and ledger placement recorded at production, whose full audit passes and which changes nothing but the marker: the audit-and-marker proof with the workspace check bypassed; `apps/loopex_cli/test/root_format_fixture_test.exs` (the retained format-1 root and the retained M7 root through the full audit, exact re-encoding by the pure codecs and the named boundary checks; D28); `apps/loopex_cli/test/store_marker_entrypoints_test.exs`; `apps/loopex_daemon/test/daemon_root_format_test.exs`; `apps/loopex_composition/test/placement_probe_test.exs` and `apps/loopex_store_local/test/writer_lock_holder_test.exs` (both extended: the cross-`TZ` cases of D33); in `store_adopt_test.exs`, an alias-bound `receipts` ledger rebound by adopt (D45), with kill cuts around the rebind and `ledger_path_mismatch` for a moved or copied ledger, and an alias-bound `resource-packs/receipts` ledger rebound with its executor identity rewritten when its open index is empty, a resource import then succeeding through the physical path, and refused `ledger_path_mismatch` naming it when its open index is not (D55) | Installed lane step 5: the retained M7-written root (D24) refused by name and byte-identical, and a backup taken by the candidate restored under it and served. `m7-adopt` in the `serenity` full check (D26), the product path: as host prerequisites before the case is recorded (D34), the `v0.4.0` release built in a temporary tree writes and stops a root on a live temporary workspace with a conversation and one helper run, and the shape precheck reads it; then the recorded case: the candidate's own `loopex store adopt --old-writer stopped` adopts it with no test seam, and the candidate's `doctor` reports `marker: current`, its offline `sessions` lists the conversation, the only session the M7 build catalogued, a read-only audit (`m7_adopt_child_audit_test.exs`) checks the helper child's journal and terminal record against the helper run log, and every M7 record stays byte-identical; then `m7-adopt-lock`, ADR 0072's three `m7_adopt: :lock` cases: D33's lock records in both directions and the `v0.4.0` Store's refusal of a `loopex_store_writer_v3` marker. A failed build stops both lanes; a failed M7 write, or a shape check that answers `unavailable` or prints no verdict line, stops `m7-adopt`; a failed time-zone precondition stops `m7-adopt-lock`; each is a pre-start stop, never a candidate failure, recording the later cases of the lane `not_dispatched` too, all resumable on the same commit, as ADR 0072's [`m7-adopt` lane](../adr/0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-m7-adopt) states |
| 8 | `apps/loopex_llm_reqllm/test/sign_in_profiles_test.exs`, `sign_in_routes_test.exs`, `chatgpt_reply_ceiling_test.exs`, `provider_bridge_test.exs` (extended), `sign_in_id_token_test.exs`; `apps/loopex_composition/test/sign_in_adc_test.exs`, `sign_in_store_test.exs`, `sign_in_refresh_test.exs`, `credential_plane_test.exs` (extended), `chatgpt_summarizer_test.exs`, `sign_in_model_admission_test.exs`; `apps/loopex/test/sign_in_required_settlement_test.exs`. Under ADR 0073 these cover: ID-token signature verification against the provider's JWKS (forged, unknown-key and rotation negatives) and the validated subject paired with the token generation, refusing a mismatch in either direction after a different-account write cut and a restart before metadata publication; the ADC source and Google's refresh-response merge; one shared streaming reply ceiling proved through both the companion and the in-process caller, summarization included; and the terminal, no-accounting sign-in refusal on any legal attempt, including a route that becomes unavailable between attempts. The auth directory, the ADC directory and every state root, backup, destination and available restore source stay separate by resolved path under [ADR 0037's path-separation rule](../adr/0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation) (D27), refused before any token or root write, with overrides and a changed `HOME`, which `auth_separation_test.exs` proves with a credential-shaped canary; `apps/loopex_protocol/test/sign_in_required_vectors_test.exs`, `session_v2_schema_test.exs` (extended: the `daemon.stopping` reason `fatal:sign_in_route_lost`, D42); `apps/loopex_cli/test/auth_command_test.exs`, `daemon_sign_in_test.exs`, `ask_sign_in_test.exs` (with `ask`'s use of the selected file's `providers` for the providers they name and an unnamed provider keeping its environment route, D54 and D57), `sign_in_route_lost_test.exs`; `apps/loopex_daemon/test/command_test.exs` (extended); the Node client decoding the new vectors. The tagged `sign_in_keychain_test.exs` (`:macos_keychain`, temporary keychain) and `sign_in_secret_service_test.exs` (`:secret_service`, under `dbus-run-session`) are excluded from the fast check and run in release lanes | `macos_keychain` in [item 4](#technical-plan-release-check)'s single indexed macOS invocation and `secret_service` in the `serenity` full check (D18), each required to execute its cases. Mounts are outside the separation guarantee (D27), so no release lane creates one. Attended, in the `serenity` full check, and with `--only` before a merge that changes their boundary (D18), four script lanes each run ADR 0073's numbered steps under a temporary `HOME` with `--store file` and end `<lane>: PASS steps=N`: `real-sign-in-openai`, `steps=5`, and `real-sign-in-gemini`, `steps=4`, each gated on its provider's client, the OpenAI lane recording its model list non-empty and naming the lane's model at both logins (D25) and verification items 11 to 15; and, ungated (D16, D43), `real-sign-in-gemini-adc`, `steps=3`, its own pinned case, which needs no Google client and records verification item 7, and `real-sign-in-anthropic`, `steps=1`, refused `sign_in_unavailable` with nothing written until a sanctioned registration exists, that tested refusal being the disabled route's proof under D16. No real sign-in lane uses a keychain or the Secret Service. Tokens are redacted from retained outputs |

ADR 0073's sixteen
[verification items](../adr/0073-provider-oauth-sign-in-technical.md#technical-adr-0073-verification)
each carry their own disposition there. Those settled by a lane or test are
checked where they land and recorded there: items 11 to 15 by
`real-sign-in-openai`, item 7 by `real-sign-in-gemini-adc`, and item 16 by
the tagged `sign_in_keychain_test.exs`. Items 2 and 5 are settled by the
provider actions [below](#technical-plan-open), which gate only the
`real-sign-in-openai` and `real-sign-in-gemini` lanes. None becomes a silent
default.

Under D16, closing outcome 8 requires positive proof from
`real-sign-in-openai`, `real-sign-in-gemini` and `real-sign-in-gemini-adc`.
The deliberately disabled Anthropic route is proved by its tested refusal in
`real-sign-in-anthropic`, which needs no deferral. A pinned lane whose client
is unavailable is evidence unavailable, not a pass. Closing outcome 8 without
a provider's positive proof needs that lane's deferral, decided before the
candidate (D36), and the provider's route then ships disabled (D43).

The two repository checks apply with the release-check changes below and the
closure matrix above. The evidence page is `docs/evidence/M8-closure-runs.md`,
created and indexed on its actual candidate, with complete immutable outputs
outside the repository. Under the M7
[scaffold rule](M7-technical.md#technical-plan-evidence) it fixes the
campaign and genesis digest of the M8 index and the committed pre-candidate
head digest and count, and predeclares `Pending` slots for the index path,
the final head digest and count, and one cell holding the count and SHA-256
of the ordered list of (run root, invocation-log reference) entries across
every `serenity` and macOS run root of the closure matrix (each `serenity`
invocation's `$retain/m7-runs` and each macOS invocation's
`--writer-retain`), retained outside the repository. For each campaign that
ended before the candidate's (D30, item 1 below) it holds one row: the ended
index's path, its final head digest and count (its last complete record
when its tail is torn, D49), the candidate commits it
recorded, and the SHA-256 of its unresolved-case list, whose lines the page
lists as unresolved; the successor's `campaign_succession` record names the
same head and list (D47). Those rows name exactly the campaigns with an
`index-head:` line in `docs/plans/M8.md` other than the closing one, and the
closing campaign recorded no candidate those rows name; the closure review
checks both. No case of an ended campaign is counted toward closure.

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
Line numbers are those of `main` (`213965e6`), which this branch leaves
unchanged (`git diff main m8 -- apps scripts` is empty); `matrix.ex` below is
`loopex.m7_matrix.ex`.

1. **M8 campaign and its committed anchor.** The full matrix and every
   indexed M8 lane take `--attempts-index FILE` naming the current M8 index,
   first campaign `m8-closure-1`. Like every index, it starts with the delivered genesis
   (campaign and codec version 1) and writer designation (writer
   `maintainer-serenity`, host `serenity`, ownership epoch 1)
   (`attempt_events.ex:47-48`); its only other header is a later
   campaign's succession record below, and neither the concept file nor the
   release label is an index member. It is created once
   on `serenity`, from a clean checkout of the M8 branch, by
   `mix loopex.m7_matrix --create --campaign m8-closure-1 --attempts-index
   FILE --writer maintainer-serenity --host serenity --markers DIR
   --checkout DIR --candidate SHA`.
   `--create` takes its campaign from `--campaign` instead of the delivered
   `campaign/0`, which reads the M7 fixture manifest (`matrix.ex:269-274`);
   it takes no `--case` and admits no lane, writes its records through
   `AttemptWriter.create/4`, and prints `index-head: CAMPAIGN N SHA256` with
   its last record's sequence and digest: `2` and the designation for
   `m8-closure-1`, `3` and the succession record for a later campaign. A
   `--create` that does not print that line leaves a file no committed line
   anchors; it is retained aside unchanged and `--create` runs again at a new
   path with the next campaign number, so no committed line can anchor the
   torn file, whose genesis names the skipped number; a skipped number is
   never a predecessor, and a campaign whose only lower numbers are skipped
   is the first and carries no succession record. The next commit appends that line to
   `docs/plans/M8.md`'s Progress and Evidence section, below its table, as
   the M7 plan places its heads. Until that commit is checked out, every
   admission refuses `committed_attempt_head_unavailable`
   (`attempt_heads.ex:81-82`). From then on the M7 plan's
   [head-recording rule](M7-technical.md#technical-plan-evidence) applies
   with `docs/plans/M8.md` as the Concept file, except its succession
   sentences, which D30, D47 and D49 replace, and except that the campaign
   comes from `--campaign`, not a manifest, and a predecessor
   campaign's lines are checked once, by `--create --predecessor` below,
   against the head its succession record binds, and not at admission: the commit after
   an indexed lane ends or a matrix stops appends its head, and a completed
   closure matrix's final head goes only into the evidence scaffold's
   `Pending` slots named above.

   Succession is a fresh campaign (D30) that carries ADR 0057's succession
   record (D47). These are the maintainer's 2026-10-14 amendments, for M8
   only, of ADR 0065's no-replacement-on-lost-acknowledgement clause
   ([technical](../adr/0065-private-attempts-io-prerequisite-technical.md#technical-adr-0065-decision),
   lines 45-50) by D30, and of its refuse-until-resolved rule for a torn
   index by D49; and of ADR 0057's succession
   ([technical](../adr/0057-attempts-event-bodies-technical.md#technical-adr-0057-records),
   lines 107-114) by D47, which omits only its authorization step: no
   `reviewed` or `authorized_next_candidate` record is written, and no
   production code appends one. A consumed non-pass (`fail`, `unavailable`,
   or a `started` case never finished, including one whose `started` reply
   was lost) ends campaign `m8-closure-N`. In the ended index every new lane
   then refuses `post_head_consumed_case` until a head after that case is
   committed (`attempt_events.ex:256-257`); after it, the failed lane
   refuses `prior_failure_unauthorized` on every later candidate (`:283`,
   `:377-382`), its continuation `consumed_lane_failure` and a join to its
   matrix `consumed_matrix_failure`. Closure needs a pass of every lane on
   one candidate and matrix (item 4), so it cannot complete there. An index
   that ends in an incomplete tail, from a recorder killed mid-append, also
   ends its campaign, since the delivered writer refuses to open it
   (`attempt_writer.ex:605-606`); D49 lets it be succeeded.

   The next candidate gets a new index instead, created on `serenity` from a
   clean checkout whose `docs/plans/M8.md` carries campaign N's final
   `index-head:` line, by the `--create` above with `--campaign
   m8-closure-<N+1>`, `--concept` that file and `--predecessor FILE`, FILE
   the ended index. The recorder first binds FILE's lock port, read from
   `FILE.lock` as the writer reads it (`attempt_writer.ex:215-232`), refusing
   `attempt_writer_contention` while another process holds it, and holds it
   until it exits; once the checks below pass, and before it writes
   anything else, it creates `FILE.ended`, or finds it left by an earlier
   `--create` killed after creating it. It reads FILE's bytes without
   opening its writer and replays them with the delivered codec, which
   answers an incomplete tail with the last complete record and the tail's
   exact bytes (`attempt_frames.ex:109-110`); the records before a torn tail are replayed and the tail is admitted (D49). Beside
   the new index, each created exclusively, it writes the
   unresolved-case list, one line `<lane> <case> <attempt> <sequence>` for
   each case whose last record is `started`, and for a torn tail a last
   line `torn-tail <offset> <length> <SHA-256>` naming those bytes, which
   stay in FILE; and a disposition record naming campaign N, the consumed
   non-pass cases or torn tail that ended it, D30, D47 and D49.
   `AttemptWriter.create/4`'s delivered `succession:` option
   (`attempt_writer.ex:122`, `:247-258`) then writes ADR 0057's
   `campaign_succession` record third: `predecessor_head` is campaign N's
   greatest committed head in `--concept`, which must be FILE's last
   complete record, and `prior_rows`,
   `unavailable_interval` and `disposition` name the ended index, the
   unresolved-case list and the disposition record, each by path and
   SHA-256. The codec admits that record (`attempt_events.ex:709-714`),
   replay keeps it as the index's succession (`:638-645`), and
   `m7_attempt_writer_test.exs:65-100` proves both; admission reads nothing
   from it, so this `--create` check is M8's form of the M7 rule that checks
   a predecessor campaign's lines against the succession's bound head
   ([M7 technical](M7-technical.md#technical-plan-evidence)). The new campaign admits against its own anchor line, since
   `AttemptHeads.select/2` ignores the earlier campaign's lines
   (`attempt_heads.ex:58-63`), and nothing is imported, so every case runs
   again. The ended index is retained unchanged: the recorder and
   `CaseRunner`, once their writer has opened an index and holds its lock,
   refuse `attempt_campaign_superseded` before admission, appending nothing,
   when `FILE.ended` exists beside it. Its unresolved cases
   are listed on the evidence page's row for that campaign, never counted. A
   new campaign never runs on a candidate an ended campaign recorded; the
   closure review checks the candidate against those rows.

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
2. **Release version.** `release_version` (`:110`) becomes `0.5.0` in the
   step-8 commit that advances `VERSION`, so the pre-merge lanes of steps 2
   to 7 keep passing the extraction check (`:329`) at `0.3.0`. The runner
   also refuses before staging when the checkout's `VERSION` differs from
   `release_version`. The index pins no version.
3. **Lane registration.** `--only` (`release-lane.sh:21`) admits
   `installed-artifact`, `secret_service`, `macos_keychain`,
   `real-sign-in-openai`, `real-sign-in-gemini`, `real-sign-in-gemini-adc`,
   `real-sign-in-anthropic`, `m7-adopt`, `m7-adopt-lock` and `m8-operator`.
   `secret_service` and `cross_uid` refuse a
   selection on a host other than Linux, and `macos_keychain` and
   `m8-operator` on a host other than macOS, before staging. A
   `real-sign-in-*` selection also requires `--only installed-artifact` in
   the same invocation, which runs first, and otherwise refuses before
   staging. Each `real-sign-in-*` lane checks its host prerequisites before
   its `start`: the compiled client of `real-sign-in-openai` and
   `real-sign-in-gemini`, a browser for the attended login, and `gcloud` for
   `real-sign-in-gemini-adc`; a missing one is a pre-start `stop` (item 7),
   evidence unavailable. The full
   matrix's lane list (`:240-246`) gains `installed-artifact`,
   `secret-service`, `real-sign-in-openai`, `real-sign-in-gemini`,
   `real-sign-in-gemini-adc`, `real-sign-in-anthropic`, `m7-adopt` and
   `m7-adopt-lock`, in that order, every `real-sign-in-*` after
   `installed-artifact`, whose archive they use (item 5), beside the
   delivered `cross-uid`, which stays a
   full-matrix lane. `m7-adopt` (D26), which W4 owns, is
   unattended and runs ADR 0072's
   [product-path adoption](../adr/0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-m7-adopt):
   it builds the `v0.4.0` commit `9fe9618b0fbd89bdbcd5fc7e75ab0a5abb1ebe20`
   in a temporary tree under the current toolchain pair, which that tag's
   `.tool-versions` names; runs its chat under `with_m7_credentials`, since
   the M7 build has no credential-free chat provider; and runs the
   candidate's read-only shape precheck; `m7-adopt-lock` also checks ADR
   0072's time-zone precondition. These are host prerequisites run before
   the lanes' `start` (D34), and their provider calls are not
   attempt-recorded. A failed build stops both lanes, a failed M7 write or
   a precheck that reports `unavailable` or prints no verdict line stops
   `m7-adopt`, and a failed time-zone precondition, checked before
   `m7-adopt-lock`'s `start`, stops `m7-adopt-lock`, each a pre-start `stop`
   (item 7) that, as every pre-start stop does, also records the later cases
   of the `release-matrix` lane `not_dispatched` (`matrix.ex:161-186`), all
   resumable on the same commit. Two recorded lanes follow, each
   under `without_credential`: `m7-adopt`, a script lane over the
   candidate's adopt, `doctor`, offline `sessions` and the read-only child
   audit, with 3 steps, and `m7-adopt-lock`, an ExUnit lane whose expected
   count is 3, ADR 0072's three `m7_adopt: :lock` cases: D33's lock records
   in both directions and the `v0.4.0` Store's refusal of a
   `loopex_store_writer_v3` marker. `release_needs_provider`
   (`release-lane.sh:169-175`) also answers yes for `installed-artifact` and
   `m7-adopt`, and for them the runner's presence check (`check-release.sh:65-68`)
   also requires `OPENAI_API_KEY`, which `with_installed_credentials` and
   `with_m7_credentials` export. Each lane must execute its stated case or
   step count (item 7): `installed-artifact` 6, `m8-operator` 1,
   `real-sign-in-openai` 5, `real-sign-in-gemini` 4,
   `real-sign-in-gemini-adc` 3 and `real-sign-in-anthropic` 1, as ADRs 0038
   and 0073 state them. A lane that executes none, or whose host refuses its session
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
   Closure is read from the current campaign's index alone: on one
   candidate and matrix, every case of the `release-matrix` lane, of the M7
   conversation lanes and of `macos-closure` completed `pass`.
5. **Attended lanes.** `m8-operator` and the four `real-sign-in-*` lanes are
   attended. Like the delivered attended rows (`:372-374`), they keep the
   invoking terminal as standard input and read any manifest on another
   descriptor; each refuses before staging, as evidence unavailable, when
   standard input is not a terminal. Their complete transcripts pass through
   the lane redactor into the retained directory, and the index records each
   transcript's SHA-256 when the lane finishes. The delivered redactor takes
   its values on descriptor 3 when it starts (`release-lane.sh:297-305`), so
   the token values a `real-sign-in-*` lane reads from its file store after
   login and each refresh (ADR 0073) cannot reach it. Such a lane therefore
   keeps the operator's interaction on the terminal and writes its
   transcript to an owner-only file in its temporary `HOME`; at its end it
   passes that file through a second redactor run, given those values on
   descriptor 3 and applying ADR 0073's JWS-shaped pattern, writes only that
   run's output to standard output, deletes the file and, when every step
   passed, prints its `PASS steps=N` line last, so the redacted transcript
   ends with it. `m8-operator`'s record is
   made in the separate macOS user account ADR 0038 names: the lane hands
   that account the verified archive, waits at the terminal while the
   operator follows the runbook there, then asks the operator for a
   verdict, `pass`, `fail` or `withheld`. For `pass` or `fail` it takes the
   record's transcript and writes it to the lane command's standard output,
   so it passes through the redactor into `$retain/m8-operator.log` before
   that log's `lane-evidence:` line (`release-lane.sh:344-357`) and the one
   log item 7 records carries it; then, for `pass` with a transcript that
   names the digest of the archive it handed over, it prints
   `m8-operator: PASS steps=1` and exits 0, and otherwise exits 1, a
   failure. The runner holds no value of that account, so its
   redactor cannot mask that account's keys or tokens: the runbook enters
   the keys without echo, `loopex` prints no token (ADR 0073), and the
   operator reviews the transcript before handing it back. A transcript
   that shows a credential is not handed back: the operator answers
   `withheld`, the lane exits 0 without its pass line, and the case
   finishes `unavailable`, a consumed non-pass that ends the campaign
   (item 1).
   The `real-sign-in-*` lanes run on the `serenity` host itself, not in the
   clean container, each under a temporary `HOME` with `--store file`; at
   closure they run in the `serenity` full check, and `--only` selects them
   before a merge that changes their boundary.

   The `real-sign-in-*` lanes and `m8-operator` use the archive this
   matrix's `installed-artifact` case built and verified, whose log names the
   archive's path and SHA-256. When an invocation reuses that case, the
   recorder's `plan skip` line also names the reused evidence's reference,
   `plan skip KEY SHA256 PATH` (extending `matrix.ex:91-98` and its parser,
   `release-lane.sh:103`); the runner requires the log at PATH, read on
   macOS over the same SSH destination, to have that SHA-256, and the
   archive it names to have its recorded SHA-256, before such a lane's
   `start`. Any mismatch or missing file is a pre-start `stop` of that lane
   (item 7), so the earlier invocation's retained directory must be kept.
   The delivered refusal of attended
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
   `lane` (`release-lane.sh:312-330`) judges an ExUnit lane by its summary's
   executed count, as delivered (`release-lane.sh:347-374`), and a script
   lane, whose command is no ExUnit run (`installed-artifact`, `m7-adopt`,
   `m8-operator` and the `real-sign-in-*` lanes), by a new
   `release_lane_run` judge mode in place of `scripts/suite-summary.sh`: the
   command's last line must be `<lane>: PASS steps=N`, N the lane's stated
   step count. It sends `unavailable` when the redactor and tee succeeded,
   the command exited 0, and an ExUnit lane counted no executed case or a
   script lane's last line is not its PASS line; and `fail` for every other
   non-pass, including a command that exited nonzero. Each new lane's host probe (session
   bus or Docker) and every other host prerequisite runs before its
   `start`; a refusal retains a refusal log and sends the delivered `stop
   KEY LOG`, which records that case and every later case of the lane
   `not_dispatched` with `evidence_incomplete_pre_dispatch`
   (`matrix.ex:161-186`). The recorder reads and hashes LOG on its own host
   and otherwise refuses `lane_log_unavailable` (`matrix.ex:276-283`). On `serenity`
   LOG is the refusal log. In a macOS run the runner first copies it into
   `--writer-retain` as `prestart-macos-closure-<case>-<16 hex>.log`, the
   suffix from eight fresh random bytes, by item 4's protocol: exclusive
   create, SHA-256 checked on `serenity`, at most three retries each under a
   fresh suffix. `stop` then names that copy. The name needs no attempt ID
   and no `start` is sent to get one. When the retries are spent the runner
   still stops the case, with a new form `stop KEY` and no LOG: the
   recorder writes its own evidence, `prestart-<case>-<16 hex>.json` in its
   run root, created exclusively as `retain/3` writes its records
   (`matrix.ex:285-293`) and naming the case and
   `refusal_log_unavailable`, and records the stop with it; the runner
   prints evidence unavailable with the local refusal log's path and exits 2.
   A `stop` of either form for a case already recorded `not_dispatched` on
   this candidate and matrix appends nothing and answers `stopped KEY`,
   since the codec refuses a second such record (`attempt_events.ex:518-523`,
   `attempt_writer.ex:560-566`); the refusal log stays in that invocation's
   retained directory. Once the host is fixed, the stopped cases continue on
   the same commit, with `--resume-matrix` on `serenity` or the same
   `--join-matrix` on macOS, without dispatching a completed case again.

   A runner killed between one case's `finish` and the next case's `start`,
   or between a pre-start copy and its `stop`, or a recorder killed during a
   `stop`'s appends, leaves the later cases of its lane with no record. If none of the lane's cases has a record, a fresh
   invocation admits the lane anew. Otherwise continuation refuses
   `not_dispatched_evidence_unavailable` (`attempt_events.ex:318-319`), and
   the lane is unresolved on that candidate (D46): the head-recording commit
   that follows is a new candidate, on which closure starts again in the
   same campaign. This is not a consumed failure, does not end the
   campaign, and leaves the writer's admission unchanged.

   The runner prints evidence unavailable and exits 2 for an unavailable or
   stopped case, or when the M7 wrapper exits 2, as it does when its writer
   open refuses `attempt_writer_contention` (`case_runner.ex:151-152`, `:236`,
   replacing the RED exit at `check-release.sh:466`), and exits 1 for a
   failure. The wrapper exits 1 for both a failed case and a pre-dispatch
   stop (`case_runner.ex:235`), so for an M7 conversation lane the runner
   prints RED and exits 1 for either; its retained log's
   `m7-fixture-chat: stopped:` line tells them apart, and a stop stays
   resumable on the same commit. The wrapper's complete output, which ends
   with its result line, such as `m7-fixture-chat: evidence unavailable:
   REASON` (`case_runner.ex:236`), passes through the lane redactor into
   `$retain/<lane>.log`, so the retained evidence keeps the underlying
   refusal. Exit 2 is never a pass: closure counts only `pass` records
   (item 4).

   Interruptions, replays and duplicates keep the delivered barriers:

   - An unsynced `start` is never acknowledged, so its lane never runs.
   - A runner killed, or an SSH connection lost, after a `start` is
     synced, whether or not its reply arrived, ends the recorder's standard input once no process holds it; the
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
     retries are spent does `finish` record the case unavailable. A runner
     killed between a pre-start copy and its `stop` leaves an unreferenced
     copy and no record, which D46 governs as above; a later invocation
     copies under a fresh suffix.
   - While a lost connection holds the `serenity` lock, every other
     invocation on either host refuses `attempt_writer_contention`
     (`attempt_writer.ex:215-221`), so two recorders never write.
   - A second `finish` of a completed case, with the same or another result,
     refuses `invalid_attempt_case_history`, because the case history admits
     no transition from `completed` to `completed` (`attempt_events.ex:566`),
     which the writer passes through (`attempt_writer.ex:565`), and nothing is
     appended.
   - An invocation of a lane that ended with every case passing runs
     nothing of it (`matrix.ex:104`), but the recorder first prints each
     case's `plan skip KEY SHA256 PATH` line from its completed record, then
     `plan ended`, and the runner keeps those lines instead of replacing
     them by `ended` (`release-lane.sh:106`). A `--resume-matrix` after
     every `release-matrix` case passed therefore matches the rebuilt
     fresh-source manifest against its digest (`check-release.sh:336-338`)
     and runs the M7 conversation lanes. One that ended in a failure
     refuses.
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
     the index byte-identical; an ended lane answers its `plan skip KEY SHA256 PATH` lines and `plan ended`; a second
     recorder on the index refuses `attempt_writer_contention`. A recorder
     in a separate OS process that is killed after its `started` reply, and
     one whose standard input closes there, each leave the case `started`
     and the lock free, and continuation refuses `consumed_lane_failure`.
     D30 and D47: a consumed failure, and a `start` synced but its reply
     discarded before the transport closes, each end the campaign; an
     `m8-closure-2` index created after them with `--predecessor` carries a
     `campaign_succession` record naming the predecessor's committed head,
     the ended index, an unresolved-case list holding exactly the case left
     `started`, and the disposition record, each with its SHA-256; it admits
     on the next candidate and plans every case `plan run`, including one
     that passed in the ended index; and the ended index is byte-unchanged
     after the new campaign's run. Afterwards a recorder or `CaseRunner`
     invocation naming the ended index, on any candidate and lane, refuses
     `attempt_campaign_superseded` and appends nothing, and a
     `--create --predecessor` while a recorder in a separate OS process holds
     the ended index refuses `attempt_writer_contention` and writes nothing.
     A `--predecessor` whose committed head is not its last complete record
     refuses before anything is written. D49:
     after a recorder killed mid-append, `--create --predecessor` names the
     last complete record as the predecessor head, lists the torn tail in the
     unresolved-case list, leaves the ended index byte-unchanged, and the
     successor admits. On an ended
     index, a consumed failure in turn in the `release-matrix` lane, an M7
     conversation lane and `macos-closure` makes every new lane refuse
     `post_head_consumed_case` until its head is committed; then the failed
     lane refuses `prior_failure_unauthorized` on the next candidate, a
     `macos-closure` join with no matrix record there refuses
     `matrix_join_unavailable`, and no invocation prints a closure PASS. D46:
     a `--resume` after a runner killed between one case's `finished` reply
     and the next `start` refuses `not_dispatched_evidence_unavailable` and
     appends nothing, and after the head-recording commit a fresh matrix
     admits on that commit in the same campaign. `stop KEY` without a log records the
     case and the later ones `not_dispatched` with the recorder's own
     `prestart-` record; two consecutive pre-start stops of the same case
     append once, and a passing `--resume` then completes the lane.
   - `apps/loopex_cli/test/m7_matrix_runner_test.exs` (new). The runner's
     own `lane` and recorder helpers from `scripts/lib/release-lane.sh`, in
     a disposable tree as `scripts/test/check-release-test.sh` builds one,
     drive a real recorder in a separate OS process against a real index,
     with only the SSH transport replaced by that local process and a
     separate writer directory. No lane command runs before its `started`
     record is in the index; a copied log is recorded with the digest the
     runner sent; a copy that fails once is retried under a new name and
     the case passes, and one that fails every retry records the case
     unavailable; an ExUnit lane that counts no case, and a script lane
     that exits 0 and whose last line is not its `PASS steps=N` line, record
     `unavailable` and print evidence unavailable, never PASS, while a
     script lane that exits nonzero records `fail`; with every
     `release-matrix` case passed and an M7 conversation lane stopped,
     `--resume-matrix` reaches that M7 lane's invocation with that matrix ID,
     the lane command stubbed, after the rebuilt manifest matches its skip
     digest; and a host-probe refusal records `not_dispatched` for that
     case and the later ones, which continue on the same commit. A macOS
     run's refused host prerequisite, with distinct source and writer
     directories, sends no `start`, copies the refusal log to a
     `prestart-` name under the writer directory and sends `stop` with it;
     the `not_dispatched` rows reference that copy, whose bytes still match
     after the source directory is removed, and the same `--join-matrix`
     then runs the stopped cases. A pre-start copy that fails every retry
     sends `stop KEY` without a log and exits 2, and the same
     `--join-matrix` then runs the stopped cases. A resumed
     invocation that reuses `installed-artifact` hands the archive-consuming
     lane the archive its `plan skip` reference names, and a changed log or
     archive stops that lane before its `start`.
   - `apps/loopex_cli/test/m7_case_runner_test.exs` (extended). `--concept`
     admits against the named file's heads and refuses when that file has
     none for the index's campaign; an index with `FILE.ended` beside it
     refuses `attempt_campaign_superseded` and appends nothing; `:auto`
     after a wrapper killed between
     two cases refuses `not_dispatched_evidence_unavailable` and appends
     nothing (D46).
   - `scripts/test/check-release-test.sh` (extended). The macOS selection
     rules, the four new options' refusals, `--attempts-index` refused with
     any other selection, an M7 wrapper exit 2 printed as evidence
     unavailable with exit 2 and its refusal line kept in the retained lane
     log, and the final lines.

   The SSH transport is proved by a rehearsal before the closure candidate,
   on a scratch index of campaign `m8-rehearsal-1` on `serenity`, whose
   genesis and anchor line cannot be mistaken for a closure campaign's, and a
   scratch commit that carries its
   head line, both discarded afterwards. On `serenity`, `--only m7-rollback`
   with that index records matrix `m7-rollback-<12 hex>` on the scratch
   commit (`check-release.sh:260`), the one indexed selection there that
   gives a join its matrix record; the macOS run then joins it with
   `--join-matrix m7-rollback-<12 hex>` and runs the three lanes, the
   operator making the attended `m8-operator` record as at closure.

<a id="technical-plan-open"></a>
### Open for the Maintainer

Concept: [Design decisions](M8.md#concept-plan-decisions).

These are actions with providers, not design gaps. Each settles one ADR
0073 verification item (2 for OpenAI, 5 for Google) and gates only its
`real-sign-in-*` lane; nothing else in M8, acceptance included, waits on
them. A lane whose action is not done by the closure candidate is deferred
under D36, its route shipping disabled (D43), or blocks closure.

1. **OpenAI client.** Confirm that Loopex registers by Sign in with ChatGPT's
   dynamic registration as a locally run open-source app, and approve the
   `agent_name_hint` it presents; if OpenAI requires a partner client, submit
   its interest form. Gates `real-sign-in-openai`.
2. **Google client.** Create Loopex's Google OAuth desktop client in a
   maintainer-owned Google Cloud project and decide when to pass verification
   for the `cloud-platform` scope. Until verification, users see an
   unverified-app screen, the app is capped at 100 users, and in Testing status
   refresh tokens expire after 7 days. The `adc` source does not need it.
   Gates `real-sign-in-gemini`, the `loopex` source; without the client
   that lane is unavailable or deferred under D36, and
   `real-sign-in-gemini-adc` runs either way (D43).
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
| Root format number | Any change to a durable member, shape or encoding of a root, nested and delegated shapes included, advances `loopex-root-format N` in any release, a patch included, and existing roots are refused until a separately decided migration exists (D28); `root_format_fixture_test.exs` decodes a retained format-1 root and the retained M7 root through the full audit and requires exact re-encoding by the pure codecs, and five named limits are checked, two there and three by the delivered `log_capacity_test.exs` and `log_encoding_test.exs`, `delegation_ledger_codec_test.exs` and `session_index_codec_test.exs` (ADR 0072), so a change that breaks a retained record, a pure codec's bytes or one of those limits fails the fast check until a new fixture is produced, which D28 pairs with a new number; that pairing, and what the retained roots do not reach, is held by review (ADR 0072) |
| Durable records and host ledger | Delivered M7 versions as the current format, except the placement lock record and guard entry `loopex-placement-v2` and the Store writer marker `loopex_store_writer_v3` (D33), with v1 lock records and guard entries and v2 markers read by liveness only, and `store adopt`'s rebinding of an alias-bound executor ledger to a generation bound to its physical path, carrying its open authority unchanged (D45, D48, amending ADR 0016), the resource-pack receipts ledger only with an empty open index and its path-derived executor identity rewritten (D55); the settled-attempt record and run terminal admit the `provider_sign_in_required` category, proved by `sign_in_required_settlement_test.exs`; no older-reader or older-root promise |
| Backup layout and its records | New experimental current-format contracts under ADR 0072: `loopex_store_backup_capture_v1`, `loopex_store_restore_attestation_v1` and `loopex_store_restore_continuation_v1` |
| Restore transition | Accepted ADR 0051 with ADR 0072's two clause amendments: the commands are its operator front end, and the discard attestation form admits an older backup for a lost source. M8 changes `restore/2` to always leave the disposable helper job index out of its audit index, as adopt and backup do, narrowly amending ADR 0056's complete helper-namespace audit (D35), while copying it under the complete manifest, so a root holding one commits where it was refused `invalid_current_history` (D29); there is no `restore/3`. ADR 0051's walks and result grammar are unchanged. A latest-form plan's bytes are unchanged |
| Daemon protocol | `loopex.experimental/4` gains `daemon.readiness` in its ADR 0044 manifest's `methods` inventory, the `provider_sign_in_required` reason and the `daemon.stopping` reason `fatal:sign_in_route_lost` (D42), each with schema, vectors and pinned digests updated in place |
| Foreground protocol and embedded API | `loopex.experimental/3` gains the `provider_sign_in_required` reason. Under ADR 0073: the `chat_terminal_outcome` definition gains its `failed_reasons` list; `LoopexProtocol.Session.CompactResult` admits the category; `session-snapshot.v3.json`, `standalone-compact-result.v1.json` and `standalone-compact-completion.v1.json` each gain it in `failure.simple.categories`, with vectors; and ADR 0018's Model callback result union widens by `{:error, {:not_dispatched, "provider_sign_in_required"}}`, which every Model adapter's caller must accept. The `loopex.ask/1` object that `ask --output json` prints admits the same failed reason and gains the status-1 codes `sign_in_route_lost`, `provider_sign_in_required` and `sign_in_unavailable` (D38, D50). The embedded API is otherwise unchanged except an undocumented `Loopex.Runtime.create_session_with_genesis_detailed/4` and D29's changed `LoopexComposition.Restore.restore/2`, which now commits a root holding the disposable helper job index it used to refuse; no `restore/3` is added. `Loopex.Store.Local.WriterLock` writes `loopex_store_writer_v3`, reads a v2 marker by liveness only (D33), refuses `TZ` among its exclusion names and gains `holder_status/1` ([holistic 2 item 4](../process/agent-context-map.md#disposition-m8-holistic2-2026-10-14)). The composition host options gain the sign-in context and `:sign_in_routes`, `LoopexComposition.CredentialHost` gains `open/3` and `close/1`, and its plane gains the member `sign_in_routes` (ADR 0073) |
| Configuration | ADR 0049's schema version 1 and resolver; discovery and writers by ADR 0037, the daemon's reader by ADR 0071, the `oauth` form and `vertex` members by ADR 0073; a credential reference named `TZ` is refused, as `LC_ALL` already is ([holistic 2 item 4](../process/agent-context-map.md#disposition-m8-holistic2-2026-10-14)); a configured disabled route, `claude:` or one D43 disables, is refused at resolution as `sign_in_unavailable` (D52) |
| Credentials | Environment references unchanged; sign-in tokens in the operating system's keyring or an owner-only file under `<home>/auth/`, and gcloud's Application Default Credentials directory, separate by resolved path from every state root, backup, restore destination and available restore source under [ADR 0037's path-separation rule](../adr/0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation), checked before any store command reads or writes those paths, so no backup's complete copy contains them. Separation is that path rule only (D27): no mount table is read, and a mount of any kind that makes credential storage reachable inside a walked tree, or a credential file copied into a root, is outside the guarantee under ADR 0037's [operator limit](../adr/0037-host-configuration-and-path-discovery-technical.md#technical-0037-operator-limit): do not mount credential storage into or over a Loopex state root, backup or restore destination. The `adc` source reads gcloud's own file under ADR 0073's stated exception to its decision 3 (D20) |
| Existing commands | The foreground `chat` keeps its grammar and exit semantics. `run`, `resume`, `attach` and `sessions` keep theirs; with `--service`, `run` and `resume` start the service on demand. Every command that selects a state root, ephemeral `ask` excepted, also refuses an unusable `HOME` as `home_unavailable` before any write, the M7-form `loopex daemon` with status 111, and opens its root as its physical path (ADR 0037); an explicit `--socket` on the M7-form daemon is canonicalized the same way (D53), and a root or socket that fit the socket length limit only through a shorter alias now refuses `socket_path_too_long` (87). `ask`, durable and ephemeral, gains `--config` and takes only `providers` from the file ADR 0037 selects, when one is selected: they apply to the providers they name, and every other provider keeps `ask`'s environment route; its other flags are unchanged (D54, D57). Foreground `run`, `resume` and `skill` without `--service`, given a selected file whose binding for the selected route is `oauth`, refuse `sign_in_unavailable` with a hint to use `loopex chat` or `--service` (D58) |
| Daemon exit statuses | 65 to 110 unchanged; 111 to 115 (114 retired), 116 to 119, 120 to 123, 124 (`root_adopting`) and 125 (`service_record_write_failed`) added, so the table uses every status 65 to 125 except 114 exactly once, and 111 also carries a configured disabled route's `sign_in_unavailable` (D52); they land in three blocks, the last being 120 to 125, so every interim table is gap-free |
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
current. It changes no record, except that an executor ledger bound
through an alias path gains a generation bound to the physical path,
carrying its open authority unchanged (D45, D48). Adopt holds the root's placement lock from
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
