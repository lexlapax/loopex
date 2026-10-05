<a id="technical-depth"></a>
## Technical depth

Concept: [Host configuration preparation](0050-host-configuration-preparation.md#concept).

<a id="technical-preparation"></a>
### Boundary and lifecycle

Concept: [Decision](0050-host-configuration-preparation.md#concept-preparation).

The callback is optional on the existing `Loopex.Model` behaviour:

```elixir
prepare_configuration(current_configuration, authored_changes,
                      immutable_definitions, context, options)
  :: {:ok, candidate_configuration} | {:error, reason}
```

No separate `configuration_preparation` runtime option or behaviour is added.
The existing private runtime model reference remains exactly `module`, `model`
and `options`. Core invokes the selected module with its existing keyword
options; a missing callback yields the existing unprepared-configuration refusal.
It never invokes `complete/3` as a fallback.

Current configuration and immutable definitions come from committed session
state. Authored changes use the existing internal six-field mutable allowlist.
Raw wire instructions contain exactly ADR 0042's `version`, `base`, `environment`
and `appendix`. The ingress decoder calls the existing pure `Instructions.capture/1`
before normalizing the command; that operation adds only its deterministic digest,
reads no files or environment and runs no host callback. The captured instruction
sections must remain exact. The existing five-field validator then applies.

The callback returns only the complete candidate. Core rederives it with
`SessionConfiguration.update/5` from the original normalized changes, returned
capabilities/mapping and immutable definitions, requiring exact candidate equality
before retained-history preflight. All non-model authored settings and explicit
origins remain unchanged; derived ceilings follow the existing resolution rules.
A different canonical model cannot replace the authored model after duplicate
lookup. Such an alias refuses through existing invalid-configuration admission;
clients use exact canonical model identifiers. The CLI's existing external alias
resolution still happens before its Core command identity is constructed.

The current eight-member `session_configuration_admitted_v1` record and normalized
command digest remain unchanged. Accepted instruction changes keep their existing
version/digest reference into the one retained candidate; replay reconstructs the
same captured command, checks its original digest and rederives the candidate
without Model or catalog access. Refusals retain their original normalized changes.
No second changes map, alias receipt, compatibility decoder or rewritten event is
introduced.

The candidate cannot contain host bindings, routes, credentials, handles, modules
or private catalog objects beyond the already approved bounded plain metadata.
Core reuses complete SessionConfiguration validation before admission.

The context contains exactly `deadline_monotonic_ms` and `cleanup_grace_ms`.
The deadline is the local monotonic millisecond time at worker start plus
60,000. It is private invocation context, never persisted or projected. Cleanup
grace is the retained session value. The session owner independently enforces
that cutoff; callback cooperation cannot extend it. Model module/options stay
private runtime configuration and do not enter informational runtime reads or Store.

Preparation order is attachment/controller authority, current owner, retained
command disposition or unknown fence, settledness, authored-change validation,
then host resolution. Replayed identical commands return their original fact;
changed-payload reuse refuses before catalog access. At most one preparation
is active per session. Conflicting mutations do not overtake it; status and
cancellation remain serviceable. Core binds a result to command identity,
owner/session epoch, original configuration version and immutable definitions.
It rechecks these before existing exact staging/history admission and the
single transaction. No worker writes a journal or publishes a durable event.

The worker and per-invocation callback-created work belong to one runtime-owned
group. Shared host catalog services retain the distinct lifetime described below.
Cancellation, caller or owner DOWN, runtime stop and cutoff retire and join the
group using retained cleanup bounds. Unjoined work makes cleanup uncertain and
cannot produce successful admission. Adapter exceptions, malformed returns and
private errors map to existing bounded refusal/error classes; raw terms never
enter public or diagnostic planes. A normal rejected candidate retains the
existing unchanged configure disposition. Owner loss follows existing fencing
and recovery rather than inventing a new committed rejection under an old owner.

Composition implements the callback on a Model wrapper that also delegates
`complete/3`. The wrapper retains two distinct private option sets: host resolution
inputs and the underlying adapter's original options. Completion forwards only
those original adapter options; wrapper keys cannot enter ReqLLM's closed option
grammar. This keeps dependency direction inward: composition may call
ProviderBindings and ReqLLM, while ReqLLM never depends on composition.

The wrapper uses `Edges.admitted_routes/1` with validated provider bindings or a
borrowed version-2 credential plane, requiring its explicit provider-name inventory.
The single-token `:legacy` result does not grant a route inventory and disables
unprepared configuration. This is capability absence, not a compatibility fallback.
No selected credential value is acquired or inspected. Host binding references
remain private options. Core never discovers providers or imports their adapters.

Composition reuses ProviderBindings and SessionConfiguration resolution. Cold
catalog loading retains the already accepted host-owned network/cache scope.
Pre-existing shared catalog services retain their host lifetimes; per-invocation
callback work must remain owned and joined. Cold-load contention spends the
captured preparation deadline, and an expired result cannot enter session truth.
Complete resolved plain metadata is committed with the candidate. Recovery never
reloads the catalog to reinterpret a committed configuration or frozen proposal.

Direction A would declare the same lifecycle on a separate behaviour and startup
option. The selected B extends Model conformance and uses the composition wrapper;
there is no new generic provider/configuration framework.

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

Required proof covers both supported toolchains and Model conformance: no
callback without authority or after a retained disposition; missing-callback or route-inventory refusal;
exact successful candidate and explicit/derived ceiling retention; stalled and
raising callbacks; deadline, caller/owner loss and runtime stop; descendant
joins; stale owner/version results; uncertain Store admission without repeated
resolution or publication; captured current restart/replay without the callback;
private canaries; and live foreground/daemon configure using admitted routes
with unchanged lease fencing and no provider dispatch during preparation.
Also prove identity-preserving preparation, alias refusal without rewritten
command facts, raw-instruction pure capture and exact duplicate replay, wrapper
option isolation and unchanged actual adapter completion. No test may accept a
canonicalized candidate under a different authored command digest. Independent
Node workflows remain part of the coordinated protocol join.
