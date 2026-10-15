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

<a id="technical-0037-ask"></a>
**`ask` (D54).** `loopex ask`, durable and ephemeral, gains `--config FILE`
(`AskOptions`) and selects a file by this table, except that with neither
present it selects none and runs as delivered rather than refusing
`configuration_not_found`. `Ask.prepare/2` (`ask.ex` :65-80) selects and
loads the file after its argument, workspace and prompt checks, with ADR
0049's unchanged reader validating the whole file, and keeps only its
`providers`. Those apply to the providers they name; every other provider
keeps `ask`'s delivered environment route, durable `ask`'s
`LOOPEX_PROVIDER_API_KEY` single-credential binding and ephemeral `ask`'s
per-provider environment and local reference routes (D57). No other
member is used: `--state-root` alone still makes `ask` durable and names
its root, the file's `paths.state_root` is neither
opened nor checked, and an ephemeral `ask`'s root stays a fresh temporary
directory. Its sign-in context therefore holds durable `ask`'s root, or no
root for ephemeral `ask`, whose check is then the marked-ancestor rule
alone. Without a usable `HOME`, an ephemeral `ask` discovers no file and has
no sign-in context; with `--config` it still reads the file, and an `oauth`
binding there of the provider its model or maintenance model uses refuses
`provider_sign_in_required` (ADR 0073); any other `oauth` binding is
dropped (D63). A file that
cannot be selected, read or validated ends `ask` with status 1 before any
session, reported as `loopex.ask/1`'s fixed `command_failed`, as are
`home_unavailable` and `auth_root_overlap`, which its closed diagnostic
list (`ask_result.ex` :19-55) does not hold; a disabled route reports
`sign_in_unavailable` (D52). ADR 0073 states how each `ask` host merges the
file's bindings with its environment routes.

State-root precedence is ADR 0049's, unchanged: `--state-root` flag >
`LOOPEX_HOME` > the file's `paths.state_root` (relative to the file's
directory). No home-derived default is added to the resolver: `init` writes
`"state_root": "state"`, so the installed root is `<home>/state` through the
file. The service socket is always `LoopexDaemon.Paths.startup(root,
nil).socket_path`, that is `<root>/daemon/daemon.sock` under the root's
[physical path](#technical-0037-physical-root); at the default home it fits
macOS's 103-byte limit whenever the physical path of `HOME` is at most 70
bytes, and a longer path refuses with the delivered `socket_path_too_long`.

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
  log/                      0700, created by `spawn` or by the daemon, whichever is first
    service.log             0600, the service's stdout and stderr, appended
    service.log.1           the previous log, kept once
    start-<16 hex>.exit     one start's exit status, read and removed by its starter;
                            stale ones pruned by the next spawn and by service stop
    service-<pid>.id        a service's process incarnation, written by that service
                            before it takes the placement lock, marked when it
                            begins to stop and removed once it releases the lock;
                            stale ones pruned by spawn and service stop
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
`paths.state_root`, any `BACKUP` or `DESTINATION` path a store command
names, and the source root an available restore reads, as its backup's
capture names it. After canonicalization, each protected directory and each
`R` must be separate: neither equals, contains, nor is contained by the
other. A violation refuses `auth_root_overlap` before anything is written.
Separation is how ADR 0072's backups and restores stay token-free: ADR
0051's complete manifest keeps every file in the root, and nothing is
excluded from it, the ADC file included. By the maintainer's decision D27 of
2026-10-14 the comparison of these paths, with the marked-ancestor rule
below, is the whole rule: no mount table is
read on either host and no walk examines mounts or compares what it meets
with the protected directories. The
[operator limit](#technical-0037-operator-limit) states what stays outside.

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
is one plain map with exactly five members:

```elixir
%{
  home: "/Users/u/.loopex",               # absolute; keys the keyring item
  auth_directory: "/Users/u/.loopex/auth", # A, absolute
  protected_directories: ["/Users/u/.loopex/auth", "/Users/u/.config/gcloud"], # [A, G]
  state_roots: [{"/paths/state_root", "/Users/u/.loopex/state"}],
  secret_service_bus: "unix:path=/run/user/1000/bus" # or nil
}
```

- `Home.sign_in_context(selection)` builds it after selection: `home`,
  `auth_directory` and `protected_directories`, exactly `[A, G]`, from
  `HOME`, and `state_roots` holding every state root,
  `BACKUP` and `DESTINATION` the command selected, each with its refusal
  pointer, in selection order. A command that selects no root, such as
  `auth login` without a configuration file, passes `[]`. It then calls
  `Separation.check(context)` and returns the context only on `:ok`, else
  `{:error, {:auth_root_overlap, pointer}}`. The one path added later is a
  restore's available source, which only the backup's capture names:
  `StoreAdmin` appends `{"/capture/source_state_root", path}` to
  `state_roots` and runs `Separation.check/1` on that context, as
  [where it runs](#technical-0037-where-it-runs) states.
- `secret_service_bus` is the value of `DBUS_SESSION_BUS_ADDRESS`, read by
  `LoopexCli.Home` in the same single read as `HOME`: a valid UTF-8 string
  of 1 to 4,096 bytes, or `nil` when the variable is unset or empty. A value
  that is longer or not UTF-8 is `nil`, never a refusal, because the bus
  serves only ADR 0073's Secret Service backend, which then reports itself
  unavailable. It is the only member read from an environment variable
  other than `HOME`, and it exists so that ADR 0073's backend, which runs in
  composition and never reads the environment, can pass the address to
  `/usr/bin/secret-tool` explicitly. It is never a path, never compared and
  never checked against the filesystem.
- `Separation.check/1` refuses a context that is not exactly this shape, whose
  `secret_service_bus` is neither `nil` nor a UTF-8 string of 1 to 4,096
  bytes, whose other paths are not absolute UTF-8 of at most 4,096 bytes, whose
  `protected_directories` is not exactly `[auth_directory, G]` for the
  context's `home`, or that holds more than 16 roots, with
  `{:error, {:auth_root_overlap, "/auth"}}`. For each root in order it applies
  the comparison below to each protected directory, in list order, and the
  root; then it applies the *marked-ancestor rule* to each protected
  directory `P`: an existing directory among `E_P` and its lexical ancestors
  that holds ADR 0072's `loopex-root-format` marker refuses with pointer
  `/auth`, because `P` would lie inside a root some other selection names. It
  reads only metadata of the paths it was given and their ancestors, and no
  mount table. Beyond that type check it ignores `secret_service_bus`.
- **Lifecycle.** The context is built once per command, after selection and
  before any write, and is never rebuilt from ambient state. The command
  passes it inward as a host option: `auth` to the store calls it makes;
  foreground chat and durable and ephemeral `ask` to
  `LoopexComposition.CredentialHost.open/4`, and the daemon to its service,
  which hand it unchanged to each `SignIn.Route` refresher they start. A
  refresher keeps the context it received for
  its whole life. `HOME` and the selected roots cannot change inside a
  running process, so the context stays the command's selection; the bus
  address is the starting command's, which the detached service inherits
  as it inherits the rest of that environment.
- **Re-validation.** ADR 0073's store calls `Separation.check/1` on the
  context it was given immediately before every backend write, and the
  refresher, the `adc` refresher included, calls it before every exchange, as
  [ADR 0073](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-decision)
  states. A path changed after startup, for example a new symbolic link
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
   `:file.read_file_info/1`. Every member exists and none is a symbolic link.
   The identity lets two spellings of one existing directory, such as a case
   variant on a case-insensitive volume, compare as one directory. It is not
   mount detection: no mount table is read, and an alias a mount creates is
   outside the guarantee under D27 whether or not its identity happens to
   match.

<a id="technical-0037-physical-root"></a>
**Physical root.** `LoopexCli.Home` hands every root opener, the `store`
commands and `loopex daemon` without `--config` included, the selected
root's physical path, `E` joined with `S`, never the spelling it was given,
and, to `store adopt` only, also the selection's `Path.expand/1` spelling,
which adopt uses solely to classify ledger bindings (ADR 0072 adopt steps 1
and 6), because the Local executor ledger binds
`Path.expand/1` of the path it receives (`ledger.ex` :159-162) and ADR 0072's
backup, adopt and restore derive physical placements; a root selected through
a symbolic-link ancestor therefore opens, backs up and restores as its
physical path. `loopex daemon`, with or without `--config`, canonicalizes an explicit
`--socket` the same way, to `E` joined with `S` (D53 and its accepted note), so a socket spelled
through the same symbolic link as the root still lies inside the physical
root's `daemon` directory, which `Paths.startup/2` checks lexically
(`paths.ex` :62-75). A socket that cannot be canonicalized (more than 40
link expansions, an unreadable component, a non-UTF-8 target or a `..` in
its missing suffix) refuses the delivered `invalid_socket_path` (89), not
`auth_root_overlap`. `LoopexDaemon.Paths.startup/2` (`paths.ex` :37-49) then
measures the socket under that physical path, so a root that fit the socket
limit through a shorter alias under M7 (on macOS `/tmp` is `/private/tmp`,
8 bytes longer) can now refuse `socket_path_too_long` (87).

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
on a case-insensitive volume where `/Users/u/.loopex` exists and holds no
`auth`, `A = /Users/u/.loopex/auth` and `R = /Users/u/.LOOPEX/auth/state`
reduce to `(/Users/u/.loopex, [auth])` and `(/Users/u/.LOOPEX, [auth,
state])`; the two `E`s are one directory with one identity and `S_A` is a
prefix of `S_R`, so the pair refuses.

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

<a id="technical-0037-operator-limit"></a>
**Mechanism boundary and operator limit (D27).** The comparison sees the
paths it is given and their ancestors, resolved through symbolic links, and
nothing else. The maintainer decided on 2026-10-14 that separation is this
path rule only, superseding D19, D21 and every rule this record stated for
mounts and walked directories: no `/proc/self/mountinfo` or macOS mount
list is read, no walk compares a directory it meets with a protected
directory's identity, and no mount at, above or inside a walked root is
examined. What the rule guarantees is exactly this: no state root, `BACKUP`,
`DESTINATION` or available restore source that Loopex selects or walks is,
contains or lies inside `A` or `G`, after symbolic links are resolved and
under the missing-component rule. Credential storage made reachable inside
such a path by a mount of any kind (bind, overlay, FUSE, network or virtual
filesystem, or a mount inside the walked tree) is not detected and is
outside the guarantee; so is a credential file the operator copies into a
root, which is ordinary root content. The check runs when the command
starts; a path that another process changes while the command runs, for
example an ancestor replaced by a symbolic link, is concurrent mutation of
the operator's paths and outside the guarantee in the same way. The
operator-facing statement of that limit is: do not mount credential storage
into or over a Loopex state root, backup or restore destination, and do not
change those paths while a store command runs.

Inside a walked tree the delivered walk refuses links without any separation
input. ADR 0051's manifest walk, `Restore.IO`'s `manifest_entry/3`
(`apps/loopex_composition/lib/loopex_composition/restore/io.ex` :2841-2911),
reads each entry with `:prim_file.read_link_info/1`, so a symbolic link is
never followed: its type falls to `unsupported_entry` (:2908-2909). A regular
file whose link count is not 1 refuses (:2870-2871), so a credential file
hard-linked into a root is refused while its other link remains; once that
link is gone nothing distinguishes it from any other file the operator
placed there. ADR 0072's backup copy refuses the same entries.

<a id="technical-0037-where-it-runs"></a>
**Where it runs.** Every row builds the sign-in context, ephemeral `ask`
only with a usable `HOME`, and runs the whole of `Separation.check/1` on
it, the marked-ancestor rule included. The
check runs after selection and before the first write, lock, socket or
process of the command:

| Command or path | Paths checked | Pointer on refusal |
| --- | --- | --- |
| `run`, `resume`, `skill`, `chat` (foreground), durable `ask`, `cancel`, offline `sessions`, `artifact` | The selected state root, before `Placement.acquire/2` or composition | The state root's origin: `/flags/state-root`, `/env/LOOPEX_HOME` or `/paths/state_root` |
| `loopex daemon`, with or without `--config` (`LoopexCli.Daemon`; without `--config` after the state root input is read and before `paths/2`, `daemon.ex` :81-82, and in every case before `LoopexDaemon.Sentinel.run/2` starts the service, :104) | The selected state root | The same |
| `service start` and every on-demand start (`ServiceStart` `select`) | The selected state root, before `probe` | The same |
| `config set` and `config unset` (candidate validation) and `init` | The candidate's resolved `paths.state_root` | `/paths/state_root` |
| `store adopt`, `store backup`, `store restore` | `store adopt` and `store backup`: the selected root, and `BACKUP`; `store restore`, which selects no configuration: exactly `BACKUP` and `DESTINATION`. Each in the context `LoopexCli.Home` builds when the command starts, before the first read of any of them; `--resume` and `--abandon` then require those paths to equal the retained plan's (ADR 0072). Backup's staging directory is a new, empty child of `BACKUP`'s parent and holds no protected directory; it could lie inside one only if `BACKUP` did, which this check refuses. For `store restore --source available`, and for a `--resume` or `--abandon` whose retained plan has `source_status` `available`, `StoreAdmin.restore/3` appends the source the capture names and calls `Separation.check/1` again immediately after its check 1 decodes `BACKUP/capture` and, on `--resume` or `--abandon`, the retained plan, before it reads `BACKUP/manifest`, walks `BACKUP/state` or reads any path of the source. A lost source is required absent and is never walked or written, so it is not checked | The root's origin; `/arguments/backup`; `/arguments/destination`; `/capture/source_state_root` |
| `auth login`, `auth logout` and every other ADR 0073 command that writes `A` | The state root its own selection names, when a file is selected, else no root; the marked-ancestor rule always | The root's origin, or `/auth` for a marked ancestor |
| A process that starts an ADR 0073 refresher (foreground chat, durable and ephemeral `ask`, daemon) | Covered by its row above, which builds the sign-in context. The refresher receives that context at start, writes only `A`, and re-runs `Separation.check/1` on it before every exchange and every write | The failing root's pointer; the refresher exchanges and writes nothing |
| Ephemeral `ask` | No root; with a usable `HOME` it builds a context with no root, so only the marked-ancestor rule runs. Its root is a fresh temporary directory, never selected, and a selected file's `paths.state_root` is not used ([`ask`](#technical-0037-ask)) | `/auth` |

`doctor` reports a violation as `configuration: "auth_root_overlap
<pointer>"` and exits `1`; it writes nothing.

**HOME unusable.** When `HOME` fails `LoopexCli.Home`'s rules, `A` and `G` cannot be
computed and separation cannot be shown. Every row above then refuses
`home_unavailable` before any write, including commands given only
`--config` and `--state-root`; `loopex daemon` exits 111 with subclass
`home_unavailable`. Ephemeral `ask` is the exception. Without
`HOME`, no sign-in directory exists that the invocation could write. The
refusal still applies to roots, because another invocation with `HOME` set
could later create `A` or `G` inside the selected root.

**Statuses.** A CLI command prints `loopex: auth_root_overlap <pointer>` with
the hint `the credential directory <P> and the state root must not contain each
other; select a different state root`, where `<P>` is the protected directory
that overlapped, and exits `1`, as every refusal in this
record does; `ask` reports it as `command_failed` ([`ask`](#technical-0037-ask)); `loopex auth` exits 76 from its own status table in
[ADR 0073](0073-provider-oauth-sign-in-technical.md#technical-depth). `loopex daemon` exits [ADR 0071](0071-daemon-attached-conversation-technical.md#technical-adr-0071-decision)'s
`111`, `configuration_invalid`, with the diagnostic line `loopex daemon
refused to start: configuration_invalid auth_root_overlap <pointer>` or
`… configuration_invalid home_unavailable`, ADR 0071's one form for every
111. Neither
refusal assigns a new daemon status; the record's one daemon status is 125, `service_record_write_failed`
([service record](#technical-0037-service-record)). The M8 set is every
integer from 65 through 125 except 114, which ADR 0071 retires.

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
loopex ask [--config FILE] [delivered ask options] [PROMPT]   providers only (D54, D57)

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
`ConfigInspection.validate_document/2` (new), which takes the candidate
document and its path instead of argv and runs `ConfigSchema.validate/1`,
`ConfigFile.resolve_document/2` (new: the path resolution `ConfigFile.load/2`
runs after decoding, today private) and the selection, instruction and
genesis checks `prepare/3` runs after its load, with no overrides;
`ConfigFile.load/2` and `prepare/3` call the same two functions; encode it with keys in byte order, two-space
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
`configuration_locked`, naming its PID; a lock the primitive cannot
attribute or read refuses its class, `placement_unverifiable` or
`placement_lock_failed`, before any read of the file. The lock is released
after the directory sync. Its probe uses `Placement.process_incarnation/1`,
which excludes only `LOOPEX_PROVIDER_API_KEY`, because the lock is taken
before the file is read; a file-bound key in the writer's environment
therefore reaches the `/bin/ps` child, a stated residual.

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
| `select` | `Home.select`, `ConfigFile.load`, `ConfigSelection.compose` with no overrides; derive root and socket | `probe`; a load or selection refusal ends the command with its class and pointer, among them ADR 0073's `sign_in_unavailable` for a disabled sign-in route (D52) |
| `probe` | `DaemonClient.connect(socket, timeout: 1_000)` | answers: `readiness`; else `Placement.live_owner(root)`: `:none`: `precheck`; an error: refuse its class, `placement_unverifiable` or `placement_lock_failed`, at once; a live holder, classified as below: a service: `wait` without spawning (that service is still starting or is stopping, so this command waits for it); not a service: refuse `root_held` at once with its PID, because no wait is known to end |
| `precheck` | For each `providers.*.credential.env`, test presence and nonemptiness of the variable without retaining, printing, hashing or comparing the value; for each `providers.*.credential.oauth` route, read only ADR 0073's non-secret sign-in metadata and its [generation floor](0073-provider-oauth-sign-in-technical.md#technical-adr-0073-generation-floor). The precheck sees only those two files; an inconsistent pair, an unavailable or unsafe store, an `adc` file failure and a startup refresh answered `invalid_grant` (D51) are found by the spawned daemon, and the starter refuses with the class its exit status maps to (ADR 0073) | all present: `spawn`; an absent reference: refuse `provider_credential_absent` naming the first absent pointer (for example `/providers/anthropic/credential/env`); an `oauth` route whose metadata is absent, not `signed_in`, or at a generation at or below the floor's (a logout cut after its floor write): refuse `provider_sign_in_required` naming the route (D22; `loopex daemon` itself exits 120 for it). Either refusal creates no process, lock, log or socket |
| `spawn` | Create `log/` (`0700`) when absent, prune stale exit and service-record files, rotate the log, then start the detached service as below | `wait` |
| `wait` | Every 250 ms until the deadline: connect; else, for a command that spawned, read this start's `log/start-<16 hex>.exit`; then, for a command whose own service has exited 76 and for a command that entered from `probe`, read `Placement.live_owner(root)` and classify the holder | answers: `readiness`; a `live_owner` error: refuse its class at once; an own exit status other than 76: refuse with its `LoopexDaemon.ExitStatus` class, or, for `0` (the service stopped, for example by a concurrent `service stop`), `service_stopped`, and for any status without a class (`1`, or `128`+n after a signal), `service_exited` naming the number and the log; own service still running (no exit status yet): stay in `wait`, classifying nothing, because this command's own start is still in progress; a service holder: stay in `wait`; a holder that is not a service: refuse `root_held` at once with its PID; no live holder: the holder this command waited for has exited, so return to `probe` under the same deadline; deadline: refuse `service_not_ready`, naming the live holder's PID and its state, `starting` or `stopping`, or `starting` when no holder is live |
| `readiness` | `daemon.readiness` | `serving`: done; `closed`: refuse `service_closed` with the session, its code and `loopex store restore`, as ADR 0071's attached conversation does over `--daemon`; `classifying` or `unavailable`: poll every 1,000 ms until the same deadline, then refuse `service_not_serving` with the last answer; a `daemon_stopping` refusal (the admission relay refuses every permit request after a stop's transport cut, which follows its stopping mark, `admission_relay.ex` :21-23) is no answer: classify the holder as `probe` does |

The 75,000 ms bound is the delivered startup gate (`@owner_start_gate_ms`
5,000) plus one ADR 0046 classification slice (60,000), the startup arbiter's
readiness write (`@output_deadline_ms` 5,000) and 5,000 for VM boot. It
excludes a sign-in route's synchronous refresh at startup (ADR 0073's lock
wait of up to 10,000 ms, an exchange of up to 30,000 ms and a model
listing), the catalog capture and the permit bind, so a start that needs a
refresh can outlive it. The deadline is fixed once per command, its own
start plus 75,000 ms, and every return to `probe` keeps it. A refused start
leaves any spawned service running; the refusal tells the operator to read
`loopex service status`.

<a id="technical-0037-service-record"></a>
**Service record.** `loopex daemon` started with `--config` and no
selection or socket flag, exactly as `spawn` runs it with or without
`--admit-project-resources`, writes `log/service-<pid>.id` in the selected
file's directory, creating `log/` (`0700`) when absent: `<pid>` is its own
`System.pid()` in decimal and the content, mode `0600`, is its
`Placement.process_incarnation/1` answer followed by one LF, the same
incarnation its placement lock record will carry, then a second line with
the socket path it will listen on and one LF. It writes the content to
`service-<pid>.id.tmp` and renames it over the record's name, replacing any
file there, which can only be a dead process's record whose PID was reused.
`LoopexCli.Daemon` writes it
after reference presence and the project-resource decision, immediately
before `LoopexDaemon.Sentinel.run/2` starts the service, so the record is
complete before the process can reach `Placement.acquire/2`.
`LoopexDaemon.Service`, given the record's path as the start option below,
removes it whenever `release_placement/1` answers `:ok` (`service.ex`
:1743-1765), on an orderly stop and after a startup failure, including its
clause for a lock never taken (`placement` `nil`, :1743): exit 76, whose
`acquire_placement/1` stops with `placement` still `nil` (:464-466), and
every earlier startup failure (`finish_startup_failure/2`, :889). The record
therefore exists for as long as the lock it describes. A daemon that exits
still holding the lock, by a fail-stop (`fail_stop/2`, :1355-1396, never
releases it) or a failed release, leaves its record, which classifies it as
a service until its VM exits; such a record then matches no live holder and
is pruned. A
daemon that cannot write it, including one whose
own `Placement.process_incarnation/1` read fails, removes its temporary
file, writes its diagnostic line naming the class and exits 125, `service_record_write_failed`
(D31), before `Sentinel.run/2`: it never reaches `Placement.acquire/2`, so
it holds no lock, socket or session, and every daemon that holds the lock
under this form has its record. Its starter reads 125 from its own exit
file and refuses `service_record_write_failed`.

*Stopping mark (D44).* `LoopexCli.Daemon` passes the record's path and its
two lines to the service as one plain start option. When an orderly stop
begins, before the transport cut (`orderly_stop/1`, `service.ex` :903), and
when a signal stops the service during startup (`finish_startup_failure/2`'s
`:operator_stop` clause, :867), `LoopexDaemon.Service` rewrites the record by
the same temporary file and rename with a third line, `stopping` and one
LF. A reader therefore sees two lines or three, never a partial record. The
rewrite runs in an unlinked writer process that the service awaits for at
most 1,000 ms and then kills, awaiting its exit, so a mark that cannot be
written, or whose write hangs, delays the stop by at most that and no rename
starts after the wait. A rename already in progress, a dirty-I/O call that
the kill does not interrupt, can still complete after the record's removal,
leaving a three-line record that matches no live holder and is pruned, a
stated residual. The service is then reported `starting`
until it exits, and a second `service stop` refuses it `root_held` as
before D44. A fail-stop writes no mark (D53): `fail_stop/2` kills the
listener at once (`service.ex` :1370) and the VM can run for up to
the sentinel's 35,000 ms watchdog (`sentinel.ex` :168) before it exits; for
that time the service is reported `starting`, a starter waits for it and
`service stop` refuses it `root_held`. This is a stated residual.

**Holder classification.** For a live `Placement.live_owner(root)` answer
`P`, the holder is a *service* when `log/service-<P>.id` is a regular file
whose first line equals `Placement.process_incarnation(P)`'s answer and
whose second line names this command's own socket, each followed by one
LF, with nothing after them or exactly the stopping mark's third line. A
service whose record carries the mark is *stopping*; any other service is
*starting* while its socket does not answer. The two sockets are compared in the [canonical form](#technical-0037-auth-separation)
the separation rule uses, equal `E` identity and equal `S`, so two
spellings of one root match. Any other holder is *not a service*: a `chat`,
`run` or M7-form `loopex daemon` writes no record, a service started from a
file in another directory wrote its record there, and a record left by an
earlier process that had the same PID carries that process's incarnation.
A `Placement.process_incarnation(P)` read answering `process_absent` means
the holder has exited: `probe` probes again, `wait` polls again and `service
status` reports `stopped`; any other failed read refuses
`placement_unverifiable` at once, and a `Placement.live_owner(root)` error,
`placement_unverifiable` (an unattributable lock or a `ps` that does not
answer) or `placement_lock_failed` (an unreadable lock), refuses its class
at once, as the delivered `cancel` does. Before refusing a holder that is
not a service the command reads `Placement.live_owner(root)` again; when it
no longer answers `P`, `probe` probes again and `wait` classifies afresh at
its next poll, so a holder that handed over between the two reads is never
reported. The decision reads
only the live holder's own record, so no command's waiting depends on
another starter's files or on whether that starter is still alive.

**Probe exclusions.** Where this record writes
`Placement.process_incarnation/1` or `Placement.live_owner(root)` for the
record writer in `LoopexCli.Daemon` or for `ServiceStart`, `service
status`, `service stop`, the prune and `doctor`, whose root report calls
ADR 0072's `RootFormat.report/2` with that probe, it means the forms that take the
exclusions, `Placement.process_incarnation(pid, "/bin/ps", excluded)` and
`Placement.live_owner(root, probe)` with that probe, `excluded` being the
set the daemon's own probe uses, `ProviderBindings.validate/1`'s
`excluded_env_names` over the selection's provider bindings (`service.ex`
:400-404, :444-447). The one-argument forms exclude only
`LOOPEX_PROVIDER_API_KEY` (`placement.ex` :118-120, :515-516), so their `ps`
child would inherit a file-bound key.

**Lock publication.** `Placement.live_owner/1` reads the lock without the
acquisition guard, and the delivered `create_owner/2`
(`apps/loopex_composition/lib/loopex_composition/placement.ex` :207-230)
opens the lock exclusively, then writes and closes it, so a read in between
finds an empty record and answers `placement_unverifiable`
(`unattributable_owner_record`, :450-461), which a starter would refuse.
M8's extracted lock primitive therefore writes and closes the whole record
under its owner handle's name first and then publishes it with `File.ln/2`
to the lock's name, which fails with `:eexist` wherever the exclusive open
did; a reader finds no lock or a complete record. A handle left by a kill
before the link is removed by the delivered `cleanup_owner_handles/1`
(:248-261) at the next acquisition.

Two or more commands that spawn, because each probed before any service
took the lock, converge through status 76: a loser's service exits 76 only
because another process holds the lock, and the loser then classifies that
holder. The winning service wrote its record before taking the lock, since
a service that cannot write one exits 125 without taking it, so every loser
started from the same file's directory waits for its socket; a foreground
command that took the lock between the probes and the spawns is classified
as not a service by each loser independently, and each refuses `root_held` at once with its PID, however
many losers there are. A third command that probes after the winner took
the lock finds a service holder and waits for the same service. A
starter killed at any step leaves no file another command reads: its
service, if spawned, is a real service that others wait for, and its exit
file is pruned. A service that takes the lock and exits before serving
leaves no live holder; its own starter refuses with its exit class, and a
command that was waiting for it returns to `probe`, which starts this
command's own service within its remaining deadline and reports that
service's outcome. A command whose own service has not exited and finds no
live holder keeps waiting, since that service has yet to take the lock.

**Exit-file pruning.** Each start writes one `log/start-<16 hex>.exit` (and
transiently its `.tmp`), and its starter removes it once read; a starter that
was killed or that refused at its deadline leaves it. A service that exits
without removing its record, as above or when killed, leaves
`log/service-<pid>.id`, or its `.tmp`. The `spawn` step and
`service stop`, after the owner is gone, prune: they read
`Placement.live_owner(root)` once, list `log/` once, stop after 1,024
entries, and remove each entry whose `File.lstat/1` reports a regular file,
whose modification time is more than 300,000 ms old, and whose name is either
`start-` followed by 16 lowercase hexadecimal characters and `.exit` or
`.exit.tmp`, or `service-` followed by a decimal PID of at most 10 digits
without a leading zero and `.id.tmp`, or the same and `.id` when its
first 8,192 bytes read as two or three lines whose second names this
command's socket in the canonical form above, other than the record of the
PID that read answered. When that read answers an error no holder is known,
so the prune removes exit files and `.id.tmp` files only, never a record. A record naming another socket belongs to another root's
service and is left to that root's commands. 300,000 ms is four times the longest any starter waits, so no live
starter's exit file is removed. A service writes its record during startup,
moments before it takes the lock or exits 76, so a record that old belongs to
the live holder, which is kept, or to a process that has exited. `:enoent` is
tolerated; any other removal error is ignored and the file is left for a
later prune. Other names in `log/` are never touched.

**Detached spawn.** The starter runs `/bin/sh` with one asynchronous list:

```text
/usr/bin/nohup /bin/sh -c 'c=$0 f=$1 l=$2 e=$3; shift 3
  trap "" TSTP TTIN TTOU; unset LOOPEX_ESCRIPT
  "$c" daemon --config "$f" "$@" </dev/null >>"$l" 2>&1
  printf "%s\n" "$?" >"$e.tmp" && mv "$e.tmp" "$e"' \
  COMMAND FILE LOG EXIT [--admit-project-resources DIGEST] </dev/null >/dev/null 2>&1 &
```

`COMMAND` is resolved from the location of the running escript, never from
the environment, exactly as ADR 0038's `LoopexCli.ProviderLaunch.options/0`
resolves the release root: `ServiceStart.command/1` takes the script path,
which the running command passes as `Path.expand(:escript.script_name())`,
as ADR 0038's `options/2` takes it, so a test can call it with any path.
With that `script`: when `MANIFEST` is a regular file in the release root, `script` with two
directory levels removed (the installed `libexec/loopex`), `COMMAND` is
`bin/loopex` under that root, the same installed-mode test ADR 0038's
launcher applies; otherwise, in a checkout, it is the launcher beside the
escript, `Path.join(Path.dirname(script), "bin/loopex")`. The selected path
not being an executable regular file refuses `service_command_unavailable`;
no fallback path is tried. The service therefore starts with
`SIGHUP` ignored by `nohup` and `SIGINT` and `SIGQUIT` ignored as an
asynchronous list. Because those three were ignored on entry, the launcher's
own traps for them cannot be installed (POSIX). Whether or not the path
that spawns `/bin/sh` starts a new session, the script ignores `SIGTSTP`,
`SIGTTIN` and `SIGTTOU`, which the service inherits, so a suspend typed at
the starter's terminal does not stop it. It
unsets `LOOPEX_ESCRIPT`, which the launcher prefers over the escript beside
it (`apps/loopex_cli/bin/loopex` :37-38), so the service runs the build
`COMMAND` names. Standard input is `/dev/null`, so
`ProjectResources.operator_present?/0` is false and the delivered decision
path leaves project resources unadmitted without asking. The environment is
the starter's own less `LOOPEX_ESCRIPT`; nothing else supplies credentials. Before spawning, a log
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
serial owner, and a classification slice holds that owner for its 60,000 ms
budget or longer before it replies, as does a parent creation up to Core's creation cutoff, so
no readiness answer may wait on it.

*Readiness source.* The helper owner publishes its classification state to a
`:protected` ETS table it creates in `init/1` with `read_concurrency: true`.
The owner is the table's only writer; the table is unnamed, so it is
per-runtime and never global, and its identifier reaches the service as a
new `readiness` member of the handle map the delivered `Delegation.open/4`,
and so `Delegation.host/4`, returns, so obtaining it calls nothing. The table
holds one row, `{:readiness, sequence, classified, slice}`:

| Field | Value |
| --- | --- |
| `sequence` | A positive integer the owner increments on every write |
| `classified` | The owner's `classified` value after the last completed slice: `:pending` before the first slice ends, `:complete`, or the incomplete value, whose delivered four elements (`helper.ex` :306-307) gain a fifth, `reason`, as `{:incomplete, covered, enumerated, failed, reason}`, with `reason` `nil`, `{:closed, session_id, code}` or `{:unavailable, code}` as below; that value stays composition-private |
| `slice` | `:idle`, or `{:classifying, started_ms}` with the owner's monotonic start |

The owner writes the row in the same callback that changes the state it
describes, before it begins any work the row announces and before it replies
to the call that ends it: `{:classifying, started_ms}` as the first step of
`handle_call({:classify, ...})`, before `classify_root/2`; `classified` and
`:idle` together as the last step, before the reply; and every other change
of `classified` in the callback that makes it, before its reply: the
delivered `Helper.classification/2` call, handled by
`handle_call({:classification, value}, ...)`, writes the row with that
value and the current `slice`. The initial row, written before `init/1`
returns, carries the `classified` value `init/1` sets, which is the
`:classified` start option when given and `:pending` otherwise, with
`:idle`. Parent creation, helper jobs and status reads do not write it,
because they do not change classification.
No other process writes helper truth: the row is a projection the owner
already holds, and the slice task, the service and readiness only read it.

*Reason.* `classify_root/2` sets it. `{:closed, session_id, code}`: a
session's scan failed with one of
[ADR 0072](0072-store-readiness-marker-backup-and-restore-technical.md#technical-depth)'s
three closed codes, which `classify_session/4` now keeps; `failed` stays
`[session_id]`. `{:unavailable, :store_unavailable}`: the runtime-page
enumeration (`enumerate/4`, `helper.ex` :874-889) answered
`{:ok, :store_unavailable}`. `{:unavailable, :runtime_unavailable}`: any
Runtime query the classification makes, the enumeration's or the binding
lookup's `Runtime.creation_provenance/2` (`load_parent/2`, `helper.ex`
:942-972, through `retained_objects.ex` :778-787, which keeps that cause
under ADR 0072) or a session scan's `Runtime.effect_intents/4` (`runtime.ex`
:454-457, :485-488), answered `{:error, :runtime_unavailable}`; accepted
[ADR 0046](0046-child-session-tool-technical.md#technical-adr-0046-decision)
names the first and the third. `{:unavailable, :unexpected}`: the enumeration answered anything else
that is not a page, or a session's scan failed with any other code outside
those three, `invalid_query` included. `nil`: the slice's deadline expired, during the
enumeration (:875-876, whose `:error` M8 keeps apart from a refused page)
or between or within sessions (:897-898, :904), or the owner has no runtime
(:861). `failed` is `[]` for every reason but `closed`. The route guard's
`Delegation.incomplete/1` (`delegation.ex` :259-266), which reads the value
through `Helper.status/1`, matches the five-element value and keeps its
four-element refusal `{:helper_classification_incomplete, covered,
enumerated, failed}`, as `Helper.classify/2`'s reply (`helper.ex` :309)
does; `delegation_guard_test.exs` :199's injected value gains `nil`.
Readiness never calls `Helper.status/1`.

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
| The table is gone (the owner exited) | `unavailable` | `unexpected`; the service is already failing stop as `runtime_lost`, which kills its listener at once (`service.ex` :1370), so a socket client normally sees the service exit instead |

*Freshness.* The row is exact at the instant of the read: the single writer
updates it at every transition, so readiness reports `classifying` for the
whole of a slice and the counts of the slice before it, never counts it has
not completed. `Helper.classify/2` checks its budget only between sessions
and operations (`helper.ex` :875, :897, :998), so a slice can outlive it and
is still `classifying` until it ends; readiness infers no budget.
Readiness reads no `sequence` across calls; the field lets a test prove that a
later read saw a later write.

While a pass is incomplete without a named session, the service runs
a further 60,000 ms `Helper.classify/2` slice from a linked task one second
after the last one ends, as ADR 0046 requires of a resident host. Only a
test changes that budget, for every further slice, through the service's
`classification_slice_ms` start option; the startup slice, run inside
composition, keeps 60,000 ms. Once the
permit seam lands (M8 plan step 6, W2), the loop starts only after ADR
0071's startup step 5 has bound the activation permit, so no slice delays
that bind or recovers a child uncounted; before it (plan step 4, W1) the
loop starts after composition and no permit exists. It stops as
ADR 0071's [stop order](0071-daemon-attached-conversation-technical.md#technical-adr-0071-stop-order)
states. The task is a tracked component, but the delivered exit
classifiers (`classify_exit/3`, `service.ex` :1784-1788, and
`classify_startup_exit/3`, :1823-1830) treat every exit of a tracked
component, `:normal` included, as a loss. The task therefore ends `:normal`
only after a complete pass or a named session, and both classifiers ignore
that `:normal` exit of the slice task; any other exit of it fails the
service, `runtime_lost` while serving, as an owner exit does, so the service
never stays `classifying` with no slice to come. The schema
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
  exits `0`; a `live_owner` error prints `loopex: <class>` and exits `1`. When the socket answers and `daemon.status`'s
  `placement_identity` equals `Loopex.runtime_placement_id(root)`, it
  re-verifies the owner's incarnation, sends that BEAM process `SIGTERM`, and
  polls every 250 ms until the owner is gone, printing `loopex: stopping
  (Ns)` on standard error every 5,000 ms. It sets no bound of its own, because
  the [daemon's stop bound](../operator/daemon.md#operator-daemon-stop-bound)
  depends on the root's cancellation budget; a signal ends only the wait,
  with exit `130` and `the service is still stopping`. It exits `0` when the
  owner is gone and the placement lock file is gone, else `1` with
  `stop_unconfirmed` and the log path. Whenever no owner remains, including
  the `stopped` case, it then prunes stale start exit and service-record files as `spawn` does;
  a prune never changes its exit status. A live owner whose socket does not
  answer, refuses `daemon.status` as `daemon_stopping`, or answers with
  another `placement_identity`, is classified under
  the holder classification: a stopping service is waited for exactly as
  above, without a signal (D44); a service still starting, or any holder
  that is not a service, is refused `root_held` with the PID and never
  signalled.
- **`service status`.** Prints the closed status object below and exits `0`
  for `serving`, `3` for any other state, and `1` when it cannot determine
  one: the file cannot be selected or loaded, the socket answers
  `daemon.readiness` but not `daemon.status`, `Placement.live_owner(root)`
  answers `placement_unverifiable` or `placement_lock_failed`, or the
  holder's incarnation read fails (`placement_unverifiable`), which it
  prints as `loopex: <class>` with no object. `service start` prints the same
  object. A live owner whose socket does not answer is `stopping` or
  `starting`, as its service record says under the holder classification,
  and `held` for any holder that is not a service.
- **`paths`.** Keys: `home`, `configuration_file`, `selected_by` (`flag` or
  `home`), `state_root`, `workspace`, `socket`, `log_directory`. Exits `1`
  only when the file cannot be loaded.
- **`doctor`.** Keys: `configuration_file`, `selected_by`, `configuration`
  (`valid` or `<class> <pointer>`), `state_root`, `workspace`, `socket`,
  `credentials` (one `{"pointer":…,"present":…}` per configured reference,
  an `oauth` route present by the `precheck` row's metadata and floor rule;
  environment names are not printed, as ADR 0049 redacts them),
  `legacy_credential` (`present_ignored` when `LOOPEX_PROVIDER_API_KEY` is
  set and no file binding names it: ignored by the service and chat, while
  durable `ask` uses it for the providers the file does not name, D57; else
  `absent`, and a binding that names it is reported under `credentials`), `root` (ADR 0072's marker, holder and backup
  format object, by reference), `service` (the `service status` object) and
  `version`. When the file does not validate, the selection is not composed:
`state_root`, `workspace`, `socket`, `root` and `service` are `null`,
`credentials` is empty and `legacy_credential` is decided from the variable
alone. It reads no credential value and no
session record. Exits `0`
  when the file is valid, every reference is present, ADR 0072's check accepts
  or the root is absent, and the service is `stopped` or `serving`; else `1`,
  including when the service state cannot be determined, for which its
  `service` value is `null` and the `live_owner` class is printed on standard
  error.

#### Service status object

Exactly these eight keys, in this order; no other key is ever printed. The
command reads, in order: the selection (`Home.select`, `ConfigFile.load`,
`ConfigSelection.compose` with no overrides); `Placement.live_owner(root)`;
and, only when that answers a live owner, one
`DaemonClient.connect(socket, timeout: 1_000)` and, on that one connection,
`daemon.readiness` and then `daemon.status`, each bounded at 1,000 ms. With
no live owner it connects to nothing, so a service whose owner exits between
the reads is never reported `stopped` beside a readiness answer. A
`daemon_stopping` refusal of either request is no answer: the object is
built as when nothing answered.

| Key | Type | Source |
| --- | --- | --- |
| `state` | String: `stopped`, `held`, `starting`, `stopping`, `serving`, `classifying`, `closed` or `unavailable` | No live owner: `stopped`. A live owner and no readiness answer: `stopping` or `starting` when its service record matches, as the record says, else `held`. A readiness answer: its `state`. A `live_owner` error: no object, exit `1` |
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
`provider_sign_in_required` (ADR 0073's class, from the start precheck, with its `loopex auth login <provider>` hint), `sign_in_unavailable` (ADR 0073's class for a disabled sign-in route, at configuration resolution, D52; and from foreground `run`, `resume` and `skill` without `--service`, D58 and its note: they select no file, so an `oauth` binding reaches them only through the composition host option `:provider_bindings` of `LoopexCli.dispatch/2`, which `credential_host/1` reads (`loopex_cli.ex` :1795-1803), and for one of the selected route they print ADR 0073's line `loopex: sign_in_unavailable /providers/ROUTE/credential/oauth` and the hint `use loopex chat, loopex ask or --service`),
`service_command_unavailable`, `service_not_ready`, `service_closed`,
`service_not_serving`, `service_stopped`, `service_exited`, `placement_unverifiable`, `placement_lock_failed`, `root_held`, `stop_unconfirmed`, `auth_root_overlap`, and a daemon start refusal under its
`LoopexDaemon.ExitStatus` class name, among them `service_record_write_failed`
for a service that exited 125.

#### Ownership

| Piece | Module |
| --- | --- |
| `HOME`, file selection, layout paths | `LoopexCli.Home` (new) |
| Sign-in directory, path selection and sign-in context, including `secret_service_bus` from `DBUS_SESSION_BUS_ADDRESS` | `LoopexCli.Home` (`auth_directory/1`, `adc_directory/1`, `sign_in_context/1`, new), called by every row of its table |
| Separation comparison | `LoopexComposition.SignIn.Separation.check/1` (new), its only public function, called by `LoopexCli.Home`, by ADR 0072's `StoreAdmin.restore/3` for an available restore source, and, on the context it was given, by ADR 0073's store and refresher. It has one implementing owner, M8's W4, and lands before `LoopexCli.Home` |
| `init`, `config set`, `config unset`, lock and atomic write | `LoopexCli.ConfigWriter` (new); candidate validation by `ConfigInspection.validate_document/2` and `ConfigFile.resolve_document/2` (both new) |
| Optional `--config`, selection line | `LoopexCli.ConfigOptions`, `LoopexCli.ConfigInspection` |
| `ask`'s `--config`, file selection and `providers` (D54, D57) | `LoopexCli.AskOptions` (the `config` flag), `LoopexCli.Ask.prepare/2` |
| On-demand machine, spawn, wait, holder classification, exit-file and service-record pruning | `LoopexCli.ServiceStart` (new); `LoopexCli.Service` calls its prune after `service stop` |
| Service record write | `LoopexCli.Daemon`; the stopping mark and the removal after the lock's release, `LoopexDaemon.Service` |
| `service`, `paths`, `doctor` | `LoopexCli.Service` (new); dispatch in `LoopexCli` |
| `--service` on live forms | `LoopexCli.Live` |
| `--config`, `--admit-project-resources` | `LoopexCli.Daemon`, `LoopexDaemon.Command` (ADR 0071) |
| `daemon.readiness` and the slice loop | `LoopexDaemon.ServiceReadiness` (new), `LoopexDaemon.Service`, `Request`, `SocketConnection`, `WireRecords`; `LoopexComposition.Delegation.Helper` (the readiness table and its single writer), `LoopexComposition.Delegation` (the handle's `readiness` member) |
| `service status` object | `LoopexCli.Service` |

#### Accepted text this record touches

- **ADR 0003, amended.** Its rule "No Loopex application reads a user home
  directory" gains one exception: `LoopexCli.Home` in the installed reference
  host reads `HOME` and passes absolute paths inward. No other application or
  adapter gains discovery authority, extension-source admission is unchanged,
  and "no test or helper may point at a real one" stands: the CLI test helper
  sets `HOME` to its temporary root beside `LOOPEX_HOME` and fails before any
  test if either escapes it; the attended `m8-operator` record, in the
  separate macOS user account ADR 0038 names, is that rule's attended opt-in
  (M8 D87).
- **ADR 0049, narrowly amended.** `--config` becomes optional on `chat`,
  `config validate` and `config show` when a home is selected, and `loopex
  ask` accepts it and uses only `providers`, for the providers they name
  (D54, D57); schema, precedence, origins and the single `LOOPEX_HOME`
  alias are reused unchanged.
- **ADR 0046, reused.** Its resident-host slicing rule is implemented as
  stated; nothing about classification changes.
- **ADR 0044, applied.** It owns the `loopex.experimental/4` contract
  manifest: its ordered `methods` inventory, result definitions and the
  digest computed over them. `daemon.readiness` joins that `methods`
  inventory and `initialized.supported_methods`, its result joins the
  payload definitions, and the manifest digest is recomputed by ADR 0044's
  recipe and pinned in the vectors, `LoopexCli.DaemonClient` and the Node
  client. The generation name, the recipe and every other member are
  unchanged.
- **ADRs 0031 and 0032, reused.** Placement lock, socket placement and the
  stop bound are unchanged except the teardown term, which ADR 0071's
  [stop order](0071-daemon-attached-conversation-technical.md#technical-adr-0071-stop-order)
  extends.
- **ADRs 0051, 0072 and 0073, applied.** The separation invariant is what
  keeps ADR 0073's tokens and the ADC refresh token out of ADR 0072's
  backups and restores, within the [operator limit](#technical-0037-operator-limit).
  ADR 0051's complete manifest is unchanged and excludes no file; a root,
  backup, destination or available source whose path is, contains or lies
  inside a protected credential directory is refused instead, before the
  store command reads or writes it. ADR 0051's manifest walks and refusal
  vocabulary are unchanged.

<a id="technical-adr-0037-evidence"></a>
### Evidence

Concept: [Observable consequences](0037-host-configuration-and-path-discovery.md#concept-adr-0037-consequences).

Every case uses a temporary `HOME` and `LOOPEX_HOME`. Test files are in
`apps/loopex_cli/test` unless another application is named.

*Test seams.* The race and real-daemon cases run a test-built escript at
`<dir>/loopex` with the launcher copied to `<dir>/bin/loopex`, so its
starters resolve that launcher through `ServiceStart.command/1` as in a
checkout, and every starter and daemon is its own OS process. The *private
hooks* they name are compiled only under `Mix.env() == :test`, as the
`LOOPEX_TEST_TRACE` seam is (`owner_activation.ex` :272-281), and act only
when `LOOPEX_TEST_HOOKS`, which a test sets in a starter's environment and
its spawned daemon inherits, names a directory holding a file named for the
hook. A *pause* writes `<name>.reached` there and waits, checking every
100 ms, until the file is removed: `starter_before_spawn`,
`starter_after_spawn` (before the first exit-file read) and
`starter_between_reads` (between the two `live_owner` reads) in
`ServiceStart`; `daemon_before_record` and `daemon_after_record` (after the
rename, before `Sentinel.run/2`) in `LoopexCli.Daemon`; `before_link`
(between the owner-handle write and the link) in the extracted lock
primitive; and `after_lock` (after `acquire_placement/1`), `after_mark`
(after the stopping mark, before the transport cut), `mark_write` (in the
mark's writer process, before it writes) and `in_fail_stop` (in
`fail_stop/2` after the listener is killed, before `report_exit/2`) in
`LoopexDaemon.Service`; `runtime_page_read` in `Loopex.Store.Local`'s
`creation_provenance/3` for a `runtime_page` selector, before its call to the
store's server, so it holds Control's reader, which Control kills at its
1,000 ms read bound, and not the store; and `admitted_prompts_read` in
`Helper`, before each `load_records/4` of `admitted_prompts/5`. A *fault*
makes one step fail: `record_write` and `own_incarnation` make the record write and the daemon's own incarnation
read answer an error, and `fail_stop` makes a serving service, checking
every 100 ms, call `fail_stop/2` with `runtime_lost`, `startup_failure`
makes the service, immediately after `after_lock`, stop
`{:fatal, :composition_start_failed}` (status 92), and `late_startup_failure`
makes it, after ADR 0071's startup step 6, whether or not it started the
slice loop, and before the listener, stop `{:fatal, :listener_start_failed}` (status 94). "Startup pause" and
"injected slow start" below are `after_lock` held, "drain" is `after_mark`, and "a service in a fail-stop" is
one held at `in_fail_stop` after `fail_stop`, a hold the sentinel's 35,000 ms
watchdog still ends.

| File (new unless noted) | Kind | Cases it proves |
| --- | --- | --- |
| `home_test.exs` | Unit | Absent, relative, non-UTF-8 and oversized `HOME` refuse; default path on each platform; `--config` wins; missing discovered file refuses naming `init`; a `config.json` in the invocation directory is ignored |
| `config_inspection_test.exs` (extended) | Unit | Explicit and discovered selection of the same bytes give identical rows and origins; the selection line; `LOOPEX_HOME` still overrides the file's root |
| `config_writer_test.exs` | Unit and fault | `init` refuses an existing file and each missing flag; written document validates and holds no value outside the schema; `set` and `unset` pointer rules and `/schema_version`; kill points before the temporary write, before rename and after rename leave prior bytes or the new bytes, never a partial file; a live lock refuses; a lock whose incarnation is gone, including a reused PID, is reclaimed; modes 0700 and 0600 |
| `service_start_test.exs` | Process race | Eight concurrent starters released together at one barrier, each probing before any daemon holds the lock, spawn at most eight daemons and all converge on one serving socket, the others recording 76 and classifying the winner as a service from its record; a starter whose first probe finds a live foreground holder and no answering socket refuses `root_held` with that PID within 2,000 ms, never waiting for the 75,000 ms deadline, and signals nothing; a starter whose first probe finds another starter's service held at a startup pause after it took the lock waits and converges on the same serving socket once the pause is released; a `loopex daemon --config` started directly and held at the same pause is waited for the same way, and an M7-form `loopex daemon` without `--config` holding the root is refused at once; **two losers, foreground winner**: two starters that probed an unheld root are paused before their spawns while a foreground `chat` takes the placement lock, then resumed together; both services exit 76, each starter refuses `root_held` with the foreground PID within 2,000 ms of reading its own exit file, neither waits for the deadline, and the `chat` receives no signal; in a second case one of the two starters is killed after its spawn and before it reads its exit file, and the other still refuses within 2,000 ms; **unrelated records**: with the foreground `chat` holding the lock and `log/` holding a fresh `service-<pid>.id` that names the `chat`'s PID with another incarnation, a fresh record for a PID no process has, and the record of a spawned daemon killed with `SIGKILL` after writing it and before taking the lock, a probe refuses `root_held` with the `chat`'s PID within 2,000 ms; **holder handover**: a holder that changes between the two `live_owner` reads (the `chat` releases and a service takes the lock at a private pause hook) is not refused, and the command converges on that service; **winner exits before serving**: a service held at a startup pause after taking the lock, with a second command waiting on it from `probe`, is made to exit by the `startup_failure` fault; its starter refuses `composition_start_failed`, and the waiting command returns to `probe`, spawns its own service and converges on its serving socket within its deadline; the service removes its record after it releases the lock, on a clean exit and after that startup failure, and a service in a fail-stop keeps its record until its VM exits; **record write refused** (D31): a daemon whose record write is refused at a private hook exits 125 before taking the lock, leaving no record, lock or socket, and its starter refuses `service_record_write_failed`, and the same holds when its own incarnation read fails at a private hook; a second starter released concurrently with it, whose own write is not refused, finds nothing holding the root and converges on its own serving service; a record naming another socket is no match and the probe refuses `root_held`; an own exit status of `0` refuses `service_stopped` and a spawned daemon killed with `SIGKILL` before taking the lock refuses `service_exited` naming `137`; a `live_owner` answering `placement_unverifiable` or `placement_lock_failed`, and a failed incarnation read, each refuse at once; **lock publication**: a probe made while a service's acquisition is paused at a private hook between its owner-handle write and the link finds no holder, a probe after the link finds the complete record, and neither refuses `placement_unverifiable`; **record replacement**: a record placed under a spawned daemon's own PID with another incarnation, at a private hook before its write, is replaced and the daemon serves; **root spelling**: a service started from a file naming the root through a symbolic link is waited for by a probe from a file in the same directory naming it directly; **pruning**: with `log/` holding a start exit file, a `.exit.tmp` and the record of a dead process, each aged past 300,000 ms, a fresh exit file of a starter still waiting, a file named `start-` with 15 hex characters, a record name with a leading zero, a symbolic link with an exit-file name and an unrelated file, `spawn` and `service stop` (including when it prints `stopped`) remove exactly the three aged files, and the waiting starter still reads its own status; an aged `.id.tmp` is removed and an aged record naming another socket is kept; a prune run while a service holds the lock keeps that holder's record aged past 300,000 ms; 1,025 aged files are pruned at most 1,024 per prune; a prune whose `live_owner` read answers an error removes the aged exit files and keeps every aged record; **stopping** (D44): a starter that probes while a service is held in its drain at a private hook after writing its stopping mark waits without spawning and sends no signal, and once that service exits it starts a fresh service and converges on its serving socket within its deadline; an absent reference refuses before any process, lock, log or socket; an `oauth` route signed out, or whose floor is at its metadata's generation after a logout killed after its floor write, refuses `provider_sign_in_required` naming the route before any process (D22); with `log/` absent the first start creates it and its starter reads its own exit file; presence check reads no value (sentinel variable never appears in any output or log); a started service's readiness says `unadmitted`; the 75,000 ms bound reports `starting` with an injected slow start; an early exit maps its status to its class; the spawned command is `<root>/bin/loopex` for an escript at `<root>/libexec/loopex` beside a `MANIFEST` and the launcher beside a checkout escript; with `LOOPEX_ESCRIPT` set to a decoy executable that writes a sentinel file and exits 99, the sentinel file never appears and the started service serves; a non-executable selection refuses `service_command_unavailable` |
| `service_command_test.exs` | Real daemon | `start`, `stop`, `status`, `paths` and `doctor` objects and exit statuses; `stop` refuses a foreground holder, and a service held at a startup pause after taking the lock, with `root_held` and signals neither; a second `stop` during the first's drain, held at a private hook, signals nothing, waits and exits `0` once the owner and the lock file are gone (D44), as does a `stop` whose `daemon.status` is refused `daemon_stopping`; a mark write held at a private hook delays the stop by at most 1,000 ms, and the service is then reported `starting` until it exits, as is a service in a fail-stop (D53); `doctor` with a service running reads readiness from it and opens no session record; `doctor` with a file that does not validate prints `state_root`, `workspace`, `socket`, `root` and `service` as `null`, `credentials` empty and `legacy_credential` from the variable alone, and exits `1` |
| `service_detach_pty_test.exs` | PTY | A service started on demand from a PTY survives `SIGINT` and `SIGTSTP` to the foreground group and hangup of the PTY, still answering readiness from another client, and stops on `service stop` |
| `live_service_test.exs` | Real daemon | `run` and `resume --service` start on demand; `attach` and `sessions --service` refuse `service_not_running`; `--daemon` never starts |
| `apps/loopex_daemon/test/readiness_method_test.exs` | Socket | Each of the four states from helper and runtime seams; the `closed` session and code; project-resource values; schema vectors and the updated digest |
| `auth_separation_test.exs` | Unit and real filesystem | For each origin (`--state-root`, `LOOPEX_HOME`, the file's `paths.state_root`): the root equal to `A`, containing it, and contained by it each refuse `auth_root_overlap` with that origin's pointer, before any file, lock, log, socket or process; `/x/state` beside `/x/stateful` and the default `<home>/state` beside `<home>/auth` pass; a root selected under one `HOME` and used under another whose `.loopex/auth` lies inside it refuses; a symbolic-link root resolving to an ancestor of `A`, a symbolic-link `HOME` and a symbolic-link `auth` each refuse; a link loop and 41 chained links refuse; **missing-tail aliases**, on real directories on both hosts: with `data` and a symbolic link `alias` to it, `HOME` under `alias` with `.loopex/auth` absent and a root `data/.loopex/auth/state` absent refuse, as do the reverse containment and an equal pair, while `alias/.loopex/auth` beside an absent `data/.loopex/state` passes; a `..` in a missing suffix refuses; **missing-component rule**: an ASCII case variant (`Auth` against `auth`) and any non-ASCII missing component at the same position refuse on both hosts, and `/x/state` beside `/x/stateful` passes; an existing case variant on a case-insensitive `darwin-arm64` volume refuses through identity; the `Separation.check/1` context grammar (shape, a missing or sixth member, relative or non-UTF-8 path, 17 roots, a `secret_service_bus` that is empty, non-UTF-8, 4,097 bytes or not a string) refuses, and contexts differing only in a valid `secret_service_bus` or `nil` give the same answer on every pair above; `Home.sign_in_context/1` sets `secret_service_bus` from `DBUS_SESSION_BUS_ADDRESS`, to `nil` when it is unset, empty, over 4,096 bytes or not UTF-8, and never refuses for it; an absent or relative `HOME` refuses `home_unavailable` on every row (durable `ask` reports it as `command_failed`), and an ephemeral `ask` still runs; an ephemeral `ask` whose `A` lies under a directory holding a `loopex-root-format` marker reports status 1 `command_failed` before any session; `config set /paths/state_root` to an overlapping path leaves the earlier bytes; `auth login` refuses when an ancestor of `A` holds a `loopex-root-format` marker; `store adopt`, `store backup` and `store restore` refuse an overlapping root, `BACKUP` and `DESTINATION` before reading or writing any of them; **available source**: a valid backup whose capture names a source root equal to, containing or inside `A` or `G`, restored with `--source available`, and resumed with `--resume` from a retained `available` plan or abandoned with `--abandon` from one, refuses `auth_root_overlap /capture/source_state_root` after the capture is read and before `BACKUP/manifest`, `BACKUP/state` or the source is read, with nothing written, while the same capture with `--source lost` and the source absent is not refused by separation; a backup of a separated root holds every file of the root and no file of `A`; **ADC directory**, on real directories with a temporary `HOME` and a credential-shaped canary `application_default_credentials.json` (random bytes in the file's grammar, never a real credential) under `<HOME>/.config/gcloud`: for each origin, a state root equal to `<HOME>/.config/gcloud`, containing it (`<HOME>/.config`) and contained by it (`<HOME>/.config/gcloud/state`) refuses `auth_root_overlap` with that origin's pointer, both when `gcloud` exists and when it is absent, before any file, lock, log, socket or process; `store backup` of such a root refuses before `BACKUP` or its staging directory exists, so no copy of the canary is written; `store restore` with `DESTINATION` an empty `<HOME>/.config/gcloud`, or a path under it, refuses before any write and leaves the directory as found, so no restored file lands in or overwrites it; `store adopt` of such a root refuses with the canary's bytes unchanged; the complete manifest of a separated root is unchanged and holds no exclusion. No case creates a mount: under D27 mounts are outside the guarantee, and the walk's refusal of symbolic links and hard-linked files is ADR 0051's delivered behaviour, proved by `restore_io_test.exs`'s existing symlink and hard-link manifest cases; **physical root**: a root selected through a symbolic-link ancestor, by each origin, reaches `Placement.acquire/2`, composition and every `store` command as its physical path, and a `run` started through the alias then backed up and restored serves |
| `daemon_configuration_test.exs` (ADR 0071, extended) | Real daemon | `loopex daemon`, with and without `--config`, exits 111 with class `auth_root_overlap` and each origin's pointer, with class `home_unavailable` for an absent or relative `HOME`, and, with `--config`, with class `sign_in_unavailable` for a disabled sign-in route (D52), leaving no lock, log entry or socket, each printing `loopex daemon refused to start: configuration_invalid <class>` with its pointer, if it has one; with and without `--config`, a root and an explicit `--socket` both given through a symbolic-link ancestor serve (D53 and its note), a socket whose physical path exceeds the limit while its alias fits refuses `socket_path_too_long` (87) before any lock, and a `--socket` through a link loop or with `..` in its missing suffix refuses `invalid_socket_path` (89) |
| `apps/loopex_daemon/test/readiness_slice_test.exs` | Socket, real helper owner | *Startup choreography*: the `runtime_page_read` pause, held for the startup slice's first read only, makes the startup slice end before recovery: Control's 1,000 ms read bound (`control.ex` :70, :5266-5300) cuts that read, so that slice ends `{:unavailable, :store_unavailable}` and the service serves. The `admitted_prompts_read` pause, armed from the start and never reached by the startup slice, holds a stop-only recovery read (`helper.ex` :1742), a direct Store read that Control's read bound does not cut, on a root holding an unfinished helper operation whose child was never prompted, so the first further slice, one second later, is the one held: `daemon.readiness` asked concurrently and repeatedly answers within 1,000 ms each (measured), as `classifying` with the previous slice's counts, `"0"` and `"0"` from that startup slice; the row's `sequence` advances at slice start and end; a parent creation held in the owner does not delay readiness; releasing that pause gives `serving`; a slice loop whose further slice completes the pass ends and the service keeps serving, and the slice task killed while serving fails the service `runtime_lost`; `ServiceReadiness` called directly with a handle whose table owner was killed answers `unavailable` with `unexpected`, and over the socket killing the owner only makes the service exit `runtime_lost`; a slice whose deadline expires during the runtime-page enumeration, on a root of more than 16 sessions, after the startup choreography's first page hold, with each later page read held at `runtime_page_read` below 1,000 ms and the further slices' budget lowered below one such hold by the service's test-only `classification_slice_ms` start option (60,000 otherwise), leaves `classifying`, while a page held past Control's 1,000 ms read bound answers `store_unavailable` and gives `unavailable` with that code, and the next slice retries; a published row whose reason is `{:unavailable, :runtime_unavailable}` and whose slice is `:idle` gives `unavailable` with `runtime_unavailable`, its producer proved at the owner boundary by ADR 0072's `delegation_readiness_code_test.exs` with a runtime whose Control is gone (`runtime.ex` :1033-1038); the route guard's refusal keeps its four elements; no readiness path calls the owner |
| `service_status_test.exs` | Real daemon | The status object has exactly its eight keys in order for `stopped`, `held`, `starting` (a service held at a startup pause after taking the lock), `stopping` (a service held in its drain after writing its stopping mark, exit `3`), `classifying`, `serving`, `closed` and `unavailable`; `stopped` is never printed beside a readiness answer, including when a service stops between the `live_owner` read and the connection; `readiness` is the verbatim result or `null`; `activations_used` and `activation_limit` equal `daemon.status`'s and include a helper child after one runs; a service started from another file keeps its own `readiness.configuration_file`; exit statuses 0, 3 and 1, including a socket that answers readiness and not status |
| `clients/node` contract lane (extended) | Independent client | `daemon.readiness` decoded from the schema by the Node client, and the recomputed ADR 0044 manifest digest matched by its independent preimage |

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
- *Start markers written by starters.* A marker says that some start began,
  not who holds the lock: starters that all lost to a foreground command
  each saw another's marker and waited out the deadline, as did any command
  that found a killed starter's young marker. The service's own record,
  matched to the lock holder's incarnation, answers the question directly.
- *Readiness in `daemon.status`.* Its result is exact and printed by
  `sessions --status`; a separate method leaves it and its consumers unchanged.
- *A readiness file in the root.* It would write inside the root outside the
  service's lifetime and say nothing true after a crash.
