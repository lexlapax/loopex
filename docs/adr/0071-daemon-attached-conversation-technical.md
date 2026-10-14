<a id="technical-depth"></a>
## Technical depth

Concept: [Daemon-attached conversation](0071-daemon-attached-conversation.md#concept).

<a id="technical-adr-0071-decision"></a>
### Contract

Concept: [Context and decision](0071-daemon-attached-conversation.md#concept-adr-0071-decision).

Everything below was checked against the delivered M7 source at `9b917387`
and `apps/loopex_protocol/priv/schema/loopex-experimental-4.json`. New
modules live in `apps/loopex_cli` unless another application is named.

#### Grammar

```text
loopex chat --service [--config FILE] [--resume SESSION] [OPTIONS]
loopex chat --daemon SOCKET [--resume SESSION] [OPTIONS]

OPTIONS, new sessions only:  --model PROVIDER:MODEL  --reasoning LEVEL
                             --max-tokens N  --context-token-budget N
                             --system-class-tokens N
OPTIONS, every fresh prompt: --max-steps N  --deadline-ms MS  --token-budget N
OPTIONS, accepted no-op:     --output text
```

`LoopexCli.Chat.run/2` sends argv to `LoopexCli.AttachedChat` (new) when
`--service` or `--daemon` occurs before any `--`; otherwise the foreground
path runs unchanged. `LoopexCli.ConfigOptions.parse/1` gains an `:attached`
head with that allowed set, the same value validators and its `{class,
pointer}` refusals. In order, before any file, socket or process:

| Input | Refusal |
| --- | --- |
| Both `--service` and `--daemon` | `service_and_daemon` |
| `--config` with `--daemon` | `config_requires_service`, `/flags/config` |
| `--workspace`, `--state-root`, `--policy`, `--tools`, `--skill-dir`, `--system-prompt-file`, `--append-system-prompt-file`, `--cleanup-grace-ms`, `--no-helpers`, `--compaction-model`, `--trace`, `--no-trace`, `--trace-level`, `--trace-module`, `--trace-max-entry-bytes`, `--trace-max-entries-per-second`, `--trace-max-queue-entries` | `service_owned_flag`, `/flags/NAME`; standard error names the service's configuration as the owner |
| A new-session option with `--resume` | `session_option_on_resume`, `/flags/NAME`; standard error suggests `/configure` |
| Anything ADR 0049's validators refuse | Its existing class and pointer |

A refusal is written as the foreground's `@loopex` `error` record with a null
input sequence, then a `closing` record with exit code `1`, exactly as
`LoopexCli.Chat`'s startup refusal does.

#### Startup

| Step | Member or call | Refusal (exit `1`) |
| --- | --- | --- |
| 1. Reach the service | `--service`: ADR 0037's on-demand machine; `--daemon`: `DaemonClient.connect(socket)` | ADR 0037's classes; `service_unreachable` |
| 2. Check readiness | `daemon.readiness` | Not `serving`: `service_not_serving` with the state, and for `closed` the session and `loopex store restore` |
| 3a. New session | `session.create` with a fresh 16-byte command identity and `session_options` `{"version": 1}` plus `configuration` from the new-session options, quantities as canonical decimal strings | The admission's refused reason |
| 3b. Existing session | The `--resume` identity | — |
| 4. Control | `session.acquire_control` | `control_held` or `control_pending`: `control_held`, naming `loopex attach --service SESSION --observe` and the 30-second lease term |
| 5. Attach | `session.attach` with `after_event_sequence: "0"` | `session_dormant`: `session.resume` under the granted epoch with one retained command identity, then attach again, as `LoopexCli.Live` does; any other code under its own name |
| 6. Inspect | `session.inspect` | Its code |
| 7. Report | Standard error: the snapshot's committed configuration rows with origin `committed`, the service's `workspace` and `project_resources` from step 2, and `loopex: session SESSION`; a pending `open_interaction` is written as a `question` record | — |

Steps 3a and 5 replay through the delivered paths: create replays its
command identity, resume keeps one retained identity until it resolves. A
dormant answer after a fresh activation is `session_unavailable`, never a
loop.

#### Action mapping

Every action runs under ADR 0033: mutations carry the granted
`writer_epoch` on the connection holding the live attachment. Command
identities are 24 random bytes as in the foreground driver; text content goes
as `content_b64`. Every method below is in the delivered `/4` method list and
request inventory; their results are the delivered `admission` or `result`
records.

| Line | Member and fields | Authority checked | On refusal |
| --- | --- | --- | --- |
| Plain text, `//text` | `session.prompt` `{command_id, content_b64, writer_epoch}` plus `bounds` `{max_turns, deadline_ms, token_budget}` only for options the operator gave | Lease, epoch, attachment | `input` record refused with the reason; pipe mode stops |
| `/follow-up TEXT` | `session.follow_up` `{command_id, content_b64, writer_epoch}`, no bounds | The same | The same |
| `/steer TEXT` | `session.steer` with `run_id` from a `session.inspect` read just before submission, as the foreground reads status | The same | No active run: local `no_active_run`; else the reason |
| `/answer ID --text JSON`, `/answer ID --choice ID`, `/decline ID` | `session.respond_interaction` `{command_id, interaction_id, answer, writer_epoch}`, the answer in `interaction_answer` wire form | The same | The reason |
| `/configure JSON` | `session.configure` `{command_id, changes, writer_epoch}`; the decoded object is sent with integer quantities as canonical decimal strings, and the service resolves the model through its own bindings | The same | The reason; no local candidate cache |
| `/compact` | Write `Compaction bounds: max_attempts=4, deadline_ms=60000, token_budget=32768`, then `session.compact` with `bounds` `{"max_attempts":"4","deadline_ms":"60000","token_budget":"32768"}` | The same | The reason |
| `/abort` | `session.abort` `{command_id, writer_epoch}` | The same | The reason |
| `/status` | `session.inspect` | Attachment on this connection; no lease | `chat_status_unavailable` |
| `/wait` | Barrier, below | — | — |
| `/quit`, end of input, signal | Detach, below | — | — |

The four `/compact` values are the `command_bounds` schema maxima and the
foreground driver's fixed reference bounds. Read-only `session.inspect` needs
only the connection's admitted session, which `RequestLedger.admit_session/2`
grants. `resources.*`, `session.admit_resources` and `session.activate_skill`
are not used: the foreground conversation has no line for them.

**Rendering.** Durable events and progress arrive on the one connection and
are rendered by the foreground driver's projection: held assistant messages,
`question` records from `interaction.requested`, run outcomes from
`run.finished` and compaction results from `context.compaction_finished`.
`LoopexCli.ChatDriver`'s private `project_event/2` and held-message release
move to `LoopexCli.ChatProjection` (new) so both drivers use one projection;
the foreground's output is unchanged. Events at or below the cursor are
dropped by session, sequence and event identity.

**Status.** One `status` record from the inspection: `run_id`, `state`,
`configuration_version`, `model`, `reasoning`, `bounds` from
`active_bounds`, `interaction_id` from `open_interaction`, and `maintenance`
with `configured_model: null`, `active_model` from `active_maintenance`,
`warning: null` and the last compaction seen on this connection. `trace` and
`policy` are `null`: service-owned and not projected to a client. The
foreground always supplies both, so `LoopexCli.ChatControl` admits `null`
only for those two members; this is the narrow ADR 0049 record amendment.

**Barrier.** `/wait` reads `session.inspect` after each delivered durable
event and otherwise every 1,000 ms. It settles when `active_run_id` is null,
`pending_work_ids` is empty, `open_interaction` is null, `active_maintenance`
is null and every compaction this connection admitted has its
`context.compaction_finished`; it stops at a pending question with a
`question` barrier record, exactly as the foreground's `wait` records do.

#### Control and loss

| Event | Result |
| --- | --- |
| Lease renewal | `session.acquire_control` every 10,000 ms; a refused renewal ends the command with `control_lost`, exit `1` |
| Transport loss | Redial every 250 ms within 35,000 ms of the first loss; reacquire, retrying `control_held` until the old lease's end plus 1,000 ms; reattach at the retained cursor; re-present an unconfirmed command with its same identity and content. These are `LoopexCli.Live`'s constants and rules |
| `detached` record (slow reader) | Wait for outstanding answers up to 5,000 ms, then `session.attach` at the retained cursor on the same connection, keeping the lease |
| `control_owner_lost` | Treated as transport loss |
| `admission_unknown` | Exit `1` naming the method and command identity |
| `daemon.stopping` | Exit `1` with `service_stopped` and the reconnect command |
| Recovery deadline passed | Exit `1` with `connection_lost` and the reconnect command |

The lease, cursor and recovery functions `LoopexCli.Live` keeps private
(`ensure_control`, `ensure_attached`, `dormant`, `maybe_renew`, `release`
and the recovery clock) move to `LoopexCli.DaemonSession` (new) so both
commands share them; `LoopexCli.Live`'s behaviour and tests are unchanged.

#### Leaving

| Event | Result |
| --- | --- |
| `/abort` | `session.abort` for the active run; the conversation continues |
| `/quit`, end of input, or a signal the escript sees as `SIGTERM` (the launcher forwards `SIGINT`, `SIGHUP` and `SIGQUIT` as `SIGTERM`; `LoopexCli.LiveSignal` delivers it) | Stop reading; wait up to 5,000 ms for an outstanding admission answer; `session.release_control` waiting at most 5,000 ms; close; `closing` record with `cleanup: confirmed`; on standard error `loopex: detached; the session continues in the service` and `reconnect: loopex chat --service --resume SESSION` (or the `--daemon` form); the run continues |
| `SIGKILL` or host loss | Nothing is sent; the lease lapses within 30,000 ms; the run continues |
| Pipe syntax or state refusal | Stop reading, detach as above, exit `1` |

`cleanup` describes this client's own resources, which it always joins; a
release that is not answered leaves the lease to lapse and does not change
the exit status.

**Exit status.** `0` unless one of these occurred, then `1`: a refusal before
or during startup; a pipe-mode refusal; `admission_unknown`; `control_lost`,
`service_stopped` or `connection_lost`; output failure; a run whose
`run.started` names a prompt or follow-up this command admitted and whose
`run.finished` outcome is not `completed`; or a compaction this command
admitted that finished `failed`. A run still active at detach does not count.

#### Service configuration

`loopex daemon --config FILE`. `LoopexDaemon.Command`'s closed flag set gains
`config` and `admit-project-resources` (ADR 0037); `--admit-project-resources`
without `--config` is a parser refusal, status `1`. `run/2` parses first,
and the delivered `credential/1` (`daemon.ex` :66, :197-209), which reads and
deletes `LOOPEX_PROVIDER_API_KEY`, then runs only for the form without
`--config`, before `start/2`'s first input check. Without `--config` every
M7 rule is unchanged, except that ADR 0037's `HOME` read and separation check
run after the state root input is read (`apps/loopex_cli/lib/daemon.ex` :81)
and before `paths/2` (:82), so an unusable `HOME` exits 111,
`home_unavailable`; the root's
[physical path](0037-host-configuration-and-path-discovery-technical.md#technical-0037-physical-root),
and an explicit `--socket` canonicalized the same way (D53 and its note), are what
`Paths.startup/2` measures.

| Daemon input | With `--config` |
| --- | --- |
| `--state-root`, `--workspace`, `--policy`, `--cleanup-grace-ms` | ADR 0049 flags with their chat names, passed to `ConfigSelection.compose/4` as overrides; origin `flag` |
| `--socket` | Daemon-only; canonicalized to the root's physical form as without `--config` (D53 and its note) |
| `--provider-launch` | Refused `provider_launch_conflict` |
| `LOOPEX_HOME` | ADR 0049's state-root alias, as in chat |
| `LOOPEX_WORKSPACE`, `LOOPEX_POLICY`, `LOOPEX_PROVIDER_LAUNCH` | Not read: ADR 0049 admits one alias. `loopex doctor` lists none of them |
| Provider launch | The build's `LoopexCli.ProviderLaunch.options/0`, as chat uses |
| `LOOPEX_PROVIDER_API_KEY` | Deleted from the environment unread unless a binding names it, exactly as `CredentialPlane.load_bindings/2` does for chat; the version-2 single-credential plane is not started |
| `providers.*.credential.env` | Each must be present and nonempty before any lock, else `provider_credential_absent`; loaded by the delivered binding plane |
| `delegation`, `roles` | Honoured as in chat: helper roles are captured before any lock and the service hosts helper parents, below. `delegation.enabled: false` keeps M7's classify-and-guard behaviour |
| `trace` | Started with `Loopex.trace/2` after composition and before the listener; diagnostics go to the service's standard error through `LoopexComposition.DiagnosticConsumer`; failure is `trace_start_failed` |

Startup order under `--config`, every pre-lock 111 refusal before 113: parse;
`ConfigFile.load/2` and `ConfigSelection.compose/4`; ADR 0037's `HOME` read
and separation check; instruction capture and `ChatConfiguration.genesis/3`;
with delegation enabled, the helper role capture below; reference presence;
the project-resource decision; ADR 0037's service record when no selection
or socket flag is given (125); then the delivered start. The composition options are the ones `LoopexCli.Chat`'s private
`composition_options/6` builds today, moved to
`LoopexCli.HostOptions.composition/2` (new) and used by both: `state_root`,
`workspace`, `policy`, `policy_identity`, `provider_bindings`,
`provider_launch`, `resource_manifest` from `session.skill_dirs` through
`ResourcePacks.read_directories/2`, `model`, `maintenance_model`,
`maintenance_instructions`, `active_tools` for `session.tools`,
`context_token_budget`, `system_class_tokens` and `cleanup_grace_ms`; the
service adds `bounds` from `session.bounds` and the captured genesis as
`session_creation_defaults`. `LoopexDaemon.Service.start_composition/2`
already forwards each of these except `system_class_tokens`, which it gains;
`provider_bindings` reaches the delivered binding plane through
`prepare_bindings/2`, which already refuses a supplied credential beside
bindings. Omitted prompt bounds are therefore the service's `session.bounds`,
captured at admission. The project
`AGENTS.md` decision is unchanged: interactive in the foreground, unadmitted
on `/dev/null`, or ADR 0037's digest-bound `--admit-project-resources`.
`session.create` keeps refusing client-named provider capabilities, credential
routes, catalogs, registry modules and tool bindings.

New `LoopexDaemon.ExitStatus` classes, after the delivered 65 to 110:

| Status | Class | Meaning |
| --- | --- | --- |
| 111 | `configuration_invalid` | ADR 0049's reader, schema, selection or resolution refused, ADR 0037 found `HOME` unusable (class `home_unavailable`), or its [auth separation](0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation) refused the selected state root (class `auth_root_overlap`), or ADR 0073's configuration resolution refused a disabled sign-in route (class `sign_in_unavailable`, D52); every 111, before or after the lock, writes one line, `loopex daemon refused to start: configuration_invalid <subclass> <pointer>`, `<subclass>` being the refusing class (`home_unavailable`, which has no pointer, `auth_root_overlap`, `sign_in_unavailable`, ADR 0049's class, or a helper capture's class and pointer as `config validate` locates them, `config_inspection.ex` :201-207). Before the lock `LoopexCli.Daemon` writes it and takes the status from `ExitStatus.fetch(:configuration_invalid)`, where the delivered clause (`apps/loopex_cli/lib/daemon.ex` :109-112) prints one class and fetches its status. A refusal after the lock, step 3's catalog capture below or an ADR 0073 composition refusal at a route's start (`auth_root_overlap`, 111; 120 to 122), is a startup failure that releases the lock (`finish_startup_failure/2`, `apps/loopex_daemon/lib/loopex_daemon/service.ex` :880-892), which latches no fatal line, so the service first writes that line on standard error, or, for 120 to 122, `loopex daemon refused to start: <class> <pointer>` with ADR 0073's class, whose status `ExitStatus.fetch/1` gives |
| 112 | `provider_launch_conflict` | `--provider-launch` with `--config` |
| 113 | `provider_credential_absent` | A configured reference is absent; the line adds the pointer |
| 114 | — | Retired before use: an earlier draft of this record assigned it to a refusal of enabled delegation, which the service now hosts. No class maps to it and the daemon never exits with it |
| 115 | `trace_start_failed` | The file enables a trace that does not start |
| 125 | `service_record_write_failed` | Owned by ADR 0037: the daemon could not write its [service record](0037-host-configuration-and-path-discovery-technical.md#technical-0037-service-record) and exits before the placement lock (D31) |

Numbers are kept stable rather than closed up, so no text that already names
115 changes meaning. ADR 0072's root refusals and ADR 0073's sign-in statuses
take the statuses after 115, in that order: 116 to 119 and 120 to 123;
ADR 0072's `root_adopting` takes 124 and ADR 0037's
`service_record_write_failed` 125. They land in three blocks so that every
interim table is gap-free: this record's 111 to 115; then ADR 0072's 116 to
119; then 120 to 125 together with ADR 0037's service record, ADR 0073's
four, ADR 0072's 124 and ADR 0037's 125. At each landing `command_test.exs`
asserts exactly the cumulative set: 65 to 115, then 65 to 119, then 65 to
125, each without 114. The
module's "every integer from 65 through 110" statement becomes, once all four
records land, "every integer from 65 through 125 except 114, which is
retired"; `ExitStatus.classes/0` omits 114 and no class maps to it. ADR
0037's separation refusal `auth_root_overlap` reuses 111 (table above) and takes no
number of its own. A helper role that cannot be captured is `configuration_invalid`
(111) with its pointer; no helper failure has a status of its own.

#### Service-hosted helpers

Checked against `740451ae`: `LoopexComposition.Delegation` (`host/4`,
`bind/4`, `role/5`, `create_parent/7`, `guard/3`),
`LoopexComposition.Delegation.Helper`, `LoopexCli.Chat`'s private `create/4`,
`LoopexCli.ChatConfiguration.helper_parent/2`, `LoopexDaemon.Service`'s
`delegation/1` and `track_delegation/2`, and `LoopexDaemon.SocketConnection`'s
`create_task/4`, `run_mutation/5` and `route_guard/3`.

**Already delivered in the daemon.** `Service.delegation/1` calls
`Delegation.host(root, placement_identity, placement, false)`, which opens the
helper owner only when the root holds a `delegation` directory. The owner and
its retained-object writer are linked and tracked, so either one's exit ends
the service as `runtime_lost`. `LoopexComposition.start_edges/2` wraps the
local executor with the router and calls `Delegation.bind/4`, which binds the
owner to the runtime and classifies for 60,000 ms; an incomplete pass starts
the runtime with mutation closed. `run_mutation/5` runs `route_guard/3`
(`Delegation.guard/3`) in the relay task before every Core mutation, and the
activation path guards `:resume`. Classification, stop-only recovery and the
route guard therefore already run in the service. What M8 adds is enabling
delegation, the frozen catalog, parent creation and the evidence below.

**Startup with delegation enabled.**

| Step | Where | Action | Refusal |
| --- | --- | --- | --- |
| 1. Capture roles, before any lock | `LoopexCli.HostOptions.helpers/1` (new) | For each enabled role in order, `Delegation.role(workspace, role, providers, read_only, cleanup_grace_ms)` with the delegation reply and context settings, exactly as `ChatConfiguration.helper_parent/2` builds it; keep the role geneses, the provider bindings and the limits `roles`, `max_children`, `token_budget`, `child_bounds` and `max_tokens` | `configuration_invalid` (111) with `/roles/NAME`; nothing started |
| 2. Open the owner, after placement | `Service.delegation/1` | `Delegation.host/4` with `enabled` true when the start options carry `helpers`; the owner always opens | The delivered `composition_start_failed` |
| 3. Freeze the catalog, after placement | `Service`, calling the host's `{LoopexCli.HostOptions, :helper_catalog, [helpers]}` with the placement identity | `Catalog.digest(runtime_id, providers, roles)` and one capture of the parent instructions with `enabled_roles` and `catalog_digest`, exactly as `ChatConfiguration`'s `capture_instructions/2` does; the result is kept in the service's state for its lifetime | `configuration_invalid` (111) as a startup failure that releases the lock, with the refusal line above |
| 4. Compose | `LoopexComposition.start_edges/2` | The handle's `enabled: true` registers the fixed `loopex.task` generation through `Delegation.definitions/1`; bind and the first 60,000 ms classification as delivered | As delivered |
| 5. Bind the activation permit, after the collaboration services start and before the listener | `Service` | `Helper.bind_activation_permit(helper, {LoopexDaemon.HelperActivation, [registry]})` (below); the call returns the sessions the owner activated before it had a permit, which the service accounts to the registry | A refused bind is the delivered `daemon_services_start_failed` |
| 6. Keep classifying, after step 5 | `Service` | ADR 0037's further 60,000 ms `Helper.classify/2` slices from a linked task until coverage completes or a session is named, after which the task ends normally; no slice runs before the bind, so none delays it or recovers a child uncounted. Before the permit seam lands (M8 plan step 6, W2) there is no step 5 and the loop starts after step 4 (plan step 4, W1) | — |
| 7. Serve | `LoopexDaemon.Owner` | The connection context carries `helper_parents: %{handle, catalog, prepare}` to every connection, as it carries `runtime` today | — |

Steps 5 and 6 also run on a service with delegation disabled whose owner
opened for retained history, so its recovery activations are counted too.

The service application depends on composition and not on the CLI, while the
configuration selection and genesis builders belong to the CLI host. The host
therefore passes plain data and a module-function pair, as it passes its
policy module; no closure crosses and no CLI module is compiled into the
daemon. `ChatConfiguration.helper_parent/2` is split into
`helper_roles/1` (step 1), `helper_catalog/3` (step 3, the only step that
reads files after the lock) and `helper_parent_genesis/3` (per creation,
reads nothing); `helper_parent/2` remains their composition, so the
foreground's bytes are unchanged.

**Parent creation.** With `helper_parents` present, `create_task/4` runs these
checks in order in the relay task, before any record:

| Check | Refusal (admission `refused` with this word) |
| --- | --- |
| The helper owner's classification is complete. This also applies to an ordinary create on a service with helpers disabled whose root holds helper history, which ADR 0046 requires and the delivered create path does not yet check | `helper_classification_incomplete` |
| `session_options` passes ADR 0055's closed version-1 decoder and names neither `configuration.instructions` nor `tools`: the parent's instructions carry the frozen catalog and its selection must hold `task` | `helper_parent_option_unsupported` |
| `helper_parent_genesis/3` resolves the remaining `model`, `reasoning`, `max_tokens`, `context_token_budget` and `system_class_tokens` as ADR 0049 flag overrides on the service's selection, through its provider bindings, and builds the genesis whose `options` are the client's `session_options` | The resolver's class |
| `Delegation.create_parent_detailed/7` (new) | `ledger_fenced`, `parent_binding_conflict`, `router_unavailable`, or Core's refusal |

`create_parent_detailed/7` captures as `create_parent/7` does and calls
`Helper.create_parent/2`, which now returns Core's detailed reply from
`Loopex.Runtime.create_session_with_genesis_detailed/4` (new, `@doc false`):
the same control message `create_session_with_genesis/4` sends, without the
projection, as `create_session_detailed/3` is for the authored route. The
foreground's `create_parent/7` keeps its projected `{:ok, session}`. The reply
is mapped exactly as `create_task/4` maps `create_session_detailed/3` today:
`:activated` publishes the session to the index and spends one activation;
a replay spends none; `commit_unknown` is `admission_unknown` and is accounted
by Core's disposition, as the delivered create path accounts it. Core's
supplied-genesis rule compares the genesis `options` with the normalized
client options and refuses a mismatch as `invalid_session_creation`, so a
helper parent commits the same original options a non-helper service session
would.

*Disposition across a later failure.* Core's disposition is fixed the moment
its creation answers, and no later step may lose it. `Helper.create_parent/2`
returns `{:ok, %{session_id, disposition}}` or `{:error, reason, %{disposition,
session_id}}`, where `session_id` is Core's session or `nil`. When Core
activated the parent and the following `bind_parent` commit then fails, is
refused or fences the owner, the error still carries `disposition: :activated`
and the session: `create_task/4` returns `{:activated, session_id, refusal}`
to its promotion, the registry's delivered `account_create_promotion/3` counts
the session, and the session is not published to the index because it is not
a bound parent. A failure before Core is called carries `:no_activation` and
`nil`.

A repeated command identity with the same options returns the original parent
within one lifetime, because the frozen catalog gives the same capture bytes.
After a restart the catalog is captured again; when a role's instructions,
the workspace instructions or the configuration changed, the capture differs
and the replay refuses `parent_binding_conflict`, and the client creates with a
new identity. The creation runs inside the helper owner's serial call, so a
guard read from another connection waits for it, bounded by Core's
60,000 ms creation cutoff, as in the foreground.

**Running helpers.** The service adds one step, the activation permit below,
to the delivered helper path: the router forwards the parent's `task` job to
the owner, which takes a permit, reserves, creates the child with its frozen
read-only genesis, prompts it with the
authored bounds and the absolute cutoff, waits in the caller, settles from
ADR 0069's run evidence, retains the receipt and returns up to 16,384 bytes of
child text with `usage` members `child`, `delegation`, `parent` and
`combined_tokens`. The limits are those delivered and named by ADR 0046's
fixed refusal order, plus the service's activation limit:

| Limit | Value and refusal |
| --- | --- |
| Active helpers per parent | One; a second `task` call while one runs refuses `helper_slot_occupied` |
| Parents in parallel | Independent parents may each run one helper; there is no service-wide helper slot |
| Service activations | ADR 0032's 64 per lifetime, shared by client sessions and helper children; a child that would exceed them refuses `helper_activation_limit` |
| Per parent run | `max_children` (1 to 128) and `token_budget`; `delegation_count_exhausted`, `delegation_tokens_exhausted`; the ADR 0056 log cap, `ledger_capacity` |
| Router registry | 4,096 active rows shared by every parent in the service; `router_registration_capacity` |
| Cancellation tombstones | 4,096; their exhaustion closes helper admission until the service restarts, `helper_admission_closed` |
| Child tools | `read`, `grep`, `find` and `ls` at 1.1.0 only; the service's workspace is unchanged by a child |

**What an attached client sees.**

| Plane | Content |
| --- | --- |
| Parent attachment | The parent's committed events and progress for the `task` call, as for any tool call, and the tool result carrying the role, catalog digest, model, child session, outcome, text, truncation flag and usage. `ChatProjection` renders them exactly as the foreground does; no rendering is added |
| Child | `session.attach`, `session.inspect` and `session.history` on the child's identity, all read-only and unguarded, while the child is active in this lifetime. A dormant child needs `session.resume`, which refuses `helper_session_owned`, so after a restart a child is read through its parent's receipt. Children are not added to the session index; `sessions --service` lists parents |
| `/status` | The parent's committed state as for any session; helper usage is in the receipts, not in the status record |
| Classification | Until it completes, `daemon.readiness` answers `classifying` with its counts, `closed` or `unavailable` ([ADR 0037](0037-host-configuration-and-path-discovery-technical.md#technical-adr-0037-decision)), and every mutation and creation refuses `helper_classification_incomplete` |

**Route guard over `/4`.** Unchanged: `route_guard/3` refuses every command
type outside `Delegation.guard/3`'s read-only set on a helper child, so
`session.prompt`, `steer`, `follow_up`, `configure`, `compact`,
`respond_interaction`, `abort`, `admit_resources`, `activate_skill` and
`resume` refuse
`helper_session_owned` before Core admission and write nothing. Until
classification completes they refuse `helper_classification_incomplete`. Once
an owner has been bound, `Helper.bind/3`'s `{:bound, supervisor}` registry
meta row makes a lost owner refuse every mutation `helper_owner_unavailable`
while the service fails stop as `runtime_lost`. `session.acquire_control` on a
child is a lease, not a mutation, and stays admitted; nothing it enables
passes the guard.

**Restart and recovery.**

| Event | Result |
| --- | --- |
| `service stop` or `SIGTERM` while a helper runs | The [stop order](#technical-adr-0071-stop-order) below: the delivered drain and runtime stop end parent and child coordinators, and the owner and its writer stop after the runtime and the executor and before the Store. The owner is never stopped while the runtime runs |
| `SIGKILL` or host loss | The same next start, plus ADR 0056's incomplete-final-frame recovery under the writer's stale-writer rule; an unresolved append fences the owner, `ledger_fenced`, until it resolves |
| Owner or writer exit while serving | Fail-stop `runtime_lost`, as delivered |
| Next start | `host(..., true)` opens with `recover_stale_writer`, binds and classifies. Each unfinished operation stops with `adapter_recovery`: a known child is aborted through a prepared owner whose recovery work is never activated, and that owner is counted as one activation, below; no create or prompt is replayed; conclusive evidence is settled and receipted; anything less keeps that parent's slot occupied, so its later `task` calls refuse `helper_slot_occupied` |
| Reattaching to the parent | `loopex chat --service --resume PARENT` resumes it, which the guard admits for a parent; its interrupted `task` call carries the stop-only result and the operator asks again |
| Configuration changed between starts | An existing parent keeps its retained catalog; new parents use the new one |
| Delegation disabled at the next start | The owner still opens because history exists, classifies and guards; the `task` generation is not registered, so an existing parent's `task` call behaves as the delivered foreground does when helpers are disabled on resume |

<a id="technical-adr-0071-stop-order"></a>
**Stop order.** The delivered orderly teardown
(`apps/loopex_daemon/lib/loopex_daemon/service.ex` :1465-1497) stops the
listener, collaboration, runtime, executor and the other edges, the Store
last, then releases placement. It stops no helper owner: `track_delegation/2`
(:614-615) tracks the owner and its writer, no step stops them, and
`Delegation.close/1` is called only by foreground hosts. A permit call
reaches the registry inside the collaboration services, so an owner still
classifying or creating a child after `:collaboration` stopped would exit
and turn a clean stop into `runtime_lost`. M8 adds three steps:

1. `:sign_in_routes`, first: the service removes every `SignIn.Route` the
   service started in `start_binding_plane/1` from its components, unlinks and monitors it, and
   sends each `Process.exit(route, :shutdown)` at once, ADR 0073's route
   shutdown, so a refresh in progress writes its rotated token. A route
   whose `DOWN` reason is `:shutdown` has stopped: unlike
   `stop_classified/3` (:1517-1545), which counts only `@owner_stop_reason`,
   this step counts the reason a trapping route exits with when sent
   `:shutdown`. A route still alive at the smaller of 60,000 ms and the
   teardown deadline is killed, and it, or a route that exits with any other
   reason, ends the stop as `sign_in_route_lost`, as a late component ends
   any step. The service starts each route's custody before the route, and
   `SignIn.Route` only rotates it (ADR 0073), so the delivered `:custody` step later stops every
   custody as before and sees no loss. While the service runs, a route that
   exits is a fail-stop: the routes join the running classes
   (`service.ex` :104-115) as `sign_in_route: :sign_in_route_lost` (123,
   D42), and the delivered `fatal_reason/1` (:1428) sends
   `fatal:sign_in_route_lost` in `daemon.stopping`, the reason D42 adds to
   that record's closed enum.
2. `:helper_quiesce`, before `:collaboration`: the slice loop's task, a
   plain process that answers no `sys` stop request, is removed from the
   service's components, unlinked and killed with `Process.exit(task,
   :kill)`, and the step waits for its `DOWN`, so no slice starts; a slice
   it was waiting on runs on in the owner. Then one `Helper.quiesce/1` (new) call
   sets the owner's `closed` flag and replies. The owner answers it only
   after the callback it is in, a slice or a creation, so every permit call
   that callback makes finds the registry. Core quiesce can leave sessions
   unsettled (`stop_record/1`'s `unsettled`, :1093), so executor jobs may
   still launch; a `launch` after the call refuses `helper_admission_closed`,
   which precedes the permit in ADR 0046's order (`@order`, `helper.ex` :48),
   so nothing acquires a permit once `:collaboration` stops. The call waits
   until the shared teardown deadline less the base `teardown_ms` (30,000 by
   default, `service.ex` :90, :1339), so the steps after it keep the budget
   the delivered teardown gives them, and not for a slice's 60,000 ms
   budget: `Helper.classify/2`
   checks that budget only between sessions and operations (`helper.ex`
   :875, :897, :998, :1673) and a session's stop-only recovery is not bounded
   by it. An owner that has not answered by then is killed and the stop
   fail-stops as `runtime_lost`. Until `Helper.quiesce/1` lands with the
   permit seam (M8 plan step 6), the step only stops the slice task.
3. `:delegation`, immediately after `:executor`, because executor job
   processes call the owner's `launch`, `finish` and `cancel` until
   `:executor` stops: the owner, then its writer, each stopped by
   `stop_classified/3`, so both are gone before the Store stops and before
   the placement release.

The teardown deadline grows by 60,000 ms with a sign-in route and by
65,000 ms with a helper owner, room for one slice or creation in progress.
It does not bound a stop-only recovery: one still running at the deadline
ends the stop as `runtime_lost`, and the next start recovers stop-only as
after any fail-stop.

Startup reverse cleanup (`teardown/1`, :1660-1674, run by
`finish_startup_failure/2`, :880-892) gains the helper steps with its
delivered `stop_component/3` waits: the slice task, if started, before
`:collaboration`, and the owner and its writer after `:executor`, so both
are gone before `release_placement/1` (:889). It stops each route first,
with `stop_component/3`'s 5,000 ms wait (:74), not ADR 0073's 60,000 ms. A running
fail-stop (`fail_stop/2`, :1355-1396) stops only the executor and a live
Store, as delivered; the owner, its writer and every route end with the VM,
which holds the placement lock until it exits. A route ended mid-exchange
by either path can lose a refresh token the provider rotated; the operator
then signs in again. This is the residual the maintainer accepted in D41.

**Child activations.** A helper child, and the prepared owner stop-only
recovery uses to abort one, each start a coordinator in the service's
runtime, so each counts toward ADR 0032's 64 activations exactly as a client
session does. Activation stays one-way: finishing, stopping or settling a
child returns nothing, as ADR 0032 states for every session. The helper owner
creates children through Core, not through the daemon's admission relay, so it
obtains its count from the daemon's session registry through a host-supplied
permit.

*Permit seam.* The helper owner gains one call,
`Helper.bind_activation_permit(helper, {module, extra_args})` (new), and no
`open/4` or `host/4` option. The service binds the pair at startup step 5,
once its registry exists. Once bound, the owner calls three functions with
`extra_args` prepended: `module.acquire(permit_id)`,
`module.settle(permit_id, settlement)` and
`module.account(permit_id, session_id)`. Composition knows only that
contract; Core is not involved and no composition module names a daemon
module. A host that binds no pair, the foreground included, asks for no
permit, counts nothing and never sees `helper_activation_limit`, so the
foreground's behaviour and bytes are unchanged. `LoopexDaemon.HelperActivation`
(new) implements the three functions as one registry call each, over three
new operations of `LoopexDaemon.ConnectionRegistry` below. It does not reuse
`reserve_activation/3` and `resolve_activation/4`: their origin must be a
connection slot, `resolve_activation/4` refuses `:activated` without a
session, and anonymous charging exists only inside the private
`account_create_promotion/3`.

*Helper permit grammar.* A permit is identified by its `permit_id`, the
child's derived create command identity
(`command("loopex:helper-create:v1", runtime_id, operation)`, 64 lowercase
hexadecimal bytes), so one ADR 0046 operation has exactly one permit in a
lifetime. Its origin kind is `{:helper, permit_id}`, a tagged tuple that
`validate_activation_origin/1` never admits and that the new operations
require; a connection origin `{incarnation, 0..31, sequence}` is never
admitted by them. Permits live in their own registry map, `helper_permits`,
keyed by `permit_id`, beside and never inside `activation_bindings`,
`activation_origins` or `activation_create_commands`, so a client create whose
command identity has the same bytes neither joins nor conflicts with a permit.
Each entry is in exactly one state:

| State | Counted in `activations_used` | Meaning |
| --- | --- | --- |
| `held` | One | Acquired; Core has not answered |
| `unknown` | One | Core answered `commit_unknown` with `:no_activation`; the outcome is not yet conclusive |
| `{:activated, session_id}` | Through `activation_set` | Settled; the session is in the registry's activated set |
| `:anonymous` | Through `anonymous_activations` | Settled activated without a session |

A permit released with no activation is removed.

*One counted sum.* The delivered registry computes the ceiling's sum in two
places: `daemon.status`'s `activations_used`
(`apps/loopex_daemon/lib/loopex_daemon/connection_registry.ex` at `e560939d`,
lines 1655 to 1657) and the admission check in the private
`reserve_activation_binding/3` (lines 4050 to 4051), both
`MapSet.size(activation_set) + map_size(activation_reservations) +
anonymous_activations`. Changing only the reported sum would let held helper
permits go uncounted at client admission: with 60 activations used and 4
helper permits `held`, `session.create` would still be admitted as the 61st.
The registry therefore gains one private function, `activations_counted/1`,
returning the delivered sum plus the number of `held` and `unknown` permits,
and every ceiling decision and report uses it: `reserve_activation_binding/3`
refuses `activation_ceiling_reached` when it is at or above 64,
`acquire_helper_permit/2` refuses at or above 64, and `activations_used`
reports it. No other expression of the sum remains. Settled permits are
already in the delivered terms, so nothing is counted twice. The map holds at most one entry per counted
activation, so it is bounded by the ceiling plus recovery accounting.

*Registry operations.* Each is one `GenServer.call` handled atomically in the
registry's serial state, `@doc false`, with the 20,000 ms bound the registry's
listener calls use; a timeout is a defect that ends the owner, below.

| Operation | Effect | Reply |
| --- | --- | --- |
| `acquire_helper_permit(registry, permit_id)` | Absent entry, and `activations_counted/1` below 64: insert `held`. At or above: nothing | `{:ok, :acquired}`; `{:error, :activation_ceiling_reached}`. An existing `held` or `unknown` entry: `{:ok, :held}`, no second charge. A settled entry: `{:ok, {:settled, state}}`, no charge |
| `settle_helper_permit(registry, permit_id, settlement)` | `{:activated, session_id}`: remove the charge, add the session to `activation_set` unless present, record it. `{:activated, nil}`: remove the charge, add one anonymous activation, record `:anonymous`. `:no_activation`: remove the entry. `{:commit_unknown, :activated}`: as `{:activated, nil}`. `{:commit_unknown, :no_activation}`: set `unknown`, keeping the charge | `:ok`. The same settlement repeated, or `:no_activation` for an absent permit, is `:ok` with no effect. A settlement contradicting a settled entry: `{:error, :helper_permit_conflict}` |
| `account_helper_activation(registry, permit_id, session_id)` | Never refused for capacity. Entry `held`, `unknown` or `:anonymous`: convert it to `{:activated, session_id}`, removing its charge or its anonymous count. Absent entry, or `permit_id` `nil`: add the session to `activation_set` unless present. Already `{:activated, session_id}`: nothing | `:ok`; a different settled session for the same permit: `{:error, :helper_permit_conflict}` |

`{:error, :helper_permit_conflict}` and an invalid argument cannot occur from
a correct owner. `HelperActivation` raises on either; the owner exits and the
service fails stop as `runtime_lost`, as for any owner exit.

*Order.* A permit is taken for a new operation after every other check in
ADR 0046's order has passed and after `reserve/4`'s retained-object install
and job-index write (`apps/loopex_composition/lib/loopex_composition/delegation/helper.ex`
:479, :500), immediately before the reserve commit (:504); the amended order
ends `delegation_tokens_exhausted`, `ledger_capacity`,
`helper_activation_limit`. It goes last because every earlier check, the late
`delegation_binding_unavailable` and `helper_index_unavailable` refusals
(:479, :515) included, is decided by the owner alone, while a permit takes a
resource from another process, so a call another check refuses never holds
one. It precedes the reserve commit because ADR 0046 tags a refusal only
before that append, and a refusal there consumes no child count and no token
allowance and writes no reserve frame; a run's first call has already
committed its initialize frame (`run_state/3`, :550-570), as for every
delivered refusal after it. The refusal returns the owner state as it
was before `reserve/4` added the job, its original and its blob (:480-492),
so no `jobs` row counts against `router_registration_capacity` (:415-416) and a
later launch of the same `job_id` is not answered `effect_unresolved`
(:432). Only the installed child-creation object and the job's index entry
remain, which the next coverage publication removes as it removes every
refused registration's (`publish_coverage/1`, :1118-1124). The delivered
`helper_index_unavailable` refusal (:515), which today returns the state
holding the `jobs` row added at :480, is changed to return the same earlier
state. A
cancel that wins before the launch callback refuses
`cancelled_before_registration` (:412) before any permit is taken; within the
callback (:249-255), which runs the checks, the permit, the reserve commit
and the child creation, no cancel can intervene, because `cancel` (:269-283)
is a separate call to the same serial owner.

*Permit lifecycle.*

| Moment | Registry effect |
| --- | --- |
| `acquire` answers `activation_ceiling_reached` | The call returns `{:error, {:refused_before_effect, :helper_activation_limit}}`; no reserve frame is written and no slot or allowance is touched |
| The reserve append or any step before Core's child creation fails | `settle(permit_id, :no_activation)`: the charge is released, as for a client create that activated nothing |
| Core's `create_session_with_genesis_detailed/4` answers `{:ok, %{session_id, disposition}}` | `settle` with `{:activated, session_id}`, or `:no_activation` for a replay |
| It answers `{:error, :commit_unknown, %{disposition: d}}` | `settle(permit_id, {:commit_unknown, d})`. With `:activated`, Core started a coordinator whose session is not named: one anonymous activation, permanent, as `account_create_promotion/3` counts a client create. With `:no_activation`, Core started none in this call but the commit may exist: the charge stays `unknown`. The owner fences the operation as ADR 0056 requires for an unresolved effect |
| It answers any other `{:error, reason, %{disposition: d}}` | `settle` with `{:activated, nil}` or `:no_activation` from `d` |
| A step after Core answered fails: the ledger append that records the child, the prompt or a fence | Nothing more: the owner settles the permit from Core's answer before it runs any later step, so a later failure can neither lose nor repeat the settlement |
| An `unknown` permit's operation is resolved by classification or recovery | The child conclusively absent (`creation_provenance` answers `absent`): `settle(permit_id, :no_activation)` releases it. The child present: `account(permit_id, session_id)` converts it when recovery stops it. Until then it stays counted; a service exit clears it with the registry |
| The child completes, fails, is stopped or is settled | Nothing; the activation stays counted until the service exits |

The owner settles each acquired permit exactly once with a terminal or
`commit_unknown` settlement, and repeats an identical settle after a lost
reply. A repeated identical settle names the same `permit_id`, so the
registry answers `:ok` with no effect and charges nothing twice.

*Recovery.* Stop-only recovery is never refused for capacity: an unfinished
child must be stopped whatever the count. A prepared owner started to abort a
child is counted after the fact with `account(permit_id, session_id)`, which
converts an existing permit or adds the session to the registry's activated
set if it is not there already, and may take the count past 64; while it is,
every new client activation refuses `activation_ceiling_reached` and every new
helper call `helper_activation_limit`. Recovery during the first bind runs
before the registry exists; the owner records those `{permit_id, session_id}`
pairs and `bind_activation_permit/2` returns them, and the service accounts
each before the listener opens. Recovery in later slices accounts each as it
happens. A restarted service starts at zero, as ADR 0032 states, plus
whatever its own recovery accounts.

*What the operator sees.* The parent's model receives the tagged refusal as
the `task` tool's result, as for every ADR 0046 refusal; the parent run
continues and may answer without a helper. The attached conversation shows
that result in the transcript like any refused tool call, and the
foreground-identical projection adds nothing. `daemon.status`'s
`activations_used` includes children. The remedy is the one ADR 0032 gives:
restart the service.

#### Unchanged limits

ADR 0032's residency ceilings apply, including 64 activations per daemon
lifetime; `session.create`, a resume and a helper child each spend one, and
`activation_ceiling_reached` is shown as the service returns it. The
foreground conversation's refusal of a held root stays the delivered
`placement_active`; when that root's socket answers `daemon.readiness`,
standard error adds `attach with: loopex chat --service`.

#### Ownership

| Piece | Module |
| --- | --- |
| Attached dispatch and grammar | `LoopexCli.Chat`, `LoopexCli.ConfigOptions` |
| Attached driver: input, mapping, barrier, leaving, exit | `LoopexCli.AttachedChat` (new), reusing `ChatInput`, `ChatControl`, `Output`, `Render` |
| Shared projection | `LoopexCli.ChatProjection` (new, from `ChatDriver`) |
| Lease, cursor and recovery | `LoopexCli.DaemonSession` (new, from `Live`) |
| Status record nullability | `LoopexCli.ChatControl` |
| Daemon `--config` | `LoopexCli.Daemon`, `LoopexDaemon.Command`, `LoopexDaemon.ExitStatus`, `LoopexCli.HostOptions` (new) |
| Trace and diagnostics in the service | `LoopexDaemon.Service` |
| Helper role capture, catalog and parent genesis | `LoopexCli.HostOptions` (new); `LoopexCli.ChatConfiguration` (`helper_parent/2` split into `helper_roles/1`, `helper_catalog/3`, `helper_parent_genesis/3`) |
| Owner open with delegation enabled, catalog retention, slices, stop order | `LoopexDaemon.Service` |
| Helper creation context on each connection | `LoopexDaemon.Owner`, `LoopexDaemon.ConnectionRegistry` |
| Creation checks and helper-parent routing | `LoopexDaemon.SocketConnection` (`create_task/4`) |
| Detailed parent creation | `LoopexComposition.Delegation` (`create_parent_detailed/7`, new), `LoopexComposition.Delegation.Helper`; `Loopex.Runtime.create_session_with_genesis_detailed/4` (new, `@doc false`) |
| Permit seam, refusal order, child creation through the detailed call and the stop's quiesce | `LoopexComposition.Delegation.Helper` (`@order`; `bind_activation_permit/2` and `quiesce/1`, new) |
| Permit implementation and accounting | `LoopexDaemon.HelperActivation` (new); `LoopexDaemon.ConnectionRegistry` (`helper_permits` state; `acquire_helper_permit/2`, `settle_helper_permit/3`, `account_helper_activation/3`, new; the private `activations_counted/1`, new, used by `reserve_activation_binding/3`, `acquire_helper_permit/2` and `activations_used`); `LoopexDaemon.Service` (step 5) |
| Route guard | Unchanged: `LoopexComposition.Delegation.guard/3`, `LoopexDaemon.SocketConnection.route_guard/3` |

#### Accepted text this record touches

- **ADR 0049, narrowly amended.** Its `status` control record admits `null`
  for `trace` and `policy`, used only by the attached form. The daemon gains
  its file reader under the existing schema, precedence and single alias,
  including the `delegation` and `roles` members.
- **ADR 0032, narrowly amended.** "At most 64 sessions are activated per
  daemon lifetime" counts every coordinator the service's runtime starts:
  `session.create` (a helper parent included), `session.resume`, each helper
  child and each prepared owner stop-only recovery starts. A child is counted
  through the registry's helper permit operations, which charge, settle and
  account it by Core's disposition exactly as a client create is, under a
  helper origin distinct from every connection slot. Recovery activations are counted but never refused, so
  the count may exceed 64 after a restart that recovers children; the ceiling
  then refuses every further activation. Activation stays one-way.
- **ADR 0055, narrowly amended.** On a service with delegation enabled,
  `session.create` refuses `configuration.instructions` and `tools` with
  `helper_parent_option_unsupported`, and the remaining configuration members
  are resolved by the host into the parent's complete genesis instead of by
  runtime Control's creation preparation. A service without delegation keeps
  ADR 0055's behaviour unchanged.
- **ADR 0046, narrowly amended.** Its closed list of tagged pre-effect
  reasons gains `helper_activation_limit`, and its fixed order gains it last,
  after `ledger_capacity`, for the reasons under *Order* above. It is returned
  only by a host that supplies an activation permit, so a host without one,
  the foreground included, sees the order exactly as accepted. The executor
  contract is unchanged: Core already reads any tagged pre-effect refusal.
  Everything else in ADR 0046 is applied as accepted; the daemon is one of the
  resident host routes it already names, and closing creation while
  classification is incomplete on the daemon route implements its existing
  rule.
- **ADRs 0056 and 0069, applied.** Ledger bytes, stop-only recovery and the
  route guard are used as accepted; a refusal before the reserve append writes
  no reserve frame, as ADR 0056 already requires.
- **ADRs 0033, 0044, 0045, 0070, reused.** Lease and takeover, the `/4`
  generation, question expiry and the single-credential plane for a daemon
  without a file are used as accepted.

<a id="technical-adr-0071-evidence"></a>
### Evidence

Concept: [Observable consequences](0071-daemon-attached-conversation.md#concept-adr-0071-consequences).

Every case runs a real `loopex daemon` process and Unix socket; no fake
transport replaces the socket. Files are in `apps/loopex_cli/test` unless
another application is named.

| File (new unless noted) | Kind | Cases it proves |
| --- | --- | --- |
| `attached_chat_grammar_test.exs` | Unit | Each refused flag and combination, with no socket opened and no process started; the error and closing records |
| `attached_chat_test.exs` | Real daemon | Every mapping row on terminal and piped input, reusing the foreground's ordered-input cases; startup report and workspace; `/status` with null trace and policy; `/wait` after a run, a question and a compaction |
| `attached_chat_detach_test.exs` | Real daemon | `/quit`, end of input and `SIGTERM` during an active run: control released, exit `0`, run identity unchanged, no cancellation, the final result seen after reattach; `/abort` ends the run and the conversation continues; exit `1` for an owned failed run |
| `attached_chat_signal_test.exs` | OS signal through `bin/loopex` | `SIGINT`, `SIGHUP` and `SIGQUIT` to the launcher detach with exit `0` and the run continues |
| `attached_chat_lease_test.exs` | Process race | A client killed mid-run, its lease lapsing, a second terminal acquiring control; the stale epoch refused; a second conversation refused while control is held; `attach --observe` watching the same session |
| `attached_chat_reconnect_test.exs` | Real daemon | Transport loss and re-presentation without duplicates; the `detached` slow-reader path; a question pending across detach, service restart and reattach, answered once, and its expiry under ADR 0045 |
| `daemon_configuration_test.exs` | Real daemon | Startup with a valid file, an invalid file and no file; each row of the service-configuration table, including 111, 112, 113 and 115, every 111 before and after the lock writing `loopex daemon refused to start: configuration_invalid <subclass>` with its pointer, if it has one; a file enabling delegation starts and serves; `LOOPEX_PROVIDER_API_KEY` absent from the service's environment afterward. The `:sign_in_routes` stop step is proved by ADR 0073's `daemon_sign_in_test.exs` (`service stop` during a delayed exchange) |
| `apps/loopex_daemon/test/command_test.exs` (extended) | Unit | `--config` and `--admit-project-resources` parsing, the latter refused without `--config`; the cumulative status set at each landing, finally 65 to 125, each used once except 114, which no class maps to |
| `live_daemon_test.exs` (extended) | Real daemon | The activation-ceiling refusal shown to the operator; the foreground conversation's refusal of a service-held root with its hint |
| `daemon_helpers_test.exs` | Real daemon with two saved roles, using the provider isolation fixture the daemon tests use | Startup captures both roles; an attached conversation's prompt makes the parent call `task`; the child completes and the result carries `child`, `delegation`, `parent` and `combined_tokens`, with combined equal to parent plus child; the workspace tree digest is unchanged by the child; a second `task` in the same parent while one runs refuses `helper_slot_occupied`; two parents each run one helper concurrently; the parent's committed original options equal the client's `session_options`; `configuration.instructions` and `tools` each refuse `helper_parent_option_unsupported`; a repeated create identity returns the same parent and spends no second activation; a role whose instruction file is unreadable exits 111 naming `/roles/NAME` with no lock, log entry or socket; a service-created parent resumes under the foreground conversation and a foreground-created parent under the service |
| `daemon_helper_restart_test.exs` | Process fault, real daemon | `SIGTERM` and `SIGKILL` to the service after the child is prompted and while its provider reply is held; the restart reports `classifying` then `serving`; the child is aborted and its provider receives no second prompt; the parent's `task` result is the stop-only outcome; the slot is released on conclusive evidence and stays occupied otherwise; a torn final ledger frame recovers under ADR 0056; `session.create` and every mutation during classification refuse `helper_classification_incomplete`; a restart with delegation disabled classifies and guards the same history; each prepared owner recovery starts is counted in `activations_used` (a count past 64 is `helper_activation_registry_test.exs`'s); **stop order**: `SIGTERM` while a classification slice is held at a gated store adapter for longer than 65,000 ms (the gate released while at least the base 30,000 ms remain before the teardown deadline) and while a child creation is held in Core each exit `0`, with the owner and its writer gone before the placement lock file is removed; a `task` launch that reaches the owner after the quiesce call refuses `helper_admission_closed` and calls no `acquire`; a startup failure injected after step 5 exits with its class, with the slice task, the owner and its writer gone before the lock file is removed |
| `daemon_helper_activation_test.exs` | Real daemon at the delivered limit of 64, using the provider isolation fixture; no test-only limit | One parent whose children spend activations until the 64th: the next `task` call returns `helper_activation_limit` as its tool result, writes no reserve frame, charges no child count or tokens, and the parent's run completes; mixed: client sessions and children together reach 64, after which `session.create` refuses `activation_ceiling_reached` and a `task` call `helper_activation_limit`; a child creation held at Core and answered `commit_unknown` keeps its charge in `activations_used` until the operation resolves; one-way: a child that completes, fails or is stopped through its parent keeps its activation counted; `daemon.status` reports children in `activations_used`; the attached conversation shows the refusal in the transcript |
| `apps/loopex_composition/test/delegation_activation_permit_test.exs` | Unit, fake permit module | The refusal is decided after `ledger_capacity` and the job-index write and before the reserve commit, and the job's index entry it leaves is removed by the next coverage publication; every earlier refusal, `helper_index_unavailable` included, is returned without calling `acquire`; an owner with no bound pair never refuses and leaves the order as accepted; each acquired permit is settled exactly once on every path, with Core's disposition for `{:ok, _}`, `commit_unknown` with each disposition and other errors; a failure injected after Core's answer (the child ledger append, the prompt) leaves the settlement already made and makes no second one; a repeated identical settle reuses its `permit_id` and changes nothing; a reserve append that fails definitely, made so by the test's delivered `:fault` callback at `:before_reserve` (`helper.ex` :502) replacing the run's ledger file with a symbolic link, as `delegation_binding_log_test.exs` :575 refuses a binding log, answers the launch `effect_unresolved` without fencing the owner and settles the permit `:no_activation`, as does a child creation that activates nothing; 4,097 calls refused `helper_activation_limit` leave the owner's `jobs` unchanged, so `router_registration_capacity` is not reached, and the same `job_id` launched again after a refusal is not answered `effect_unresolved`; after `helper_index_unavailable`, `jobs` is unchanged and a relaunch is not `effect_unresolved`; recovery calls `account` with the permit and never `acquire`; an `unknown` permit is released on conclusive absence and converted on recovery; `{permit_id, session_id}` pairs recovered before `bind_activation_permit/2` are returned by it |
| `apps/loopex_daemon/test/helper_activation_registry_test.exs` | Real `ConnectionRegistry` process, no fake | `acquire` up to the ceiling and `activation_ceiling_reached` at 64 with clients and permits mixed; a repeated `acquire` answers `held` or the settlement and charges once; `{:activated, nil}`, which `resolve_activation/4` refuses, counts one anonymous activation; `{:commit_unknown, :activated}` counts one anonymous activation and a later `account` with the session converts it without a second count; `{:commit_unknown, :no_activation}` stays in `activations_used` until a `:no_activation` settle releases it or `account` converts it; identical settles are idempotent and a contradicting one is `helper_permit_conflict`; `account` past 64 is admitted and then refuses every new client activation and `acquire`; a `{:helper, _}` origin is refused by `reserve_activation/3`, a connection origin by the helper operations, and a client create whose command identity equals a `permit_id` neither joins nor conflicts; `daemon.status`'s `activations_used` equals `activations_counted/1` at every step; the shared sum, both directions: with 60 client activations and 4 permits `held` (then the same with `unknown`), a client `session.create` reservation through `reserve_activation_binding/3` refuses `activation_ceiling_reached`, and with 60 client activations plus 3 held permits it is admitted as the 64th and the next `acquire` refuses `activation_ceiling_reached`; releasing one held permit with `:no_activation` readmits exactly one client reservation |
| `apps/loopex_composition/test/delegation_create_parent_detailed_test.exs` | Unit, real runtime | `bind_parent` failing, refused and fencing after Core activated the parent: the error carries `disposition: :activated` and the session; a failure before Core carries `:no_activation` and `nil` |
| `apps/loopex_daemon/test/helper_parent_activation_test.exs` | Socket, real registry | The same post-create binding failure through `session.create`: the admission is refused, `activations_used` rises by one, the session is not in the index, and the next creation still succeeds below the ceiling |
| `apps/loopex_daemon/test/helper_route_guard_test.exs` (extended) | Socket | Every mutating `/4` method on a helper child refuses `helper_session_owned` and the child's records are unchanged; attach, inspect and history on the child are admitted; resuming a dormant child refuses; killing the owner makes every mutation refuse `helper_owner_unavailable` and the service exit `runtime_lost` |
| `apps/loopex/test/runtime_create_with_genesis_detailed_test.exs` | Unit | `create_session_with_genesis_detailed/4` reports `:activated` for a fresh create, no activation for a replay and the same refusals `create_session_with_genesis/4` projects |
| `apps/loopex_cli/test/chat_configuration_test.exs` (extended) | Unit | `helper_parent/2` and its three parts in sequence produce byte-identical role geneses, catalog digest and parent genesis |

The attended reconnect case is ADR 0038's installed demonstration: start a
task with `loopex chat --service`, close the terminal, reconnect from another
with `--resume`, see the result. The attended helper case, `m8.service-review`,
runs M7's `m7.review` fixture profile (roles `investigate` and `review` on the
second pinned provider, the parent on the first) through the installed
service: prompt, detach while a helper runs, reconnect, see the receipts with
separate and combined usage; then `loopex service stop` during a second
helper, restart, reconnect and see the stop-only result. Controller and
replay conformance suites run unchanged.

<a id="technical-adr-0071-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0071-daemon-attached-conversation.md#concept-adr-0071-compatibility).

The command is one more peer over the daemon generation. It adds no core
command, record or facade function, and the session coordinator remains the
sole writer. The lease stays in daemon memory under ADR 0033. Helper hosting
adds `Loopex.Runtime.create_session_with_genesis_detailed/4`, an undocumented
unprojected form of an existing call, and changes no wire schema, vector,
stored record or ledger byte. Removing helper hosting returns the service to
classify-and-guard only; the retained ledger stays readable by the foreground
conversation and by a later service.

**Alternatives rejected.**

- *Refuse a file that enables delegation.* An earlier draft did this. The
  maintainer decided on 2026-10-13 that the service hosts helpers, so the same
  configuration behaves the same through either host.
- *Capture roles and instructions at each creation.* It would let one service
  create parents with different catalogs from one configuration and make a
  create replay depend on files changing during the lifetime. Freezing them
  at start matches the service's other session defaults.
- *Let core's creation preparation build the helper parent.* Core would have
  to learn the catalog and the `task` binding, which ADR 0046 keeps in
  composition.
- *Leave helper children uncounted.* An earlier draft did this. It let a
  service left running accumulate child coordinators beyond the ceiling ADR
  0032 sets; the maintainer decided on 2026-10-13 that children count.
- *A separate ceiling for children.* It would add a second limit to explain
  and tune while bounding the same resource.
- *Refuse recovery when the limit is reached.* An unfinished child would then
  stay unstopped, which ADR 0046's stop-only rule forbids.
- *Insert the new refusal earlier in the order.* A permit taken before a later
  check refuses would have to be returned on that path, and a refusal would
  then depend on another process's state ahead of the owner's own checks.
- *Count children through the admission relay.* The relay serves client
  requests and connection origins; children are created by the helper owner
  inside a parent's tool job, which has no connection.

- *A daemon the conversation starts and owns privately.* It makes the terminal
  the owner of session lifetime again and excludes a second terminal.
- *Abort on interrupt, as the foreground conversation does.* The foreground
  rule exists because its runtime dies with the terminal. Attached, it would
  make the most common way of leaving a terminal destroy the work the service
  exists to keep, and would differ from every existing daemon command.
- *Implicit attachment whenever a service is running.* A command that changes
  which process owns the workspace, policy and credentials according to
  ambient state hides the most important fact about a session.
- *Client-supplied configuration.* Letting a client name roles, policy or
  provider bindings would move host authority across the socket, which ADR
  0032 and M7's `session.create` rules refuse.
- *Waiting for another holder's lease.* `attach --take-over` already waits;
  the conversation refuses at once so a second terminal never silently queues.
- *Service-side compaction defaults.* They would add a protocol member to
  carry values the foreground command already fixes.
- *An observer mode on the conversation command.* `attach --observe` already
  exists; a second spelling adds grammar and no capability.
- *A second conversation protocol for terminals.* The daemon generation
  already carries the actions; a parallel surface would need its own vectors
  and would drift.
- *Network attachment.* The remote-ecosystem rung owns it, behind its own
  threat model.
