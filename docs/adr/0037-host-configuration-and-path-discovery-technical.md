<a id="technical-depth"></a>
## Technical depth

Concept: [Installed host configuration and path discovery](0037-host-configuration-and-path-discovery.md#concept).

<a id="technical-adr-0037-decision"></a>
### Contract

Concept: [Context and decision](0037-host-configuration-and-path-discovery.md#concept-adr-0037-decision).

The installed CLI adds discovery around ADR 0049's existing reader. Explicit
`--config FILE` wins over the default home's `config.json`. Resolve a Unix home
from absolute `HOME` once, then `.loopex`; refuse absent/relative home. Retain
`--state-root` > `LOOPEX_HOME` > file state root > installed home for state
placement. Configuration selection and state-root selection are separate.
No project search, XDG search, interpolation or hot reload is proposed.

The home contains config plus the store-owned state root, existing artifacts,
M5 daemon directory and bounded diagnostics. Any final layout must respect the
then-current store format and socket placement rules; no new core global state.
Reuse role snapshots, immutable run configuration and env-only provider custody.
`config show` and `paths` inspect references without resolving credentials;
`doctor` reports reference availability only, never values.

Candidate commands extend the M7 parser: `init`, `config set`, `paths`, `doctor`
and installed daemon lifecycle commands. Before M8 acceptance, freeze exact
syntax, defaults and supported previous artifacts against its delivered baseline.
`init` refuses an existing config, validates before writing and writes no secret.
A configuration update validates the whole resulting document. Write an exclusive
temporary in the same directory, fsync, rename and fsync the directory. Use a
single owner lock with explicit stale-lock recovery; PID existence alone is not
proof against PID reuse. A failed update leaves prior bytes unchanged.

The narrow ADR 0003 amendment permits only the installed reference host's
launcher/configuration layer to read the user's home and pass explicit absolute
paths inward. All tests/helpers still use temporary homes. No other application
or adapter receives discovery authority. Extension-source admission is unchanged.

<a id="technical-adr-0037-evidence"></a>
### Evidence

Concept: [Observable consequences](0037-host-configuration-and-path-discovery.md#concept-adr-0037-consequences).

M8 must prove explicit versus discovered configuration equivalence, origin
reporting, temporary-home isolation, atomic update crash cuts, stale-lock refusal,
missing provider/policy refusal and no credential read during inspection. Its
operator demonstration uses the actual installed artifact and matching rollback
artifact. M7 does not claim these outcomes.

<a id="technical-adr-0037-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0037-host-configuration-and-path-discovery.md#concept-adr-0037-compatibility).

One JSON schema and resolver is preferred to a second installed configuration
system. Installation, default home and management do not alter committed session
settings. Provider file credentials and live rotation remain separately scoped.
Do not promise a released old reader recognizes future records or new error
classes; prove the exact binary/record combinations in the successor plan.
