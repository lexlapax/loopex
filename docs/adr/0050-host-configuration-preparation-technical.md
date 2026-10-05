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

The callback returns only the complete candidate. Core retains the original
normalized authored changes and verifies the returned candidate using the pure
[alias-binding rule](#technical-alias-identity) below, before retained-history
preflight. All non-model authored settings and explicit origins remain unchanged;
derived ceilings follow the existing resolution rules. Model aliases use the
host's existing ProviderBindings resolution; no new alias registry or runtime
catalog is added.

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

<a id="technical-alias-identity"></a>
### Alias binding and replay

Concept: [Authored identity and retained resolution](0050-host-configuration-preparation.md#concept-alias-identity).

The current private record becomes `session_configuration_admitted_v2`. Its
closed eight-member shape is:

```text
kind: "session_configuration_admitted_v2"
command_type: "configure"
command_id
command_digest
admission
changes
prior_configuration_version
configuration
```

`changes` retains normalized authored input, including the exact model alias.
Compute `command_digest` from the existing deterministic preimage
`["loopex_command_v1", normalized_authored_command]`; never substitute the
canonical model into that preimage. Accepted instruction changes retain their
existing version/digest descriptor into the single candidate. Reconstruct their
full captured envelope from that candidate before verifying the authored digest.
A refusal retains its authored changes and has `configuration: nil`, preserving
the existing refusal grammar and semantics.

For accepted admission and replay, let A be reconstructed authored changes, C
the candidate and P the prior committed configuration:

1. Validate A with the existing six-field mutable allowlist.
2. If A explicitly contains `model`, derive effective changes by replacing only
   that member with C's canonical `model`.
3. If A omits `model`, require C's model to equal P's model. Omission cannot
   refresh or retarget it.
4. Require exact equality between C and
   `SessionConfiguration.update(P, effective_changes, C.model_capabilities,
   C.provider_mapping, immutable_definitions)`.
5. Preserve settledness, prior-version equality, complete retained-history and
   request preflight, source-bound metadata ceilings, origin rules and public
   projection validation.

The complete OwnerLane transaction binds authored changes to the full candidate.
The retained model binding is A's `model` to C's `model`; no second changes map,
alias receipt or callback return tuple is necessary. Alias resolution is a
trusted host capture. Pure recovery verifies that retained binding and the
complete candidate; it does not prove that today's catalog would resolve the
alias identically. Model requests use only the canonical captured configuration.
The candidate cannot rewrite any other authored setting.

Normalize and digest authored input before preparation. An identical retained
command returns its original accepted/refused disposition before invoking a
callback or catalog. Changed authored payload returns `idempotency_conflict`.
Alias and canonical spellings conflict under the same command ID even when they
resolve identically. A fresh command ID may capture a different resolution after
catalog drift. Unknown admission retains the original complete proposal,
transaction ID and digest; never resolve again or rebuild its candidate.

The existing prepared-candidate facade uses the same pure rule. Externally
prepared alias commands gain support without another argument; canonical
callers retain their semantics. Duplicate lookup ignores a replacement candidate.
CLI preparation must preserve its authored changes while using canonical
changes internally to construct C. Native, foreground and daemon ingress share
this contract. Public configured events and snapshots remain canonical and
unchanged.

Replace all configure-v1 writer and readers together, including recovery and
effect-index readers. Refuse `session_configuration_admitted_v1`; do not keep a
compatibility reader, migrate roots or rewrite existing journals. This version
change identifies the new persistent model-identity relationship. Current v2
replay, owner restart and exact unknown-commit recovery remain required.

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
Also prove authored-alias/canonical-candidate records and independent digest
vectors; alias versus canonical duplicate conflicts; catalog drift with an
identical duplicate versus a fresh ID; accepted/refused v2 replay without the
callback; omitted-model retarget and non-model rewrite refusal; instruction
reconstruction and pure raw capture; canonical and alias prepared callers;
unknown-commit exact re-presentation without another resolver call; v1 refusal;
wrapper option isolation and unchanged actual adapter completion. No test may
substitute canonical changes into the authored command digest. Independent Node
workflows remain part of the coordinated protocol join.
