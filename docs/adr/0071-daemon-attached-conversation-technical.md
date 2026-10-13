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
`config` and `admit-project-resources` (ADR 0037). Without `--config` every
M7 rule is unchanged.

| Daemon input | With `--config` |
| --- | --- |
| `--state-root`, `--workspace`, `--policy`, `--cleanup-grace-ms` | ADR 0049 flags with their chat names, passed to `ConfigSelection.compose/4` as overrides; origin `flag` |
| `--socket` | Unchanged; daemon-only |
| `--provider-launch` | Refused `provider_launch_conflict` |
| `LOOPEX_HOME` | ADR 0049's state-root alias, as in chat |
| `LOOPEX_WORKSPACE`, `LOOPEX_POLICY`, `LOOPEX_PROVIDER_LAUNCH` | Not read: ADR 0049 admits one alias. `loopex doctor` lists none of them |
| Provider launch | The build's `LoopexCli.ProviderLaunch.options/0`, as chat uses |
| `LOOPEX_PROVIDER_API_KEY` | Deleted from the environment unread unless a binding names it, exactly as `CredentialPlane.load_bindings/2` does for chat; the version-2 single-credential plane is not started |
| `providers.*.credential.env` | Each must be present and nonempty before any lock, else `provider_credential_absent`; loaded by the delivered binding plane |
| `delegation.enabled: true` | Refused `service_delegation_unsupported`, `/delegation/enabled` |
| `trace` | Started with `Loopex.trace/2` after composition and before the listener; diagnostics go to the service's standard error through `LoopexComposition.DiagnosticConsumer`; failure is `trace_start_failed` |

Startup order under `--config`: parse; `ConfigFile.load/2`,
`ConfigSelection.compose/4`, instruction capture and
`ChatConfiguration.genesis/3`; reference presence; then the delivered
start. The composition options are the ones `LoopexCli.Chat`'s private
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
| 111 | `configuration_invalid` | ADR 0049's reader, schema, selection or resolution refused; the diagnostic line adds its class and pointer |
| 112 | `provider_launch_conflict` | `--provider-launch` with `--config` |
| 113 | `provider_credential_absent` | A configured reference is absent; the line adds the pointer |
| 114 | `service_delegation_unsupported` | The file enables delegation |
| 115 | `trace_start_failed` | The file enables a trace that does not start |

ADR 0072's root refusals take the statuses after 115. The module's
"every integer from 65 through 110" statement becomes "through 115".

#### Unchanged limits

ADR 0032's residency ceilings apply, including 64 activations per daemon
lifetime; `session.create` and a resume each spend one, and
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

#### Accepted text this record touches

- **ADR 0049, narrowly amended.** Its `status` control record admits `null`
  for `trace` and `policy`, used only by the attached form. The daemon gains
  its file reader under the existing schema, precedence and single alias.
- **ADRs 0032, 0033, 0044, 0045, 0055, 0070, reused.** Attachment, replay,
  lease and takeover, the `/4` generation, question expiry, remote creation
  options and the single-credential plane for a daemon without a file are
  used as accepted.

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
| `daemon_configuration_test.exs` | Real daemon | Startup with a valid file, an invalid file and no file; each row of the service-configuration table, including 111 to 115; `LOOPEX_PROVIDER_API_KEY` absent from the service's environment afterward |
| `apps/loopex_daemon/test/command_test.exs` (extended) | Unit | `--config` and `--admit-project-resources` parsing; statuses 65 to 115 each used once |
| `live_daemon_test.exs` (extended) | Real daemon | The activation-ceiling refusal shown to the operator; the foreground conversation's refusal of a service-held root with its hint |

The attended reconnect case is ADR 0038's installed demonstration: start a
task with `loopex chat --service`, close the terminal, reconnect from another
with `--resume`, see the result. Controller and replay conformance suites run
unchanged.

<a id="technical-adr-0071-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0071-daemon-attached-conversation.md#concept-adr-0071-compatibility).

The command is one more peer over the daemon generation. It adds no core
command, record or facade function, and the session coordinator remains the
sole writer. The lease stays in daemon memory under ADR 0033.

**Alternatives rejected.**

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
