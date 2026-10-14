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

<a id="technical-0037-auth-separation"></a>
#### Sign-in directory and state-root separation

Concept: [Sign-in directory and state-root separation](0037-host-configuration-and-path-discovery.md#concept-0037-auth-separation).

**Invariant.** Let `A` be the sign-in directory, `<HOME>/.loopex/auth`, which
[ADR 0073](0073-provider-oauth-sign-in-technical.md#technical-depth) defines
and fills, and `G` the Application Default Credentials directory,
`<HOME>/.config/gcloud`, whose `application_default_credentials.json` holds
the refresh token ADR 0073's
[`adc` source](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-adc)
reads. ADR 0073 never consults `CLOUDSDK_CONFIG` or
`GOOGLE_APPLICATION_CREDENTIALS`, so `G` is fixed by `HOME` alone. `A` and `G`
are the *protected credential directories*, each computed from this
invocation's `HOME` whether or not it exists. Let `R` be any state root the
invocation selects, by `--state-root`, `LOOPEX_HOME` or the file's
`paths.state_root`, and any `BACKUP` or `DESTINATION` path a store command
names. After canonicalization, each protected directory and each `R` must be
separate: neither equals, contains, nor is contained by the other. A violation
refuses `auth_root_overlap` before anything is written. Separation is how ADR
0072's backups and restores stay token-free: ADR 0051's complete manifest
keeps every file in the root, and nothing is excluded from it, the ADC file
included. The path comparison is the early refusal; the
[physical walk check](#technical-0037-physical-walk) refuses a mount that
places credential storage inside a root while that root is copied or
verified.

**Owner.** `LoopexCli.Home` (new), the only module that reads `HOME`, owns
`Home.auth_directory/1`, `Home.adc_directory/1`, the choice of which paths each command checks, and
the construction of the *sign-in context*. The comparison itself is one pure
function over filesystem metadata, `LoopexComposition.SignIn.Separation.check/1`
(new, `apps/loopex_composition`), so that the host and the token store run
the same code; the CLI depends inward on it, and composition imports no CLI
module. Core, composition and the daemon application never compute `A` or `G` and
never read `HOME`, configuration or the environment to find a root or a
protected directory. They receive the context from a host that has already
checked it.

**Sign-in context.** The contract between the host and ADR 0073's token store
is one plain map with exactly four members:

```elixir
%{
  home: "/Users/u/.loopex",               # absolute; keys the keyring item
  auth_directory: "/Users/u/.loopex/auth", # A, absolute
  protected_directories: ["/Users/u/.loopex/auth", "/Users/u/.config/gcloud"], # [A, G]
  state_roots: [{"/paths/state_root", "/Users/u/.loopex/state"}]
}
```

- `Home.sign_in_context(selection)` builds it after selection: `home`,
  `auth_directory` and `protected_directories`, exactly `[A, G]`, from
  `HOME`, and `state_roots` holding every state root,
  `BACKUP` and `DESTINATION` the command selected, each with its refusal
  pointer, in selection order. A command that selects no root, such as
  `auth login` without a configuration file, passes `[]`. It then calls
  `Separation.check(context)` and returns the context only on `:ok`, else
  `{:error, {:auth_root_overlap, pointer}}`.
- `Separation.check/1` refuses a context that is not exactly this shape, whose
  paths are not absolute UTF-8 of at most 4,096 bytes, whose
  `protected_directories` is not exactly `[auth_directory, G]` for the
  context's `home`, or that holds more than 16 roots, with
  `{:error, {:auth_root_overlap, "/auth"}}`. For each root in order it applies
  the comparison below to each protected directory, in list order, and the
  root; then it applies the *marked-ancestor rule* to each protected
  directory `P`: an existing directory among `E_P` and its lexical ancestors
  that holds ADR 0072's `loopex-root-format` marker refuses with pointer
  `/auth`, because `P` would lie inside a root some other selection names. It
  reads only metadata of the paths it was given and their ancestors.
- **Lifecycle.** The context is built once per command, after selection and
  before any write, and is never rebuilt from ambient state. The command
  passes it inward as a host option: `auth` to the store calls it makes;
  foreground chat, durable `ask` and the daemon to composition, which hands
  it unchanged to each `SignIn.Route` refresher it starts; the ephemeral
  composition the same way. A refresher keeps the context it received for
  its whole life. `HOME` and the selected roots cannot change inside a
  running process, so the context stays the command's selection.
- **Re-validation.** ADR 0073's store calls `Separation.check/1` on the
  context it was given immediately before every backend write, and the
  refresher, the `adc` refresher included, calls it before every exchange, as
  [ADR 0073](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-decision)
  states. A filesystem changed after startup, for example a new symbolic link
  that moves `A` or `G` into a root, is therefore refused before a token
  reaches it.
  There is no second resolver: the store never selects a root and never reads
  `HOME`.

**Canonical form.** Each path is reduced independently to a pair `(E, S)`,
reading only metadata:

1. Start from the absolute path the resolver produced (`Path.absname`
   against the invocation directory for a flag or argument, ADR 0049's
   file-relative rule for `paths.state_root`).
2. Walk its components from `/`. For each component that exists,
   `:file.read_link_info/1` decides. A symbolic link is replaced by its
   `:file.read_link_all/1` target, resolved against the already-canonical
   parent, and the walk restarts from that point. A `..` after a resolved
   component removes the canonical parent physically, as `realpath(3)` does.
   More than 40 link expansions, an unreadable component or a non-UTF-8
   target refuses `auth_root_overlap`, because separation cannot be shown.
3. The walk stops at the first component that does not exist. `E` is the
   canonical path walked so far: the deepest existing ancestor-or-self, with
   no symbolic link in it. `S` is the list of remaining components with `.`
   removed. A `..` in `S` refuses `auth_root_overlap`: its meaning depends on
   what a missing component later becomes, so separation cannot be shown.
4. The *identity chain* of `E` is the `{major_device, inode}` of `E` and of
   each of its lexical ancestors up to `/`, read with
   `:file.read_file_info/1`. Every member exists and none is a symbolic link,
   so a mount point in the chain contributes the identity of what is mounted
   there. A bind mount of `/srv/data` at `/mnt/alias` gives `/mnt/alias` the
   identity of `/srv/data`.

**Comparison.** `X` lies inside or at `Y` when:

- `S_Y` is empty and the identity of `E_Y` is in the identity chain of `E_X`;
  or
- `S_Y` is not empty, `E_X` and `E_Y` have the same identity, and `S_Y` is a
  prefix of `S_X` under the missing-component rule below.

When `S_Y` is not empty no existing component of `X` below `E_Y` can match
`S_Y`'s first component, because that name does not exist under `E_Y`; so the
second case needs equal identities, not a chain lookup. A protected directory
and `R` overlap when either lies inside or at the other. Whole components are compared, never
string prefixes, so `/x/state` and `/x/stateful` are separate. For example,
with `/srv/data` bind-mounted at `/mnt/alias`, `A = /mnt/alias/.loopex/auth`
and `R = /srv/data/.loopex/auth/state`, neither existing, reduce to
`(/mnt/alias, [.loopex, auth])` and `(/srv/data, [.loopex, auth, state])`; the
two `E`s have one identity and `S_A` is a prefix of `S_R`, so the pair refuses.

**Missing-component rule.** Existing components are compared by identity, so
filesystem name rules never matter for them. Two missing components, at the
same position after identical `E`s, are taken to name the same entry, and the
pair refuses, when any of these holds:

1. they are byte-equal;
2. both are ASCII and equal after ASCII lower-casing;
3. either contains a byte at or above `0x80`.

The rule is the same on both supported hosts and never asks which filesystem
or volume a path is on, because a case-insensitive or normalization-
insensitive volume can be mounted on either. It refuses some separate pairs:
`state` beside a missing `State` on a case-sensitive volume, and any two
missing non-ASCII names at the same position. It admits no pair that a
filesystem equating names by Unicode case folding or Unicode normalization
could treat as one entry: for two ASCII names both equivalences reduce to
ASCII lower-casing, and every name with a non-ASCII byte is refused.

<a id="technical-0037-physical-walk"></a>
**Physical walk check.** The path comparison sees the paths it is given and
their ancestors. A mount that places part of a root's tree over credential
storage, for example `<root>/sub` bind-mounted at `$HOME/.loopex` or at
`$HOME/.config`, shares no identity with `R` or its ancestors, so the path
comparison admits it. Every walk that copies or verifies a root therefore
also compares identities, whatever the mount layout:

- At the start of the walk, `LoopexComposition.SignIn.Separation.identities/1`
  stats each of the context's `protected_directories` with
  `:file.read_file_info/1` and keeps its `{major_device, inode}`. A protected
  directory that does not exist (`:enoent`) is skipped; any other stat
  failure refuses `auth_root_overlap` with pointer `/auth`, because
  separation cannot be shown.
- The walk already stats every entry it lists for ADR 0051's manifest. For
  every directory it encounters, the walked root included, it compares that
  directory's `{major_device, inode}` with the set. A member stops the walk
  before its next read or write and refuses `auth_root_overlap` with the
  walked path's pointer: the root's origin, `/arguments/backup` or
  `/arguments/destination`. The identities reach `Restore.IO` as a
  host-private option of the operation, never in a manifest, plan or
  retained record.
- The walks are [ADR 0072](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-backup)'s:
  `store backup`'s manifest A of the root (step 7), taken before its staging
  directory exists, then its copy and manifests B and C; `store adopt`'s
  manifests A and C (steps 8 and 10); and `store restore`'s manifest of
  `BACKUP/state` (check 1), taken before anything is written, then every
  manifest ADR 0051's transition takes of the backup and of `DESTINATION`,
  including the destination manifest it compares after the copy and before
  its commit. ADR 0072 states how the transition reports that refusal.

A mount that aliases credential storage into a root is therefore refused
before any file is copied from it, and a restore never commits a destination
through which credential storage is reachable. Physical separation holds for
every root that is backed up, adopted or restored; the path comparison stays
as the early refusal before any walk.

**Where it runs.** Every row builds the sign-in context, so every row runs
the whole of `Separation.check/1`, the marked-ancestor rule included. The
check runs after selection and before the first write, lock, socket or
process of the command:

| Command or path | Paths checked | Pointer on refusal |
| --- | --- | --- |
| `run`, `resume`, `skill`, `chat` (foreground), durable `ask`, `cancel`, offline `sessions`, `artifact` | The selected state root, before `Placement.acquire/2` or composition | The state root's origin: `/flags/state-root`, `/env/LOOPEX_HOME` or `/paths/state_root` |
| `loopex daemon`, with or without `--config` (`LoopexCli.Daemon`, before `LoopexDaemon.Command` starts the service) | The selected state root | The same |
| `service start` and every on-demand start (`ServiceStart` `select`) | The selected state root, before `probe` | The same |
| `config set` and `config unset` (candidate validation) and `init` | The candidate's resolved `paths.state_root` | `/paths/state_root` |
| `store adopt`, `store backup`, `store restore` | The selected root; `BACKUP`; `DESTINATION`; then the [physical walk check](#technical-0037-physical-walk) during every manifest and copy of them | The root's origin; `/arguments/backup`; `/arguments/destination` |
| `auth login`, `auth logout` and every other ADR 0073 command that writes `A` | The state root its own selection names, when a file is selected, else no root; the marked-ancestor rule always | The root's origin, or `/auth` for a marked ancestor |
| A process that starts an ADR 0073 refresher (foreground chat, durable and ephemeral `ask`, daemon) | Covered by its row above, which builds the sign-in context. The refresher receives that context at start, writes only `A`, and re-runs `Separation.check/1` on it before every exchange and every write | The failing root's pointer; the refresher exchanges and writes nothing |
| Ephemeral `ask` | Nothing: its root is a fresh temporary directory, never selected | — |

`doctor` reports a violation as `configuration: "auth_root_overlap
<pointer>"` and exits `1`; it writes nothing.

**HOME unusable.** When `HOME` fails `LoopexCli.Home`'s rules, `A` and `G` cannot be
computed and separation cannot be shown. Every row above then refuses
`home_unavailable` before any write, including commands given only
`--config` and `--state-root`. Ephemeral `ask` is the exception. Without
`HOME`, no sign-in directory exists that the invocation could write. The
refusal still applies to roots, because another invocation with `HOME` set
could later create `A` or `G` inside the selected root.

**Statuses.** A CLI command prints `loopex: auth_root_overlap <pointer>` with
the hint `the credential directory <P> and the state root must not contain each
other; select a different state root`, where `<P>` is the protected directory
that overlapped, and exits `1`, as every refusal in this
record does; `loopex auth` exits 76 from its own status table in
[ADR 0073](0073-provider-oauth-sign-in-technical.md#technical-depth). `loopex daemon` exits [ADR 0071](0071-daemon-attached-conversation-technical.md#technical-adr-0071-decision)'s
`111`, `configuration_invalid`, with class `auth_root_overlap` and the
pointer on its diagnostic line. No new daemon status is assigned. The M8 set
is every integer from 65 through 124 except 114, which ADR 0071 retires.

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
within one 1,000 ms read and never calls the helper owner. `Helper.status/1`,
`Helper.classify/2` and `Helper.create_parent/2` are `:infinity` calls to one
serial owner, and a classification slice holds that owner for up to 60,000 ms
before it replies, as does a parent creation up to Core's creation cutoff, so
no readiness answer may wait on it.

*Readiness source.* The helper owner publishes its classification state to a
`:protected` ETS table it creates in `init/1` with `read_concurrency: true`.
The owner is the table's only writer; the table is unnamed, so it is
per-runtime and never global, and its identifier reaches the service in the
handle `Delegation.host/4` returns, so obtaining it calls nothing. The table
holds one row, `{:readiness, sequence, classified, slice}`:

| Field | Value |
| --- | --- |
| `sequence` | A positive integer the owner increments on every write |
| `classified` | The owner's `classified` value after the last completed slice: `:pending` before the first slice ends, `:complete`, or the incomplete value, which gains its reason as `{:incomplete, covered, enumerated, failed, reason}` with `reason` `nil`, `{:closed, session_id, code}` or `{:unavailable, code}`; that value stays composition-private |
| `slice` | `:idle`, or `{:classifying, started_ms}` with the owner's monotonic start |

The owner writes the row in the same callback that changes the state it
describes, before it begins any work the row announces and before it replies
to the call that ends it: `{:classifying, started_ms}` as the first step of
`handle_call({:classify, ...})`, before `classify_root/2`; `classified` and
`:idle` together as the last step, before the reply; the initial row with
`:pending` and `:idle` before `init/1` returns. Parent creation, helper jobs
and status reads do not write it, because they do not change classification.
No other process writes helper truth: the row is a projection the owner
already holds, and the slice task, the service and readiness only read it.

*Mapping.* `Loopex.creation_startup_status(runtime, remaining)` is asked with
the read's remaining budget; not ready is `unavailable`/`runtime_unavailable`.
With no helper owner, ready is `serving`. Otherwise one `:ets.lookup/2` of the
row decides, in this order:

| Row | `state` | Counts and code |
| --- | --- | --- |
| `classified: :complete` | `serving` | `null` |
| `classified` incomplete with `{:closed, session_id, code}` | `closed` | `session_id`, `code`, `recovery` |
| `classified` incomplete with `{:unavailable, code}` and `slice: :idle` | `unavailable` | `code` |
| `slice: {:classifying, _}`, or `classified` `:pending`, or incomplete with reason `nil` | `classifying` | `covered` and `enumerated` from the last completed slice, `"0"` and `"0"` while `:pending` |
| The table is gone (the owner exited) | `unavailable` | `unexpected`; the service is already failing stop as `runtime_lost` |

*Freshness.* The row is exact at the instant of the read: the single writer
updates it at every transition, so readiness reports `classifying` for the
whole of a slice and the counts of the slice before it, never counts it has
not completed. A slice that outlives its own budget is still `classifying`;
`Helper.classify/2` enforces the budget, readiness does not infer one.
Readiness reads no `sequence` across calls; the field lets a test prove that a
later read saw a later write.

While a pass is incomplete without a named session, the service runs
a further 60,000 ms `Helper.classify/2` slice from a linked task one second
after the last one ends, as ADR 0046 requires of a resident host. The schema
addition updates `loopex-experimental-4.json` (method list,
`initialized.supported_methods`, result definition), its vectors, the pinned
digest in `LoopexCli.DaemonClient` and `clients/node/contract-manifest.mjs`,
and `clients/node/daemon-client.mjs`.

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
- **`service status`.** Prints the closed status object below and exits `0`
  for `serving`, `3` for any other state, and `1` when it cannot determine
  one: the file cannot be selected or loaded, or the socket answers
  `daemon.readiness` but not `daemon.status`. `service start` prints the same
  object. A live owner whose socket does not answer is `held`: a service still
  starting or a foreground command; only a starter, which knows it spawned
  one, reports `starting`.
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

#### Service status object

Exactly these eight keys, in this order; no other key is ever printed. The
command reads, in order: the selection (`Home.select`, `ConfigFile.load`,
`ConfigSelection.compose` with no overrides); `Placement.live_owner(root)`;
one `DaemonClient.connect(socket, timeout: 1_000)`; and, on that one
connection, `daemon.readiness` and then `daemon.status`, each bounded at
1,000 ms.

| Key | Type | Source |
| --- | --- | --- |
| `state` | String: `stopped`, `held`, `starting`, `serving`, `classifying`, `closed` or `unavailable` | No live owner: `stopped`. A live owner and no readiness answer: `held`, or `starting` from a starter. A readiness answer: its `state` |
| `pid` | Integer or `null` | The live owner's OS process from `Placement.live_owner(root)`; `null` when `stopped` |
| `socket` | String | `LoopexDaemon.Paths.startup(root, nil).socket_path` from the selection |
| `state_root` | String | The selection's absolute state root |
| `configuration_file` | String | The file this command selected, by `--config` or as the default home |
| `readiness` | Object or `null` | The `daemon.readiness` result verbatim, with exactly its ten members above; `null` when nothing answered. Its own `configuration_file` is the file the service was started with and may differ from the top-level one; its `state` equals the top-level `state` |
| `activations_used` | Integer or `null` | `daemon.status`'s `activations_used`, which under [ADR 0071](0071-daemon-attached-conversation-technical.md#technical-adr-0071-decision) includes helper children and held helper permits; `null` when nothing answered |
| `activation_limit` | Integer or `null` | `daemon.status`'s `activation_limit`, `64`; `null` when nothing answered |

Nesting the readiness result keeps its `state` and `configuration_file` from
overlapping the command's own keys, and no readiness member is renamed or
flattened. `doctor`'s `service` member is this object.

#### Refusals

Command refusals print `loopex: <class> [<pointer>]` and a fixed hint on
standard error and exit `1`: `home_unavailable`, `configuration_not_found`,
`configuration_exists`, `configuration_member_fixed`, `configuration_locked`,
`configuration_sync_unconfirmed`, ADR 0049's existing load and validation
classes, `service_and_daemon`, `config_requires_service`,
`service_not_running`, `provider_credential_absent`,
`service_command_unavailable`, `service_not_ready`, `service_closed`,
`service_not_serving`, `root_held`, `stop_unconfirmed`, `auth_root_overlap`, and a daemon start refusal under its
`LoopexDaemon.ExitStatus` class name.

#### Ownership

| Piece | Module |
| --- | --- |
| `HOME`, file selection, layout paths | `LoopexCli.Home` (new) |
| Sign-in directory, path selection and sign-in context | `LoopexCli.Home` (`auth_directory/1`, `adc_directory/1`, `sign_in_context/1`, new), called by every row of its table |
| Separation comparison | `LoopexComposition.SignIn.Separation.check/1` (new), called by `LoopexCli.Home` and, on the context it was given, by ADR 0073's store and refresher |
| Physical walk check | `LoopexComposition.SignIn.Separation.identities/1` (new) and the identity comparison in `Restore.IO`'s backup-copy, adopt-manifest and manifest walks, given the identities by ADR 0072's `StoreAdmin` as a host-private operation option |
| `init`, `config set`, `config unset`, lock and atomic write | `LoopexCli.ConfigWriter` (new) |
| Optional `--config`, selection line | `LoopexCli.ConfigOptions`, `LoopexCli.ConfigInspection` |
| On-demand machine, spawn, wait | `LoopexCli.ServiceStart` (new) |
| `service`, `paths`, `doctor` | `LoopexCli.Service` (new); dispatch in `LoopexCli` |
| `--service` on live forms | `LoopexCli.Live` |
| `--config`, `--admit-project-resources` | `LoopexCli.Daemon`, `LoopexDaemon.Command` (ADR 0071) |
| `daemon.readiness` and the slice loop | `LoopexDaemon.ServiceReadiness` (new), `LoopexDaemon.Service`, `Request`, `SocketConnection`, `WireRecords`; `LoopexComposition.Delegation.Helper` (the readiness table and its single writer), `LoopexComposition.Delegation` (`host/4` handle carries the table) |
| `service status` object | `LoopexCli.Service` |

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
- **ADRs 0051, 0072 and 0073, applied.** The separation invariant and the
  physical walk check are what keep ADR 0073's tokens and the ADC refresh
  token out of ADR 0072's backups and restores. ADR 0051's complete manifest
  is unchanged and excludes no file; a root that would hold or reach a
  protected credential directory is refused instead. ADR 0051's refusal
  vocabulary is unchanged; ADR 0072 maps the walk's refusal inside the
  transition onto it.

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
| `auth_separation_test.exs` | Unit and real filesystem | For each origin (`--state-root`, `LOOPEX_HOME`, the file's `paths.state_root`): the root equal to `A`, containing it, and contained by it each refuse `auth_root_overlap` with that origin's pointer, before any file, lock, log, socket or process; `/x/state` beside `/x/stateful` and the default `<home>/state` beside `<home>/auth` pass; a root selected under one `HOME` and used under another whose `.loopex/auth` lies inside it refuses; a symbolic-link root resolving to an ancestor of `A`, a symbolic-link `HOME` and a symbolic-link `auth` each refuse; a link loop and 41 chained links refuse; **missing-tail aliases**, on real directories on both hosts: with `data` and a symbolic link `alias` to it, `HOME` under `alias` with `.loopex/auth` absent and a root `data/.loopex/auth/state` absent refuse, as do the reverse containment and an equal pair, while `alias/.loopex/auth` beside an absent `data/.loopex/state` passes; a `..` in a missing suffix refuses; **missing-component rule**: an ASCII case variant (`Auth` against `auth`) and any non-ASCII missing component at the same position refuse on both hosts, and `/x/state` beside `/x/stateful` passes; an existing case variant on a case-insensitive `darwin-arm64` volume refuses through identity; **bind mount**: in `auth_separation_bind_test.exs`, tagged `:bind_mount`, the reviewer's example (`/srv/data` bound at `/mnt/alias`, `A = /mnt/alias/.loopex/auth`, `R = /srv/data/.loopex/auth/state`, neither existing) and the same pair with both existing refuse; **subtree mount**: a separated root `R` whose `<R>/sub` is bind-mounted at the protected directory's parent (`<HOME>/.loopex`, and in a second case `<HOME>/.config`) with a credential-shaped canary token file in the protected directory passes the path comparison, and `store backup` then refuses `auth_root_overlap` with the root's pointer at manifest A, before its staging directory exists, so no copied token file is written anywhere; `store adopt` of that root refuses at manifest A with the canary unchanged; and a restore whose `DESTINATION` gains such a mount during ADR 0051's copy, at a private pause hook, is never committed and prints `auth_root_overlap /arguments/destination`; it runs on `linux-x86_64` inside `unshare --user --map-root-user --mount` in the release check, and when the host refuses that namespace the lane reports the evidence unavailable, never a pass; `darwin-arm64` has no unprivileged bind mount, so there the identity-chain step is proved by the symbolic-link and case-variant cases above; the `Separation.check/1` context grammar (shape, relative or non-UTF-8 path, 17 roots) refuses; an absent or relative `HOME` refuses `home_unavailable` on every row, and an ephemeral `ask` still runs; `config set /paths/state_root` to an overlapping path leaves the earlier bytes; `auth login` refuses when an ancestor of `A` holds a `loopex-root-format` marker; `store adopt`, `store backup` and `store restore` refuse an overlapping root, `BACKUP` and `DESTINATION`; a backup of a separated root holds every file of the root and no file of `A`; **ADC directory**, on real directories with a temporary `HOME` and a credential-shaped canary `application_default_credentials.json` (random bytes in the file's grammar, never a real credential) under `<HOME>/.config/gcloud`: for each origin, a state root equal to `<HOME>/.config/gcloud`, containing it (`<HOME>/.config`) and contained by it (`<HOME>/.config/gcloud/state`) refuses `auth_root_overlap` with that origin's pointer, both when `gcloud` exists and when it is absent, before any file, lock, log, socket or process; `store backup` of such a root refuses before `BACKUP` or its staging directory exists, so no copy of the canary is written; `store restore` with `DESTINATION` an empty `<HOME>/.config/gcloud`, or a path under it, refuses before any write and leaves the directory as found, so no restored file lands in or overwrites it; `store adopt` of such a root refuses with the canary's bytes unchanged; the complete manifest of a separated root is unchanged and holds no exclusion; **physical walk check** at the `Restore.IO` boundary, on real directories on both hosts, with the path comparison deliberately not run: the backup copy, adopt manifest and manifest operations given a root that contains a protected directory, or is one, refuse `auth_root_overlap` with the walked path's pointer at the first such directory and write nothing after it, the backup copy creating no copied canary; a protected directory that does not exist is skipped and the walk proceeds |
| `daemon_configuration_test.exs` (ADR 0071, extended) | Real daemon | `loopex daemon`, with and without `--config`, exits 111 with class `auth_root_overlap` and each origin's pointer, leaving no lock, log entry or socket |
| `apps/loopex_daemon/test/readiness_slice_test.exs` | Socket, real helper owner | A gated store adapter holds a classification slice open: `daemon.readiness` asked concurrently and repeatedly answers within 1,000 ms each (measured), as `classifying` with the previous slice's counts, `"0"` and `"0"` before the first completes; the row's `sequence` advances at slice start and end; a parent creation held in the owner does not delay readiness; releasing the gate gives `serving`; killing the owner gives `unavailable` with `unexpected`; no readiness path calls the owner |
| `service_status_test.exs` | Real daemon | The status object has exactly its eight keys in order for `stopped`, `held`, `classifying` and `serving`; `readiness` is the verbatim result or `null`; `activations_used` and `activation_limit` equal `daemon.status`'s and include a helper child after one runs; a service started from another file keeps its own `readiness.configuration_file`; exit statuses 0, 3 and 1, including a socket that answers readiness and not status |
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
