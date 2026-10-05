<a id="technical-depth"></a>
## Technical depth

Concept: [Host configuration preparation](0050-host-configuration-preparation.md#concept).

<a id="technical-preparation"></a>
### Boundary and lifecycle

Concept: [Decision](0050-host-configuration-preparation.md#concept-preparation).

Proposed startup option:

```elixir
configuration_preparation: %{module: module, options: keyword()}
```

Proposed callback on a separate Core-owned behaviour:

```elixir
prepare_configuration(current_configuration, authored_changes,
                      immutable_definitions, context, options)
  :: {:ok, canonical_changes, candidate_configuration} | {:error, reason}
```

Current configuration and immutable definitions come from committed session
state. Authored changes use the existing internal six-field mutable allowlist;
raw wire instructions must first be captured through ADR 0042's four-field
input grammar. The callback cannot change immutable definitions or return host
bindings, routes, credentials, handles, modules or private catalog objects in
its changes or candidate. Core reuses bounded plain-data and complete
SessionConfiguration validation before admission.

The context contains exactly `deadline_monotonic_ms` and `cleanup_grace_ms`.
The deadline is the local monotonic millisecond time at worker start plus
60,000. It is private invocation context, never persisted or projected. Cleanup
grace is the retained session value. The session owner independently enforces
that cutoff; callback cooperation cannot extend it. Module/options stay private
runtime configuration and do not enter informational runtime reads or Store.

Preparation order is attachment/controller authority, current owner, retained
command disposition or unknown fence, settledness, authored-change validation,
then host resolution. Replayed identical commands return their original fact;
changed-payload reuse refuses before catalog access. At most one preparation
is active per session. Conflicting mutations do not overtake it; status and
cancellation remain serviceable. Core binds a result to command identity,
owner/session epoch, original configuration version and immutable definitions.
It rechecks these before existing exact staging/history admission and the
single transaction. No worker writes a journal or publishes a durable event.

The worker and any callback-created work belong to one runtime-owned group.
Cancellation, caller or owner DOWN, runtime stop and cutoff retire and join the
group using retained cleanup bounds. Unjoined work makes cleanup uncertain and
cannot produce successful admission. Adapter exceptions, malformed returns and
private errors map to existing bounded refusal/error classes; raw terms never
enter public or diagnostic planes. A normal rejected candidate retains the
existing unchanged configure disposition. Owner loss follows existing fencing
and recovery rather than inventing a new committed rejection under an old owner.

Composition reuses ProviderBindings and SessionConfiguration resolution with
admitted provider names. It needs no credential lookup. Cold catalog loading
retains the already accepted host-owned network/cache scope. Complete resolved
plain metadata is committed with the candidate. Recovery never reloads the
catalog to reinterpret a committed configuration or frozen proposal.

Choice B uses this same lifecycle and validation but declares the optional
callback on Loopex.Model and supplies its existing private options. That reduces
startup plumbing while making model completion adapters responsible for host
configuration preparation. It requires Model conformance and adapter changes;
A requires separate port conformance and composition lifecycle changes.

<a id="technical-contract-impact"></a>
### Evidence and proof

Concept: [Contract impact and verification](0050-host-configuration-preparation.md#concept-contract-impact).

Current source evidence:

- `ChatConfiguration.update/2` prepares externally using ProviderBindings and
  then the approved `Loopex.command_with_configuration/3` facade.
- `SessionConfiguration.resolve/4` and `update/5` validate pure supplied facts;
  neither discovers host model metadata or admitted routes.
- `Runtime.configuration/1` excludes creation captures and private host facts.
- `prepared_session_configuration/1` is restricted to an unspent resume
  capability; it is not a live attachment read.
- SessionCoordinator currently accepts commands through an infinite caller
  wait and synchronous owner admission. The new 60,000-ms preparation cutoff
  is proposed here, not claimed as an existing timeout.
- Foreground Stdio and daemon collaboration contexts receive runtime identity;
  they do not hold ProviderBindings or a configuration resolver.

Required proof covers both supported toolchains and port conformance: no
callback without authority or after a retained disposition; absent-port refusal;
exact successful candidate and explicit/derived ceiling retention; stalled and
raising callbacks; deadline, caller/owner loss and runtime stop; descendant
joins; stale owner/version results; uncertain Store admission without repeated
resolution or publication; captured current restart/replay without the port;
private canaries; and live foreground/daemon configure using admitted routes
with unchanged lease fencing and no provider dispatch during preparation.
Independent Node workflows remain part of the coordinated protocol join.
