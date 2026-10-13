<a id="concept"></a>
## Concept

Technical depth: [Installed host configuration and path discovery](0037-host-configuration-and-path-discovery-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30; reconciled with the delivered M7 baseline on 2026-10-13; detailed for implementation on 2026-10-13; service command resolved from the escript's own location on 2026-10-13
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
5. **The service is asked for by name.** `--service` on `chat`, `run`,
   `resume`, `attach` and `sessions` names the selected home's service. The
   conversation, `run` and `resume` start it on demand; `attach` and
   `sessions` never do. `--daemon SOCKET` keeps its M7 meaning and never starts
   anything. Without either flag every command is the foreground or offline
   command it is today, whether or not a home exists.
6. **Starting on demand.** The starting command checks that every configured
   credential reference is present, without reading a value, and refuses by
   name before anything starts when one is absent. The service inherits that
   command's environment and runs detached from its terminal, so closing the
   terminal or interrupting the command does not stop it. It never prompts and
   leaves the workspace's project resources unadmitted, which its readiness
   report states. `loopex service start` at a terminal shows the project
   resources and asks, as the daemon does in the foreground today. Concurrent
   starts converge on one service through the existing placement lock.
7. **Readiness is reported as it is.** The running service answers one new
   query, `daemon.readiness`: serving; still classifying helper history, with
   ADR 0046's two counts; closed, with the session whose history could not be
   read; or unavailable, with a code and no session, which the service retries.
   The same answer carries the service's workspace, its project-resource
   admission and its version. A command that starts the service waits at most
   75 seconds for it to serve and otherwise reports the state it found.
8. **The ADR 0003 amendment is one module.** Only the installed reference
   host's home-discovery code reads `HOME`, and it passes absolute paths
   inward. Tests set `HOME` to a temporary directory.

This record introduces no second role or provider schema and fixes no
session's model at process launch. ADRs 0044, 0048 and 0049 govern committed
selection, custody and explicit configuration. File, keychain and command
credentials remain a separate future decision.

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
