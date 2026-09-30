<a id="technical-depth"></a>
## Technical depth

Concept: [Host provider routing and credential bindings](0048-host-provider-routing-and-credential-bindings.md#concept).

<a id="technical-adr-0048-decision"></a>
### Contract

Concept: [Context and decision](0048-host-provider-routing-and-credential-bindings.md#concept-adr-0048-decision).

**Exact amendment boundary.** ADR 0034 Concept's composition-bound reference
becomes one reference per admitted provider. Its Technical "Adapter / core
selection seam" and single-provider scope become immutable route selection
through `complete(request, options, progress)`: the request names its committed
exact model, composition options carry the host routing table. No credential
channel is added to core or to per-call model data. ADR 0039's provider-name table
also permits an explicit host-selected environment-variable name, validated as
`[A-Za-z_][A-Za-z0-9_]{0,127}`; existing provider-specific defaults remain for
existing callers.

Admit at most 16 provider bindings. Provider keys match the adapter's supported
provider catalog without creating atoms from input. Each binding is a host-only
reference. The canonical request remains plain model/reasoning/configuration
identity; it contains no env name, route token, registry PID or role alias.
Require the configured model's provider to match its binding. No duplicate
provider route or ambiguous alias is admitted.

**Durable custody.** Host bootstrap resolves all configured credential references
into separately owned custody, creates composition-bound tokens and removes
those named values from the Loopex-owned host environment before resource/tool
subprocess launch, as the existing durable path does for
`LOOPEX_PROVIDER_API_KEY`. Every configured name participates in the exclusion
set at each owned launch boundary, including project-resource loaders. Never
log a value or read it in the adapter. Deduplicate shared env names before
resolution/deletion; a missing value fails the startup transaction and cleans
up every custody already created. This does not erase copies held by the
invoking shell or other host code.

After the selected provider companion is ready, the excluded sender obtains
only that binding's selected key from custody and transfers it on the existing
private bootstrap frame. One binding's loss refuses its dispatch; it cannot
select another token. Trace exclusions cover all custodies, senders and
credential-bearing provider subprocesses. Startup/stop failures clean all
partially admitted bindings.

**Ephemeral references.** Composition validates only the selected provider and
reference form. Its sensitive caller resolves the chosen variable for that
invocation, validates the existing 1–65,536-byte value bound, uses it and proves
caller/tagged-pool cleanup as ADR 0039 requires. Ambient authorized host tools
may still read environment values; this amendment adds no structural secrecy
claim from them. Keep the selected-value reply guard and diagnostic exclusions.
Do not delete ambient variables through the durable loader in this profile.

**Admission and recovery.** Validate a model/reasoning switch against admitted
routes, capabilities and projected byte/token budgets before its config commit.
A refusal leaves the prior configuration. Resume requires the route for the
committed model and unresolved staged invocations. A pending attempt keeps its
original model/configuration/digest; a new default cannot redirect it. Role
snapshots retain provider identity, never credential bytes. Rotation takes an
explicit host restart/rebinding in M7; no live refresh watcher is added.

<a id="technical-adr-0048-evidence"></a>
### Evidence

Concept: [Observable consequences](0048-host-provider-routing-and-credential-bindings.md#concept-adr-0048-consequences).

- Two credential canaries and interleaved independent sessions prove selected
  binding isolation, no unselected-token resolution and no key in durable/public
  planes, jobs, diagnostics or resource subprocess environments.
- Partial bootstrap, missing env value/custody, wrong provider and unknown model
  refuse without fallback or leaked custody; existing teardown tests run for
  every admitted binding.
- Durable and ephemeral environment-lifetime tests remain distinct.
- Restart before/after configure and staged intent retains exact dispatch identity.
- Real A→B→A with canonical tool history, and parent A/helper B, both succeed.
- Registry loss, bootstrap timeout, cancellation and trace-canary tests retain
  the accepted profile-specific cleanup guarantees.

<a id="technical-adr-0048-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0048-host-provider-routing-and-credential-bindings.md#concept-adr-0048-compatibility).

The two superseded restrictions must be named in the eventual acceptance
record and ADR index; accepted source files remain historical. Same-provider
multi-account routing, endpoint configuration, typed binding records from
ADR 0035, file credentials and live rotation are deferred. No new source copy
or Pi dependency is involved.
