<a id="technical-depth"></a>
## Technical depth

Concept: [Host configuration and path discovery](0037-host-configuration-and-path-discovery.md#concept).

<a id="technical-adr-0037-decision"></a>
### Schema and Precedence

Concept: [Context and decision](0037-host-configuration-and-path-discovery.md#concept-adr-0037-decision).

**Where the layer lives.** In the reference host, beside the launcher and the
command grammar in `apps/loopex_cli`, as one module family that owns reading,
validating, resolving and writing the file. Nothing under `apps/loopex`,
`apps/loopex_composition` or any store, model or executor application reads
the file or the home. The composition keeps its required options and its
refusal of defaults; the configuration layer's last step produces exactly the
keyword list `LoopexComposition.start/1` validates today, so a configured start
and an explicit embedded start take the same path from that point.

**The file.** `config.json`, UTF-8, one JSON object, closed at every level:

| Domain | Keys | Type and rule |
| --- | --- | --- |
| `schema_version` | — | Integer, `1` for `0.3.0`; a newer value refuses `config_version_unsupported` |
| `paths` | `state_root`, `socket`, `diagnostics` | Absolute paths after expansion; `socket` defaults inside the daemon's `daemon/` subdirectory of the root as ADR 0032 fixes, and a value outside the root is refused as ADR 0032 already requires |
| `daemon` | `drain_budget_ms`, `attachments_per_session`, `attachments_per_daemon` | Integers within the bounds ADR 0032 names; each defaults to the accepted M5 value |
| `runtime` | `context_budget`, `cleanup_grace_ms` | Integers within the bounds the runtime already validates |
| `providers` | A map of profile name to `{adapter, model, endpoint, credential, options}` | `adapter` is a closed enumeration of the adapters in the release; `credential` is a reference of the form `{"env": "NAME"}` and nothing else in `0.3.0`; `options` is the adapter's own closed keyword set, never an open bag |
| `policy` | `profile`, `options` | `profile` is a closed enumeration of the host policies the release ships; absent means no policy and every run refuses until one is chosen |
| `diagnostics` | `trace`, `limits` | Boolean and the bounded limits ADR 0030 names |
| `selected` | `provider`, `policy` | The names in effect when no flag or environment override is present |

Unknown keys refuse with the JSON pointer of the offending member. Every
refusal is one line on standard error with a stable class and the path.

**Precedence, applied per value.**

```text
--flag value          origin: flag
LOOPEX_<DOMAIN>_<KEY> origin: env      (the closed set the companion lists)
config.json           origin: file <path>#<pointer>
documented default    origin: default  (never for policy or a credential)
```

`LOOPEX_HOME` is the `paths.state_root` environment override and keeps that
name for compatibility. `--state-root` is its flag. The default home is
`$HOME/.loopex` resolved by the launcher from the process environment once,
and is refused if `HOME` is unset or relative; there is no other discovery, no
XDG lookup and no search path.

**Resolution pipeline.**

```text
authored bytes
  -> parse (closed JSON, size ceiling 256 KiB)
  -> validate against schema_version
  -> resolve: for each key, first defined source in precedence order,
     recording origin; expand paths; refuse relative results
  -> select: one provider profile and one policy profile by name
  -> compose: LoopexComposition options, plus the daemon and CLI options
     M5 defined, as an immutable keyword list
```

The resolved configuration is a plain map that carries no PIDs, functions or
atoms from input; profile and adapter names are matched against closed
enumerations before any atom exists.

<a id="technical-adr-0037-layout"></a>
### Home Layout and Commands

Concept: [Observable consequences](0037-host-configuration-and-path-discovery.md#concept-adr-0037-consequences).

```text
~/.loopex/
  config.json        authored, non-secret host configuration
  <state data>       the store-owned state root contents, unchanged in shape
  artifacts/         the existing content-addressed artifact store
  daemon/            the M5 daemon's 0700 directory: socket, index
  logs/              bounded, redacted diagnostics the daemon writes
  cache/             disposable material; safe to delete at any time
```

The state root is the home itself unless `paths.state_root` says otherwise, so
an operator who already exported `LOOPEX_HOME="$HOME/.loopex"` as the
app-server guide shows finds the same root. The exact data layout under the
root is the store adapter's and follows ADR 0036.

| Command | Effect |
| --- | --- |
| `loopex init [--home DIR]` | Creates the home `0700`, writes a minimal valid `config.json` with no provider and no policy selected, prints the path; refuses an existing file |
| `loopex config show [--effective]` | Prints the authored file, or every effective value with its origin; credential references print as references |
| `loopex config set <pointer> <value>` | Validates the whole resulting document before writing; atomic replacement under a lock file beside `config.json` |
| `loopex config validate [FILE]` | Exit `0` or one refusal line per error |
| `loopex paths` | Every resolved path and its origin |
| `loopex doctor` | The M6 diagnostic: home, file validity, selected profiles, credential reference resolvable or not, store format and pending migration, daemon status, release version and platform |

**Atomic write.** Write to `config.json.<random>` in the same directory, `fsync`,
rename over the target, `fsync` the directory. The lock is an exclusive
`O_EXCL` file that records the writer's OS pid and is reclaimed only when
that pid is gone, the same rule the placement lock uses. A failed write
leaves the prior file untouched and removes its temporary.

<a id="technical-adr-0037-compatibility"></a>
### Compatibility Mechanics and Rejected Alternatives

Concept: [Compatibility and rollback](0037-host-configuration-and-path-discovery.md#concept-adr-0037-compatibility).

**ADR 0003, the exact change.** Its technical clause 5 reads "No Loopex
application reads a user home directory, and no test or helper may point at a
real one" (`0003-extension-contract-boundary-technical.md:53`). After
acceptance it reads: "No Loopex application other than the reference host's
launcher and configuration layer reads a user home directory; that layer
resolves its documented default home and passes explicit absolute paths
inward; no test or helper may point at a real one." The first sentence of the
clause, that host policy owns the configuration naming sources, is unchanged,
and this pair adds no extension-source configuration.

**Compatibility.** The schema is a new experimental surface, versioned by
`schema_version`. `0.3.0` reads version `1` only. A later minor release that
changes it ships a migration note and a reader for the previous version.
Environment variable names that exist today keep their meaning; new ones are
enumerated in the companion's closed set and nowhere else.

**Rollback.** Delete `config.json`; every command returns to the released
flag-and-environment behaviour. No durable session truth lives in the file.

**Rejected alternatives.**

- *A global configuration process or application environment* would create a
  singleton authority the vision's per-runtime ownership rule forbids and would
  hide per-runtime state in global names.
- *YAML with layered `.env` files* accumulates precedence exceptions; one file,
  one closed schema and one rule are smaller.
- *Persisting credential bytes* is excluded by the vision's credential rule; a
  future OS-backed secret store is its own trust decision.
- *Project-local configuration* waits on a project-trust rule.
- *Hot reload* adds a mutable path into a running composition for no M6
  outcome.
- *XDG base directories* add a search path and a second answer to "where is my
  configuration"; one default and two explicit overrides are enough.
