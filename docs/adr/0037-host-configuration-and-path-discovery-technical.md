<a id="technical-depth"></a>
## Technical depth

Concept: [Installed host configuration and path discovery](0037-host-configuration-and-path-discovery.md#concept).

<a id="technical-adr-0037-decision"></a>
### Contract

Concept: [Context and decision](0037-host-configuration-and-path-discovery.md#concept-adr-0037-decision).

Everything below was checked against the delivered M7 source at `9b917387`.
Names in `code` are existing modules unless marked new; every new module
lives in `apps/loopex_cli` unless another application is named.

#### Home discovery and file selection

| Input | Rule |
| --- | --- |
| `HOME` | Read once per command by `LoopexCli.Home` (new). Must be a nonempty, absolute, valid UTF-8 path of at most 4,096 bytes; otherwise `home_unavailable`. Never expanded, never followed beyond `Path.absname` |
| Home | `Path.join(HOME, ".loopex")` on `darwin-arm64` and `linux-x86_64` alike |
| Discovered file | `<home>/config.json` |
| `--config FILE` | Resolved against the invocation directory exactly as `LoopexCli.ConfigFile.load/2` does today; wins over the discovered file |
| Neither present | A command that needs configuration refuses `configuration_not_found`, naming the discovered path and `loopex init` |

`LoopexCli.Home.select/2` takes the parsed `--config` value and an injected
environment reader and returns `%{file: abs, selected_by: :flag | :home,
home: abs}`. Selection reads no file; `ConfigFile.load/2` then reads it under
ADR 0049's unchanged 256 KiB reader, schema and resolver. No project file,
XDG directory, `LOOPEX_CONFIG`-style variable or interpolation is consulted.

State-root precedence is ADR 0049's, unchanged: `--state-root` flag >
`LOOPEX_HOME` > the file's `paths.state_root` (relative to the file's
directory). No home-derived default is added to the resolver: `init` writes
`"state_root": "state"`, so the installed root is `<home>/state` through the
file. The service socket is always `LoopexDaemon.Paths.startup(root,
nil).socket_path`, that is `<root>/daemon/daemon.sock`; at the default home
it fits macOS's 103-byte limit whenever `HOME` is at most 70 bytes, and a
longer path refuses with the delivered `socket_path_too_long`.

Inspection reports the selection without a new origin member: `config show`
prints one leading line `Configuration file: <abs path> (selected by
--config)` or `(selected as the default home)` before its existing rows, and
every value read from the file keeps ADR 0049's `file#pointer` origin.

#### Home layout

```text
$HOME/.loopex/              0700, created by init (one mkdir, never -p)
  config.json               0600, written only by the writers below
  .config-writer/           0700, holds the writer lock
  auth/                     0700, ADR 0073's sign-in metadata and file-fallback token store
  log/                      0700, created by the first service start
    service.log             0600, the service's stdout and stderr, appended
    service.log.1           the previous log, kept once
    start-<16 hex>.exit     one start's exit status, read and removed by its starter
  state/                    the state root; created and marked by ADR 0072's rule
```

The same layout applies beside any explicitly selected file: its writer lock
and `log/` live in the selected file's directory. Nothing is ever written
inside the state root by these commands; the root is created only by the first
command that opens it, under ADR 0072's marker rule.

#### Command grammar

```text
loopex init --workspace DIR --policy NAME --provider PROVIDER
            --credential-env NAME --model PROVIDER:MODEL
            --max-steps N --deadline-ms MS --token-budget N [--config FILE]
loopex config set POINTER JSON [--config FILE]
loopex config unset POINTER [--config FILE]
loopex config validate [--config FILE] [ADR 0049 overrides]
loopex config show [--config FILE] --effective [ADR 0049 overrides]
loopex paths [--config FILE]
loopex doctor [--config FILE]
loopex service start [--config FILE]
loopex service stop [--config FILE]
loopex service status [--config FILE]

loopex chat    --service [--config FILE] ...        ADR 0071
loopex run     --service [--config FILE] [--steer TEXT | --follow-up TEXT] PROMPT
loopex resume  --service [--config FILE] SESSION
loopex attach  --service [--config FILE] SESSION [--observe | --take-over [--prompt TEXT]] [--after SEQ]
loopex sessions --service [--config FILE] [--status | --limit N --after SESSION]
```

Every value flag takes one nonempty value in `--flag value` or `--flag=value`
form, no flag repeats, `--` ends options, and every refusal happens before
any file write, socket or process. `--service` and `--daemon` are mutually
exclusive (`service_and_daemon`); `--config` on a live form requires
`--service` (`config_requires_service`). `LoopexCli.Live`'s per-form flag
table gains `service: :boolean` and `config: :value`; the socket is resolved
from the selected file and then the delivered drive paths run unchanged.
`--config` on `config validate` and `config show` becomes optional; this is a
narrow amendment of ADR 0049's grammar, which required it, and its reader,
precedence and origins are unchanged.

#### Configuration writers

`LoopexCli.ConfigWriter` (new) owns `init`, `config set` and `config unset`.

- **`init`.** All nine value flags are required except `--config`, because
  ADR 0049 forbids spending and authority defaults. It writes exactly
  `schema_version: 1`, `paths.workspace` (the flag resolved to an absolute,
  existing directory), `paths.state_root: "state"`, `providers.PROVIDER:
  {"credential": {"env": NAME}}`, `policy`, `session.model` and
  `session.bounds`. It refuses an existing file (`configuration_exists`) and
  creates only the file's directory when absent and its parent exists.
- **`config set POINTER JSON`.** `POINTER` is an RFC 6901 pointer into the
  schema-version-1 document; `JSON` is one JSON value text (a string is
  quoted). Missing intermediate objects are created; an array is replaced
  whole. `/schema_version` refuses `configuration_member_fixed`.
- **`config unset POINTER`.** Removes the member; removing a required member
  refuses through validation.

Every write runs the same stages: take the lock; read the current bytes
(`init`: none); build the candidate; validate it with
`ConfigSchema.validate/1`, then `ConfigFile` path resolution and
`ConfigInspection.prepare/3`'s model, instruction and genesis checks against
the candidate's own directory; encode it with keys in byte order, two-space
indentation and one trailing LF (authored formatting is not preserved); write
`config.json.tmp-<16 hex>` opened `[:raw, :binary, :write, :exclusive]` with
mode 0600; `:file.sync/1`; `File.rename/2`; sync the directory with the
`[:raw, :read, :directory]` open-and-sync the session index storage already
uses; release the lock. A refusal names a class and pointer and never the
value. Any failure before the rename deletes the temporary and leaves the
earlier bytes; a failure after it reports `configuration_sync_unconfirmed`
with the new bytes in place. A credential value cannot be written: the schema
admits only environment-reference names. Success prints `Configuration
written: <path>` or `Configuration updated: <pointer>` and, when the selected
service answers `daemon.readiness`, `the running service keeps its startup
configuration; restart it to apply this change`.

The lock uses the placement lock primitive that M8 extracts into one shared
private module (the same primitive ADR 0073's refresh lock uses), on the
`.config-writer` directory, never `Placement.acquire/2`, whose first step
admits a state root under ADR 0072 and must not mark a lock directory. Its
record binds the owning OS process to its
observed start identity and a stale lock is reclaimed only when that
incarnation is gone; a PID alone is never proof. A live holder refuses
`configuration_locked`, naming its PID. The lock is released after the
directory sync.

#### Commands that use the service

| Command | Resolves the socket from | Starts on demand | When no service answers |
| --- | --- | --- | --- |
| `chat --service` | Selected file | Yes | Start, then attach under ADR 0071 |
| `run --service`, `resume --service` | Selected file | Yes | Start, then the delivered live drive |
| `attach --service`, `sessions --service` | Selected file | No | Refuse `service_not_running` |
| Any form with `--daemon SOCKET` | The flag | No | The delivered `cannot reach a daemon at that socket` |
| `service start` | Selected file | Yes, and may ask | Start |

#### On-demand start

`LoopexCli.ServiceStart` (new) runs this machine for every row marked "Yes".
All waits yield to the command's signal route exactly as `LoopexCli.Live`'s
`pause/1` does; a signal stops waiting, never the service.

| State | Action | Next |
| --- | --- | --- |
| `select` | `Home.select`, `ConfigFile.load`, `ConfigSelection.compose` with no overrides; derive root and socket | `probe`; a load or selection refusal ends the command with its class and pointer |
| `probe` | `DaemonClient.connect(socket, timeout: 1_000)` | answers: `readiness`; else live `Placement.live_owner(root)`: `wait`; else `precheck` |
| `precheck` | For each `providers.*.credential.env`, test presence and nonemptiness of the variable without retaining, printing, hashing or comparing the value; for each `providers.*.credential.oauth` route, read only ADR 0073's non-secret sign-in metadata and refuse `provider_sign_in_required` naming the route when it is absent or signed out | all present: `spawn`; else refuse `provider_credential_absent` naming the first absent pointer (for example `/providers/anthropic/credential/env`), with no process, lock, log or socket created |
| `spawn` | Rotate the log, then start the detached service as below and record `t0` | `wait` |
| `wait` | Every 250 ms until `t0 + 75_000`: connect; else read this start's `log/start-<16 hex>.exit` | answers: `readiness`; exit status 76 (`placement_active`): stay in `wait`, another start won; any other status: refuse with its `LoopexDaemon.ExitStatus` class; deadline: refuse `service_not_ready`, naming `starting` or the live holder's PID |
| `readiness` | `daemon.readiness` | `serving`: done; `closed`: refuse `service_closed` with the session, its code and `loopex store restore`; `classifying` or `unavailable`: poll every 1,000 ms until the same deadline, then refuse `service_not_serving` with the last answer |

The 75,000 ms bound is the delivered startup gate (`@owner_start_gate_ms`
5,000) plus one ADR 0046 classification slice (60,000), the startup arbiter's
readiness write (`@output_deadline_ms` 5,000) and 5,000 for VM boot. A
command that found the service already running uses the same deadline,
measured from its own start. A refused start leaves any spawned service
running; the refusal tells the operator to read `loopex service status`.

**Detached spawn.** The starter runs `/bin/sh` with one asynchronous list:

```text
/usr/bin/nohup /bin/sh -c 'c=$0 f=$1 l=$2 e=$3; shift 3
  "$c" daemon --config "$f" "$@" </dev/null >>"$l" 2>&1
  printf "%s\n" "$?" >"$e.tmp" && mv "$e.tmp" "$e"' \
  COMMAND FILE LOG EXIT [--admit-project-resources DIGEST] </dev/null >/dev/null 2>&1 &
```

`COMMAND` is resolved from the location of the running escript, never from
the environment, exactly as ADR 0038's `LoopexCli.ProviderLaunch.options/0`
resolves the release root. With `script = Path.expand(:escript.script_name())`:
when `MANIFEST` is a regular file in the release root, `script` with two
directory levels removed (the installed `libexec/loopex`), `COMMAND` is
`bin/loopex` under that root, the same installed-mode test ADR 0038's
launcher applies; otherwise, in a checkout, it is the launcher beside the
escript, `Path.join(Path.dirname(script), "bin/loopex")`. The selected path
not being an executable regular file refuses `service_command_unavailable`;
no fallback path is tried. The service therefore starts with
`SIGHUP` ignored by `nohup` and `SIGINT` and `SIGQUIT` ignored as an
asynchronous list. Because those three were ignored on entry, the launcher's
own traps for them cannot be installed (POSIX), while its `SIGTERM` forward
still works for `service stop`. Standard input is `/dev/null`, so
`ProjectResources.operator_present?/0` is false and the delivered decision
path leaves project resources unadmitted without asking. The environment is
the starter's own; nothing else supplies credentials. Before spawning, a log
over 1,048,576 bytes is renamed to `service.log.1`.

#### Readiness

`daemon.readiness` (new) is a `loopex.experimental/4` method beside
`daemon.status`: closed request `{}`, a relay permit like `daemon.status`, no
attachment and no lease. Its `result` has exactly these members:

| Member | Value |
| --- | --- |
| `state` | `serving`, `classifying`, `closed` or `unavailable` |
| `covered`, `enumerated` | Canonical decimal strings when `classifying`, else `null` |
| `session_id` | The unreadable session's identity when `closed`, else `null` |
| `code` | `closed`: `invalid_history`, `history_unavailable` or `session_absent`; `unavailable`: `store_unavailable`, `unexpected` or `runtime_unavailable`; else `null` |
| `recovery` | `restore_from_backup` when `closed`, else `null` (ADR 0072) |
| `project_resources` | `absent` (no manifest), `unadmitted` (no decision) or `admitted` |
| `workspace` | The service's absolute workspace path, at most 4,096 bytes |
| `configuration_file` | The absolute file given to `--config`, or `null` |
| `version` | The `VERSION` the service was compiled from, as in its `daemon_ready` line |

`LoopexDaemon.ServiceReadiness` (new, `apps/loopex_daemon`) computes it
within one 1,000 ms read: `Loopex.creation_startup_status(runtime, 1_000)`
not ready is `unavailable`/`runtime_unavailable`; with no helper owner, ready
is `serving`; otherwise the helper owner's bounded status decides:
`:complete` is `serving`; an incomplete pass with a named session is
`closed`; budget exhaustion or a still pending pass is `classifying`; an
incomplete pass carrying a code is `unavailable`. The helper's incomplete
value, today `{:incomplete, covered, enumerated, failed}`, gains its reason so
the code can be reported; that value is composition-private. While a pass is
incomplete without a named session, the service runs a further 60,000 ms
`Helper.classify/2` slice from a linked task one second after the last one
ends, as ADR 0046 requires of a resident host. The schema addition updates
`loopex-experimental-4.json` (method list, `initialized.supported_methods`,
result definition), its vectors, the pinned digest in
`LoopexCli.DaemonClient` and `clients/node/contract-manifest.mjs`, and
`clients/node/daemon-client.mjs`.

#### Lifecycle and diagnostic commands

`LoopexCli.Service` (new) owns `service start|stop|status`, `paths` and
`doctor`. Each prints exactly one compact JSON object and one LF on standard
output with keys in the order listed, as `sessions --daemon --status` does.

- **`service start`.** Runs the on-demand machine. Before `spawn`, when
  standard input is an interactive terminal, it shows the workspace's project
  resources with `ProjectResources.discover/1` and asks as the daemon does; a
  yes passes `--admit-project-resources DIGEST` (64 lowercase hex), which the
  daemon honours only when the manifest it discovers has that exact digest and
  otherwise starts unadmitted. A service already running is reported, not
  restarted, and its admission cannot change until it is restarted. Prints the
  status object; exits `0` when `serving`, else `1`.
- **`service stop`.** With no live placement owner it prints `stopped` and
  exits `0`. When the socket answers and `daemon.status`'s
  `placement_identity` equals `Loopex.runtime_placement_id(root)`, it
  re-verifies the owner's incarnation, sends that BEAM process `SIGTERM`, and
  polls every 250 ms until the owner is gone, printing `loopex: stopping
  (Ns)` on standard error every 5,000 ms. It sets no bound of its own, because
  the [daemon's stop bound](../operator/daemon.md#operator-daemon-stop-bound)
  depends on the root's cancellation budget; a signal ends only the wait,
  with exit `130` and `the service is still stopping`. It exits `0` when the
  owner is gone and the placement lock file is gone, else `1` with
  `stop_unconfirmed` and the log path. A live owner whose socket does not answer is a foreground
  command or a service still starting: it refuses `root_held` with the PID and
  never signals it.
- **`service status`.** Keys: `state` (`stopped`, `held`, or a readiness
  state), `pid`, `socket`, `state_root`, `configuration_file`, then the
  readiness members (`null` when nothing answers). A live owner whose socket
  does not answer is `held`: a service still starting or a foreground command;
  only a starter, which knows it spawned one, reports `starting`. Exits `0` for `serving`, `3` for any other state, `1` when it cannot
  determine one.
- **`paths`.** Keys: `home`, `configuration_file`, `selected_by` (`flag` or
  `home`), `state_root`, `workspace`, `socket`, `log_directory`. Exits `1`
  only when the file cannot be loaded.
- **`doctor`.** Keys: `configuration_file`, `selected_by`, `configuration`
  (`valid` or `<class> <pointer>`), `state_root`, `workspace`, `socket`,
  `credentials` (one `{"pointer":…,"present":…}` per configured reference;
  environment names are not printed, as ADR 0049 redacts them),
  `legacy_credential` (`absent`, or `present_ignored` for
  `LOOPEX_PROVIDER_API_KEY`), `root` (ADR 0072's marker, holder and backup
  format object, by reference), `service` (the `service status` object) and
  `version`. It reads no credential value and no session record. Exits `0`
  when the file is valid, every reference is present, ADR 0072's check accepts
  or the root is absent, and the service is `stopped` or `serving`; else `1`.

#### Refusals

Command refusals print `loopex: <class> [<pointer>]` and a fixed hint on
standard error and exit `1`: `home_unavailable`, `configuration_not_found`,
`configuration_exists`, `configuration_member_fixed`, `configuration_locked`,
`configuration_sync_unconfirmed`, ADR 0049's existing load and validation
classes, `service_and_daemon`, `config_requires_service`,
`service_not_running`, `provider_credential_absent`,
`service_command_unavailable`, `service_not_ready`, `service_closed`,
`service_not_serving`, `root_held`, `stop_unconfirmed`, and a daemon start refusal under its
`LoopexDaemon.ExitStatus` class name.

#### Ownership

| Piece | Module |
| --- | --- |
| `HOME`, file selection, layout paths | `LoopexCli.Home` (new) |
| `init`, `config set`, `config unset`, lock and atomic write | `LoopexCli.ConfigWriter` (new) |
| Optional `--config`, selection line | `LoopexCli.ConfigOptions`, `LoopexCli.ConfigInspection` |
| On-demand machine, spawn, wait | `LoopexCli.ServiceStart` (new) |
| `service`, `paths`, `doctor` | `LoopexCli.Service` (new); dispatch in `LoopexCli` |
| `--service` on live forms | `LoopexCli.Live` |
| `--config`, `--admit-project-resources` | `LoopexCli.Daemon`, `LoopexDaemon.Command` (ADR 0071) |
| `daemon.readiness` and the slice loop | `LoopexDaemon.ServiceReadiness` (new), `LoopexDaemon.Service`, `Request`, `SocketConnection`, `WireRecords`; `LoopexComposition.Delegation.Helper` |

#### Accepted text this record touches

- **ADR 0003, amended.** Its rule "No Loopex application reads a user home
  directory" gains one exception: `LoopexCli.Home` in the installed reference
  host reads `HOME` and passes absolute paths inward. No other application or
  adapter gains discovery authority, extension-source admission is unchanged,
  and "no test or helper may point at a real one" stands: the CLI test helper
  sets `HOME` to its temporary root beside `LOOPEX_HOME` and fails before any
  test if either escapes it.
- **ADR 0049, narrowly amended.** `--config` becomes optional on `chat`,
  `config validate` and `config show` when a home is selected; schema,
  precedence, origins and the single `LOOPEX_HOME` alias are reused unchanged.
- **ADR 0046, reused.** Its resident-host slicing rule is implemented as
  stated; nothing about classification changes.
- **ADRs 0031 and 0032, reused.** Placement lock, socket placement and the
  stop bound are unchanged.

<a id="technical-adr-0037-evidence"></a>
### Evidence

Concept: [Observable consequences](0037-host-configuration-and-path-discovery.md#concept-adr-0037-consequences).

Every case uses a temporary `HOME` and `LOOPEX_HOME`. Test files are in
`apps/loopex_cli/test` unless another application is named.

| File (new unless noted) | Kind | Cases it proves |
| --- | --- | --- |
| `home_test.exs` | Unit | Absent, relative, non-UTF-8 and oversized `HOME` refuse; default path on each platform; `--config` wins; missing discovered file refuses naming `init`; a `config.json` in the invocation directory is ignored |
| `config_inspection_test.exs` (extended) | Unit | Explicit and discovered selection of the same bytes give identical rows and origins; the selection line; `LOOPEX_HOME` still overrides the file's root |
| `config_writer_test.exs` | Unit and fault | `init` refuses an existing file and each missing flag; written document validates and holds no value outside the schema; `set` and `unset` pointer rules and `/schema_version`; kill points before the temporary write, before rename and after rename leave prior bytes or the new bytes, never a partial file; a live lock refuses; a lock whose incarnation is gone, including a reused PID, is reclaimed; modes 0700 and 0600 |
| `service_start_test.exs` | Process race | Eight concurrent starters spawn at most eight daemons and all converge on one serving socket, the others recording 76; an absent reference refuses before any process, lock, log or socket; presence check reads no value (sentinel variable never appears in any output or log); a started service's readiness says `unadmitted`; the 75,000 ms bound reports `starting` with an injected slow start; an early exit maps its status to its class; the spawned command is `<root>/bin/loopex` for an escript at `<root>/libexec/loopex` beside a `MANIFEST` and the launcher beside a checkout escript, unchanged with `LOOPEX_ESCRIPT` and any other variable set to a different tree; a non-executable selection refuses `service_command_unavailable` |
| `service_command_test.exs` | Real daemon | `start`, `stop`, `status`, `paths` and `doctor` objects and exit statuses; `stop` refuses a foreground holder and never signals it; `doctor` with a service running reads readiness from it and opens no session record |
| `service_detach_pty_test.exs` | PTY | A service started on demand from a PTY survives `SIGINT` to the foreground group and hangup of the PTY, and stops on `service stop` |
| `live_service_test.exs` | Real daemon | `run` and `resume --service` start on demand; `attach` and `sessions --service` refuse `service_not_running`; `--daemon` never starts |
| `apps/loopex_daemon/test/readiness_method_test.exs` | Socket | Each of the four states from helper and runtime seams; the `closed` session and code; project-resource values; schema vectors and the updated digest |
| `clients/node` contract lane (extended) | Independent client | `daemon.readiness` decoded from the schema by the Node client |

The installed demonstration under ADR 0038 runs `init`, `chat --service`,
`service status`, `doctor`, `service stop` and backup and restore with the
actual archive. M7 does not claim these outcomes.

<a id="technical-adr-0037-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0037-host-configuration-and-path-discovery.md#concept-adr-0037-compatibility).

One JSON schema and resolver is preferred to a second installed configuration
system. Installation, default home and management do not alter committed
session settings. Provider file credentials and live rotation remain
separately scoped. Before 1.0 only the current schema, root format and
`loopex.experimental/4` contract are read; adding `daemon.readiness` updates
that contract in place with its vectors. An unsupported root is refused before
any write under ADR 0072, and no earlier build is claimed to recognize a later
file or root.

**Alternatives rejected.**

- *`LOOPEX_HOME` as the home.* ADR 0049 made it the state root; redefining it
  would change every M7 invocation and put the configuration inside the root
  that ADR 0072's marker must find empty.
- *A second variable for the home.* `--config` already selects any other
  file, and ADR 0049 admits one alias.
- *On-demand start whenever the home's socket is silent.* A command would
  change which process owns the workspace from ambient state, which P5
  forbids.
- *A start lock separate from placement.* The placement lock already makes
  concurrent daemons converge; the loser's 76 is the signal.
- *Readiness in `daemon.status`.* Its result is exact and printed by
  `sessions --status`; a separate method leaves it and its consumers unchanged.
- *A readiness file in the root.* It would write inside the root outside the
  service's lifetime and say nothing true after a crash.
