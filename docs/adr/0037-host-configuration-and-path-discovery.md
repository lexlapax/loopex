<a id="concept"></a>
## Concept

Technical depth: [Installed host configuration and path discovery](0037-host-configuration-and-path-discovery-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30; reconciled with the delivered M7 baseline on 2026-10-13; detailed for implementation on 2026-10-13; service command resolved from the escript's own location on 2026-10-13; readiness source, status object and sign-in separation specified on 2026-10-13; separation comparison for missing paths and the host-to-store sign-in context specified on 2026-10-13; the ADC directory protected and the physical walk check added on 2026-10-13; the walk check extended to refuse any mount inside a walked tree on 2026-10-13; the maintainer's Linux separation by filesystem path and Linux mount-table walk rule decided, and the restore walk after the commit stated, on 2026-10-13; the maintainer's rule for overlay, FUSE and network mounts at or above a walked root (D21) decided on 2026-10-13; after the holistic internal review on 2026-10-13, the maintainer's confirmation that an unready sign-in route refuses the start (D22), and the start's immediate `root_held` refusal, the pruning of start exit files, the sign-in context's session-bus member and ADR 0044's method inventory; a probe's wait on another command's start in progress, and the start's handling of a lost placement race and of a clock-skewed pending file, stated on 2026-10-14; the maintainer's decision that credential separation is a path rule only (D27), superseding D19, D21 and every mount and walk-identity rule, recorded on 2026-10-14; the maintainer's decision that a service that cannot write its service record refuses the start with daemon status 125 (D31), recorded on 2026-10-14; the maintainer's acceptance of the start and status contracts (D39) and the fixes of the second holistic internal review, recorded on 2026-10-14
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0003](0003-extension-contract-boundary.md#concept) only its ban on any Loopex application reading a user home, narrowed to the installed reference host; it also narrowly amends [ADR 0049](0049-explicit-host-configuration.md#concept)'s grammar so `--config` is optional when a home is selected
- **Depends on:** [ADR 0049](0049-explicit-host-configuration.md#concept), accepted and delivered by M7; [ADR 0071](0071-daemon-attached-conversation.md#concept) for the service's configuration reader; [ADR 0072](0072-store-readiness-marker-backup-and-restore.md#concept) for the root facts the diagnostic command reports
- **Prerequisite for:** M8 outcomes 2 and 4: installed discovery, configuration management, service lifecycle and readiness; not an M7 prerequisite

<a id="concept-adr-0037-decision"></a>
### Context and Decision

Technical depth: [Contract](0037-host-configuration-and-path-discovery-technical.md#technical-adr-0037-decision).

M7 delivered explicit configuration, named roles and provider routing under
ADR 0049, with `config show` and value origins. The installed successor reuses
that reader and schema, then adds a documented default home, automatic loading
of that home's configuration file, configuration writers and lifecycle
commands. Core and reusable composition still receive explicit values and never
discover home directories.

The maintainer's 2026-10-13 decisions for M8 bind this record: release
`0.5.0` on macOS arm64 and Linux x86-64 (glibc 2.35), and proposals P4, P5, P6
and P8 of the [M8 plan](../plans/M8.md#concept-plan-decisions) as written.
They are recorded here as decided, not proposed.

**The decision.**

1. **One home, found one way.** The home is `.loopex` under the operator's
   `HOME`, on both supported hosts. `HOME` is its only environment input;
   there is no project search, no XDG search and no second variable. An
   explicit `--config FILE` always wins over the home's `config.json`, so
   `--config` becomes optional on `chat` and configuration inspection, and
   inspection says which file was selected and why. `LOOPEX_HOME` keeps its
   ADR 0049 meaning: it names the state root, not the home.
2. **The home holds configuration, not state.** `loopex init` writes the
   configuration with a state root of `state` beside it, so the store-owned
   root is a subdirectory that ADR 0072's marker rule can create empty. The
   service log sits in a `log` directory beside the configuration, outside
   the root.
3. **Writers change the file atomically and never write a secret.**
   `loopex init` creates the file and refuses one that exists. `loopex config
   set` and `config unset` change one member. Every write validates the whole
   resulting document with ADR 0049's reader before it replaces the file, under
   one writer lock, and a failed write leaves the earlier bytes. Credentials
   remain named environment references.
4. **Lifecycle commands.** `loopex service start`, `service stop` and `service
   status` manage the service; `loopex paths` and `loopex doctor` inspect the
   home. All of them select the home the same way and pass the selected file to
   `loopex daemon --config` under ADR 0071, which adds no second reader.
   `service status` prints one closed object: the service's state, process,
   socket, state root and selected file, the service's whole readiness answer
   kept intact, and the activations it has used out of its 64, helper
   children included. Its state is one of `stopped`, `held` (a process that
   is not a service holds the root), `starting`, or the service's own
   `serving`, `classifying`, `closed` or `unavailable`; it exits `0` when
   serving, `3` in any other state and `1` when it cannot tell. `service
   stop` signals only a holder whose socket answers as this root's service;
   a live holder whose socket does not answer, a foreground command or a
   service still starting, is refused as `root_held` and is not signalled.
   The maintainer accepted these contracts on 2026-10-14 (D39).
5. **The service is asked for by name.** `--service` on `chat`, `run`,
   `resume`, `attach` and `sessions` names the selected home's service. The
   conversation, `run` and `resume` start it on demand; `attach` and
   `sessions` never do. `--daemon SOCKET` keeps its M7 meaning and never starts
   anything. Without either flag every command is the foreground or offline
   command it is today, whether or not a home exists.
6. **Starting on demand.** The starting command checks that every configured
   credential reference is present, without reading a value, and refuses by
   name before anything starts when one is absent. A configured sign-in route
   that is not signed in refuses the start the same way, and `loopex daemon`
   started directly on such a configuration exits with ADR 0073's status 120;
   the maintainer confirmed on 2026-10-13 that this stays (D22). The service inherits that
   command's environment and runs detached from its terminal, so closing the
   terminal or interrupting or suspending the command does not stop it. It never prompts and
   leaves the workspace's project resources unadmitted, which its readiness
   report states. `loopex service start` at a terminal shows the project
   resources and asks, as the daemon does in the foreground today. Concurrent
   starts converge on one service through the existing placement lock. A
   service started from a configuration file alone, as a start runs it,
   records its own process incarnation in that file's log directory before it
   takes the lock, so the lock's holder shows whether it is a service. A
   service that cannot write that record refuses to start: it exits with the
   new status 125, `service_record_write_failed`, before taking the lock, and
   its starter refuses with that class (D31). A command that finds the root
   held by a process whose socket does not answer waits only when that
   holder is a service: its record in the selected file's log directory
   matches the lock's incarnation and names the same socket. Any other
   holder, a foreground command or a service started from a file in another
   directory, is refused at once as held, naming that process, because no
   wait is known to end. A command whose own service lost the lock judges
   the holder the same way, so starters that all lost to a foreground
   command never wait on one another. A start that does not end with a
   serving service refuses by name: `root_held`, `service_stopped`,
   `service_exited`, `service_not_ready`, `service_not_serving`,
   `service_closed`, `service_command_unavailable`,
   `service_record_write_failed`, `placement_unverifiable` or
   `placement_lock_failed`, or with the precheck's or the service's own
   class. The maintainer accepted this classification and these classes on
   2026-10-14 (D39).
7. **Readiness is reported as it is.** The running service answers one new
   query, `daemon.readiness`: serving; still classifying helper history, with
   ADR 0046's two counts; closed, with the session whose history could not be
   read; or unavailable, with a code and no session, which the service retries.
   The same answer carries the service's workspace, its project-resource
   admission and its version. Readiness answers within one second even while
   the service is busy classifying or creating a session. It reads what the
   helper owner last published about itself and never waits for that owner.
   A command that starts the service waits at most 75 seconds for it to serve
   and otherwise reports the state it found.
8. **The ADR 0003 amendment is one module.** Only the installed reference
   host's home-discovery code reads `HOME`, and it passes absolute paths
   inward. Tests set `HOME` to a temporary directory.
9. **Sign-in tokens never live inside a state root.** The sign-in directory,
   gcloud's Application Default Credentials directory and every state root
   stay apart by path, as the
   [separation section](#concept-0037-auth-separation) states.

This record introduces no second role or provider schema and fixes no
session's model at process launch. ADRs 0044, 0048 and 0049 govern committed
selection, custody and explicit configuration. Provider sign-in tokens are
decided by [ADR 0073](0073-provider-oauth-sign-in.md#concept); file, keychain
and command sources for API keys remain a separate future decision.

<a id="concept-0037-auth-separation"></a>
### Sign-in Directory and State-Root Separation

Technical depth: [Sign-in directory and state-root separation](0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation).

ADR 0073 keeps provider sign-in tokens in `auth` under the home, and its
Google `adc` source reads a refresh token from gcloud's Application Default
Credentials file in `.config/gcloud` under the user's home. These two are the
*protected credential directories*. The state root can be chosen separately,
by flag, by `LOOPEX_HOME` or in the configuration. ADR 0072's backups copy
every file in a root, so a root that held either directory would put a token
into a backup, and a restore into either would write over credential storage.
This record makes that impossible by refusing the layout rather than by
leaving files out of a backup, and it does so by comparing paths:

- After following symbolic links, a protected credential directory and a
  state root may not be the same directory, and neither may contain the
  other. The same holds for the backup and destination directories the store
  commands name, and for the original root an available restore reads, which
  the backup names. It holds for paths that do not exist yet: each is
  compared from its deepest existing directory. Where separation cannot be
  proved, as when two not-yet-created names could be one name on a
  case-insensitive volume, the layout is refused.
- **A path rule only (D27).** The maintainer decided on 2026-10-14 that
  separation is this comparison of paths and nothing more. Loopex reads no
  mount table on either host and examines no mount, at, above or inside a
  root, while it copies or verifies one. D27 supersedes the mount rules this
  record stated earlier (D19 and D21). The operator-facing limit is: **do not
  mount credential storage into or over a Loopex state root, backup or
  restore destination.** A bind mount, an overlay, a FUSE or network
  filesystem, or a mount inside a root that makes credential storage
  reachable there is outside the guarantee, and so is a credential file the
  operator copies into a root, which is ordinary root content.
- The walk that copies or verifies a root still refuses every symbolic link
  and every file with a second hard link inside it, as ADR 0051's manifest
  always has, so a link placed inside a root cannot reach a credential file.
  The checks run when a command starts; changing those paths while a store
  command runs is outside the guarantee, like a mount.
- A root selected through a symbolic link is opened, backed up and restored
  as its physical path, so the same root under two spellings is one root.
- The installed host's home module owns the rule and decides which paths each
  command checks. It checks before any token is written, any root is created
  or opened, and before `store adopt`, `store backup`, `store restore`,
  `config set` and every daemon or service start, before any lock or process.
  Each store command checks every path it will walk before its first read or
  write of it: the root, the backup and the destination when its
  configuration is resolved, and, for a restore with an available source,
  that source as soon as the restore has read the backup's capture record,
  before it reads the backup's manifest or the source. Every command also
  refuses when any directory above a protected credential directory is a
  marked state root.
- The home module hands the checked protected directories and the exact roots
  it checked to the sign-in token store and its background refreshers. They
  repeat the same check on those paths immediately before every token
  exchange and every token write,
  never find a root of their own, and refuse a path that changed after
  startup, such as a new symbolic link. The same handoff carries the
  session-bus address the Linux keyring needs, which the home module reads
  from the environment once, so the store never reads the environment; the
  separation check ignores it.
- A violation is refused as `auth_root_overlap`, naming where the root was
  chosen, before anything is written. A command exits `1`, as every refusal in
  this record does. `loopex daemon` exits with ADR 0071's existing `111`,
  `configuration_invalid`, so this refusal adds no exit status. A command that
  cannot read a usable `HOME` cannot check the rule, so it refuses
  `home_unavailable` before touching a root. An ephemeral `ask`, which never
  selects a root, is unaffected.
- No file is excluded from ADR 0051's complete manifest, the ADC file
  included. A backup of a permitted root contains every file of that root,
  and none of them is a token unless the operator mounted or copied
  credential storage into the root, which the limit above leaves to the
  operator.

<a id="concept-adr-0037-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0037-host-configuration-and-path-discovery-technical.md#technical-adr-0037-evidence).

An installed operator runs `loopex init` once, inspects effective values and
origins, and runs `loopex chat --service` from any terminal; the first such
command starts the service. `loopex service status` and `loopex doctor` print
one machine-readable line each, and `doctor` never resolves a credential or
scans session history. The host still refuses missing authority or provider
bindings. Tests always use temporary homes.

A configuration change reaches the running service only after a restart; the
writers say so when a service is serving. Removing the configuration does not
remove durable session truth and may make recovery unavailable. After ADR
0072's restore prints a new root, the operator selects it with `loopex config
set`.

<a id="concept-adr-0037-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0037-host-configuration-and-path-discovery-technical.md#technical-adr-0037-compatibility).

The explicit-file path remains supported. Automatic discovery is a new host
trust choice, not project-context admission. Unsupported schemas refuse before
startup. Configuration deletion is not a recovery procedure. `daemon.readiness`
is a named addition to `loopex.experimental/4` with its schema, vectors and
pinned digest updated in the same change. Before 1.0 there is no rollback to an
earlier build; recovery restores a backup under the matching build with ADR
0072's commands, with the configuration file kept beside it.

## Open for the Maintainer

None.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
