<a id="concept"></a>
## Concept

Technical depth: [Installed host configuration and path discovery](0037-host-configuration-and-path-discovery-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30; reconciled with the delivered M7 baseline on 2026-10-13; detailed for implementation on 2026-10-13; service command resolved from the escript's own location on 2026-10-13; readiness source, status object and sign-in separation specified on 2026-10-13; separation comparison for missing paths and the host-to-store sign-in context specified on 2026-10-13; the ADC directory protected and the physical walk check added on 2026-10-13; the walk check extended to refuse any mount inside a walked tree on 2026-10-13; the maintainer's Linux separation by filesystem path and Linux mount-table walk rule decided, and the restore walk after the commit stated, on 2026-10-13; the maintainer's rule for overlay, FUSE and network mounts at or above a walked root (D21) decided on 2026-10-13; after the holistic internal review on 2026-10-13, the maintainer's confirmation that an unready sign-in route refuses the start (D22), and the start's immediate `root_held` refusal, the pruning of start exit files, the sign-in context's session-bus member and ADR 0044's method inventory; a probe's wait on another command's start in progress, and the start's handling of a lost placement race and of a clock-skewed pending file, stated on 2026-10-14
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
   children included.
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
   terminal or interrupting the command does not stop it. It never prompts and
   leaves the workspace's project resources unadmitted, which its readiness
   report states. `loopex service start` at a terminal shows the project
   resources and asks, as the daemon does in the foreground today. Concurrent
   starts converge on one service through the existing placement lock. A
   service started from a configuration file alone, as a start runs it,
   records its own process incarnation in that file's log directory before it
   takes the lock, so the lock's holder shows whether it is a service. A command that finds the root held by a process
   whose socket does not answer waits only when that holder is a service;
   any other holder is a foreground command, and the command refuses at once
   as held, naming that process, because no wait would end a foreground
   command. A command whose own service lost the lock judges the holder the
   same way, so starters that all lost to a foreground command never wait on
   one another.
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
   stay physically apart, as the
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
leaving files out of a backup:

- After following symbolic links, and recognizing an existing directory
  reached through a mount alias such as a bind mount, a protected credential
  directory and a state root may not be the same directory, and neither may
  contain the other. The same holds for the backup and destination directories the store
  commands name. It holds for paths that do not exist yet: each is compared
  from its deepest existing directory. Where separation cannot be proved, as
  when two not-yet-created names could be one name on a case-insensitive
  volume, the layout is refused.
- **On Linux, paths are also compared inside their filesystems.** The
  maintainer decided on 2026-10-13 that on Linux each of these paths is
  also located by the kernel's mount table: the filesystem it lies on and
  its path inside that filesystem. Two paths overlap when they are on the
  same filesystem and one of those inner paths equals or contains the
  other. This recognizes a bind mount of any directory or subdirectory of a
  protected directory, such as a subdirectory of gcloud's directory bound
  at another path and selected as a state root, which neither the paths
  nor the directory identities above reveal. A mount table that cannot be
  read, is too large or is malformed refuses the layout. The comparison runs
  in the early path check and again, for the walked root, at the start of
  every backup, adopt and restore walk. On macOS, which has no bind mount,
  the directory identities decide as before.
- That path check is the early refusal. A mount can still place part of a
  root over credential storage with no link between the two paths, and on
  Linux a single credential file can be bind-mounted into a root. So
  `store backup`, `store adopt` and `store restore` also compare every
  directory they walk while copying or verifying a root with the protected
  directories' physical identities, and refuse any mount inside the walked
  tree, whatever it holds. On Linux a mount is one the kernel's mount table
  lists strictly inside the tree: the maintainer decided on 2026-10-13 that
  an entry which merely reports another device, as files of an overlay
  filesystem and btrfs subvolumes do, is not refused there, so state roots
  in overlay filesystems, as containers use, and on btrfs are supported. On
  macOS an entry on another device than the walked root is refused, as
  before. Each walk reads the mount table at its start and again before its
  final manifest, and refuses a mount added, removed or changed at, above or
  inside the walked root between the two reads. Any of these refusals is
  `auth_root_overlap` before that walk copies a file. A restore that meets one before its root commit record is
  published is never committed. One met after that record exists, in the
  restore's final check of the destination or in claim cleanup, leaves the
  commit standing and the cleanup pending, with the destination closed,
  until a later call with the same plan finishes. A state root, backup or
  destination that contains a mount is therefore refused, and physical
  separation of every copied root rests on that refusal. A credential file
  the operator copies into a root is ordinary root content that no walk can
  recognize.
- **Mounts at or above a walked root (D21).** A mount whose mount point is
  the walked root or lies above it is not inside the tree, and an overlay
  there can still show credential files: its lower, upper and work
  directories are ordinary directories elsewhere, so an overlay mounted at a
  root with gcloud's directory as a lower layer serves the ADC file through
  the root while every device and directory identity differs. The maintainer
  decided on 2026-10-13 that every backup, adopt and restore walk examines
  each mount listed at the walked root or above it:
  - An **overlay** is admitted only when its backing directories can be read
    from the options the mount table shows and none of them overlaps a
    protected directory by filesystem location. A backing directory that
    lies on an overlay is examined the same way, at most eight levels deep.
    An overlay whose backing directories cannot be read from its options,
    or that nests deeper, is refused. Ordinary overlays, such as a
    container's root filesystem, stay admitted.
  - A **FUSE** filesystem is refused, because a user-space program decides
    what it shows, whatever device it names, so its source cannot be
    established. This includes block-backed FUSE such as `ntfs-3g`.
  - **Network and virtual filesystems** (NFS, SMB, 9p, virtiofs, Ceph,
    GlusterFS and the like) are admitted. This is an explicit limit the
    maintainer accepted: a network or virtual filesystem that exports the
    host's own credential directories back to it is not detected.
  - A backing directory is the path the overlay's mounter named, read in
    Loopex's own mount namespace when the walk runs. A container's overlay
    names paths of the host's namespace that do not exist inside the
    container, so a missing backing path is compared by name and admitted
    when it is separate. A backing path that reached credential storage only
    in another namespace, or through a link changed since the mount was
    made, is outside what the walk can see, as the network limit is.
  - On macOS the walk reads the system's mount list and refuses a FUSE
    filesystem (macFUSE, FUSE-T and the tools built on them, such as
    `bindfs`) and `nullfs` or `unionfs` at or above the walked root, and
    admits APFS, HFS and network filesystems under the same limit. A mount
    list that cannot be read or parsed refuses.

  So the guarantee that no backup copies a token holds for roots on local
  filesystems, bind mounts and overlays whose backing directories pass this
  check, with FUSE refused, and not for credential directories that a
  network or virtual filesystem exports back to the same host.
- The installed host's home module owns the rule and decides which paths each
  command checks. It checks before any token is written, any root is created
  or opened, and before `store adopt`, `store backup`, `store restore`,
  `config set` and every daemon or service start. Every command also refuses
  when any directory above a protected credential directory is a marked state
  root.
- The home module hands the checked protected directories and the exact roots
  it checked to the sign-in token store and its background refreshers. They
  repeat the same check on those paths immediately before every token write,
  never find a root of their own, and refuse a filesystem that changed after
  startup. The same handoff carries the session-bus address the Linux
  keyring needs, which the home module reads from the environment once, so
  the store never reads the environment; the separation check ignores it.
- A violation is refused as `auth_root_overlap`, naming where the root was
  chosen, before anything is written. A command exits `1`, as every refusal in
  this record does. `loopex daemon` exits with ADR 0071's existing `111`,
  `configuration_invalid`, so no new exit status is added. A command that
  cannot read a usable `HOME` cannot check the rule, so it refuses
  `home_unavailable` before touching a root. An ephemeral `ask`, which never
  selects a root, is unaffected.
- No file is excluded from ADR 0051's complete manifest, the ADC file
  included. A backup of a permitted root contains every file of that root,
  and, within the scope D21 states above, none of them can be a token.

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

None. Every cell is decided in the companion.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
