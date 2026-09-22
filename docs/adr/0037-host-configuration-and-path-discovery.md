<a id="concept"></a>
## Concept

Technical depth: [Schema, precedence, provenance and write mechanics](0037-host-configuration-and-path-discovery-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-21
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0003](0003-extension-contract-boundary.md#concept) only
  its technical clause that no Loopex application reads a user home directory,
  narrowed as stated below; every other ADR 0003 clause stands, including that
  host policy owns the configuration naming extension sources
- **Prerequisite for:** M6 outcomes 2 and 4, accepted before the configuration
  layer, the default home or any `loopex config`, `paths`, `init` or `doctor`
  command is written

<a id="concept-adr-0037-decision"></a>
### Context and Decision

Technical depth: [Schema and precedence](0037-host-configuration-and-path-discovery-technical.md#technical-adr-0037-decision).

Loopex has no persisted host configuration, and that is partly deliberate.
`LoopexComposition.start/1` takes explicit per-instance options and requires
the caller to supply the state root, the workspace, the runtime identity and
the policy, with no defaults for any of them (`apps/loopex_composition/lib/loopex_composition.ex:122`);
root application configuration carries no runtime state. The state root is
read from exactly one process environment variable, `LOOPEX_HOME`, which is
required, has no default and is expanded only into a state root
(`apps/loopex/lib/loopex/session_directory.ex:98`,
`apps/loopex_app_server/lib/loopex_app_server/host.ex:153`). Every other
setting is a flag or an environment variable read at the command. An
installed product cannot ask an operator to re-derive that set at every
invocation, and it cannot let them guess which value is in effect.

**The decision.**

1. **The installed reference host resolves a documented default home,
   `~/.loopex` on Unix, and passes explicit absolute paths inward.** Core, the
   runtime and the reusable composition never discover a user home or a
   configuration location; they receive absolute paths as they do today.
   `LOOPEX_HOME` keeps its meaning as the state-root override, and
   `--state-root` overrides both. This is the narrow amendment to ADR 0003: the
   prohibition on reading a user home moves from every Loopex application to
   every application except the reference host's launcher and configuration
   layer, and tests and helpers still never point at a real one.
2. **One authored configuration file, one closed versioned schema.**
   `config.json` under the home carries non-secret host configuration in six
   domains: paths, daemon, runtime, providers, policy and diagnostics. Unknown
   fields refuse with an exact path; a missing schema version refuses; a
   version newer than the reader refuses with a named class. A provider
   profile names an adapter, a default model, optional role aliases such as
   `fast` or `capable` that the vision places in host configuration, and a
   credential reference; several profiles may be saved and one is selected.
3. **One precedence rule, stated once:** command flags, then named environment
   overrides, then the selected saved profile, then documented defaults that
   grant no authority. Policy and credentials have no permissive default: a
   saved policy applies only after the operator selected it explicitly, and a
   provider profile names a credential **reference**, never credential bytes.
   Two reference forms exist in `0.3.0`: an environment variable, and a file
   the operator protects, which the sender re-reads per invocation so that a
   rotated key needs no daemon restart. A command-form reference is a trust
   decision of its own and is recorded as open, not admitted here.
4. **Configuration is a typed pipeline, not a service.** Authored bytes are
   parsed and validated into a resolved configuration whose every value knows
   its origin; one runtime and provider profile is selected from it; that
   selection becomes the immutable composition options the existing
   composition already takes. There is no global configuration process,
   no hot reload and no in-place mutation: a change takes effect at the next
   daemon start, and `loopex daemon` says so when the file has changed under a
   running daemon.
5. **Writes are atomic and conservative.** `loopex init` and `loopex config
   set` write through a lock and an atomic replacement, keep the prior valid
   file when a write fails, and refuse to write a value the schema rejects.
6. **The effective configuration is inspectable.** `loopex config show
   --effective` prints every value with its origin; `loopex paths` prints every
   resolved path; credential references are shown as references and never
   resolved for display.
7. **Selection is per invocation, not per run.** `--provider NAME` selects a
   saved profile and `--role NAME` selects one of its aliases for one command;
   the model is fixed when the composition starts and does not change within
   a run. Live switching with continuation handling remains the vision's
   later reference-CLI flow and is not admitted here.

<a id="concept-adr-0037-consequences"></a>
### Observable Consequences

Technical depth: [Home layout and commands](0037-host-configuration-and-path-discovery-technical.md#technical-adr-0037-layout).

A first run on an empty machine works without exporting anything:
`loopex init` creates the home, writes a validated file with no provider and
no policy selected, or with the profile, credential reference and policy its
flags name, and `loopex doctor` says exactly what is missing and whether the
credential reference resolves, without printing it. A scripted or embedded
caller changes nothing: it still supplies absolute paths and receives no
defaults. The released offline commands keep reading
`LOOPEX_HOME` and flags exactly as today when a home has not been initialized;
the default home is consulted only when neither override is present.

Workspace remains an invocation input and is never persisted. Project-local
configuration is not admitted: Loopex has no project-trust rule yet, and the
M3 project-resource decision is the only place project bytes reach the model,
by explicit choice at the terminal. That decision is the intended basis for
the project-trust rule a later release needs before a workspace file may
influence configuration.

<a id="concept-adr-0037-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics and rejected alternatives](0037-host-configuration-and-path-discovery-technical.md#technical-adr-0037-compatibility).

The schema is experimental under the 0.x policy and versioned from its first
byte, so a later minor release may change it with a migration note. Nothing in
the file is durable session truth; deleting it loses saved profiles and
nothing else, which is the rollback. Credential bytes are excluded by
construction; a persistent credential store is a separate trust decision this
pair does not make and M6 does not need.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
