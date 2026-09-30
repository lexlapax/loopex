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
This also amends ADR 0019's sole-source sentence and ADR 0039's explicit
preservation of that restriction for durable use. The accepted source files
remain historical; their security/cleanup claims are otherwise unchanged.

Validate the complete name set before any environment read or deletion. Reject
operational variables `PATH`, `HOME`, `TMPDIR`, `TMP`, `TEMP`, `SHELL`, `USER`,
`LOGNAME`, `PWD`, `OLDPWD`, `SHLVL`, `IFS`, `CDPATH`, `ENV`, `BASH_ENV`, `ZDOTDIR`
and prefixes `LD_`, `DYLD_`, `ERL_`, `ELIXIR_`, `MIX_`, `RELEASE_`, `BASH_`,
`LOOPEX_`, except the existing `LOOPEX_PROVIDER_API_KEY`. These names control
launch/runtime/resource behavior and cannot be repurposed as credential slots.
Validation failure leaves the environment untouched. Host adapters may further
narrow allowed credential names; no config field can bypass the exclusions.

A binding is either `credential: {env: NAME}` for a credentialed route or
`credential: {none: true}` for an already-supported credential-free ephemeral
route. The alternatives are exclusive. Credential-free bindings create no
custody or env read and never fall back to ambient keys. Durable composition
rejects unsupported local routes before startup; preserve the existing ephemeral
Ollama default and its caller-supplied configuration contract.

Admit at most 16 provider bindings. Provider keys match the adapter's supported
provider catalog without creating atoms from input. Each binding is a host-only
reference. The canonical request remains plain model/reasoning/configuration
identity; it contains no env name, route token, registry PID or role alias.
Require the configured model's provider to match its binding. No duplicate
provider route or ambiguous alias is admitted.

**Composition contract.** Add the explicit `:provider_bindings` startup option
to durable and ephemeral composition. Its closed provider-name map uses the
binding alternatives above and is validated before effects. Legacy callers
omitting it retain their documented single-route defaults. A supplied map
admits only its named routes; no default route is silently added. CLI chat,
foreground app-server and daemon composition use this same map through explicit
programmatic host options. Only chat/config gain ADR 0049's file grammar in M7;
the existing app-server/daemon CLI commands retain their single-route defaults
and gain no implicit file loader. Remote session commands cannot mutate it.
Effective inspection reports configured provider identities and reference-form
validity, never credential availability, environment name or value. It reads no
environment values and does not probe custody.

The new host-private credential plane has closed shape
`{version: 2, capability, model_options, excluded_env_names}` with optional
`capability_pid` as in the existing host-owned plane. `model_options` contains
exactly `provider_routes`, `credential_registry`, `tracing_capability`.
`provider_routes` maps at most 16 admitted provider names to validated opaque
credential tokens; every token resolves in that exact validated registry and
the tracing capability equals the plane capability. The sorted unique
`excluded_env_names` is the union of the existing legacy exclusion set and
validated configured credential names. With the existing single-name set it
contains at most 17 names. It is passed only to trusted owned-launch adapters, never core
requests, executor jobs, journals or diagnostics. Preserve the existing
unversioned single-token plane as a separate validated legacy branch, with its
original exclusion set. Unknown fields, mixed branches and missing tokens
refuse before any runtime or subprocess starts. Ephemeral composition stores
only references and uses its selected caller resolution below, never this
durable custody plane.
Supplying both `:provider_bindings` and `:credential_plane` is conflicting
configuration and refuses before effects. Daemon startup also rejects simultaneous
value-bearing `:credential` and `:provider_bindings` before environment reads,
deletions or custody creation; its legacy credential branch remains separate. A borrowing host validates its file
and bindings once when opening custody. For each temporary or main composition,
`CredentialHost.plane/1` lends the same route tokens/registry and exclusion set
with a fresh runtime-specific tracing capability. Never reuse a capability
already bound to another runtime. The plane supplies immutable route and
exclusion sets. Borrowing never resolves environment variables again or adds
default routes. Validate every supplied plane before starting owned edges.

**Durable custody.** One private composition-owned binding resolver supplies
complete-name validation, unique-name resolution/deletion, custody registration
and partial-start cleanup to CredentialHost, direct composition and daemon
bootstrap. Preserve each opener's process ownership and error boundary; validate
the whole binding set before environment effects. Ephemeral reference resolution
retains its separate caller-only lifetime and does not use this durable loader.
Host bootstrap resolves all configured credential references
into separately owned custody, creates composition-bound tokens and removes
those named values from the Loopex-owned host environment before resource/tool
subprocess launch, as the existing durable path does for
`LOOPEX_PROVIDER_API_KEY`. Every configured name participates in the exclusion
set at each owned launch boundary, including project-resource loaders. Never
log a value or read it in the adapter. Deduplicate shared env names before
resolution/deletion; a missing value fails the startup transaction and cleans
up every custody already created. This does not erase copies held by the
invoking shell or other host code.
Preserve existing exclusion behavior too: if the legacy credential name is
not a configured route, remove it without reading or admitting its value.
CLI chat reaches validated binding resolution before the general early legacy
credential discard. Non-composing inspection remains free of credential reads;
the durable resolver performs unread legacy deletion when that name is not a
configured route.

After the selected provider companion is ready, the excluded sender obtains
only that binding's selected key from custody and transfers it on the existing
private bootstrap frame. One binding's loss refuses its dispatch; it cannot
select another token. Trace exclusions cover all custodies, senders and
credential-bearing provider subprocesses. Startup/stop failures clean all
partially admitted bindings.
Update `CredentialHost`, `CredentialPlane`, composition `Edges` validation,
the durable option parser, CLI recovery's temporary/main runtime handoff,
daemon startup, the Local executor environment builder and resource-launch
environment builder together. Both temporary and main runtimes borrow the
same host custody with distinct trace capabilities; a second runtime must not
reread a deleted environment key.
Local receipts retain their existing `provider_credential_present` meaning
for the legacy selected variable. Do not reinterpret an old false value as
proof about every M7 binding. The additional exclusion guarantee is proved at
the configured launch boundaries with all admitted canaries; this proposal
adds no credential names to receipts or new receipt field.

**Ephemeral references.** Configuration validates admitted provider/reference
forms without reading values. An invocation resolves only its selected route;
credential-free routes bypass resolution. Its sensitive caller resolves the chosen variable for that
invocation, validates the existing 1–65,536-byte value bound, uses it and proves
caller/tagged-pool cleanup as ADR 0039 requires. Ambient authorized host tools
may still read environment values; this amendment adds no structural secrecy
claim from them. Keep the selected-value reply guard and diagnostic exclusions.
Do not delete ambient variables through the durable loader in this profile.
The existing closed ephemeral option validator admits `:provider_bindings`
under the same grammar. Binding maps, environment names and opaque handles
are removed from public configuration/status views; the exact selected model
continues to be public. Host authorization of a variable name does not verify
the provider account behind its value; authentication failure has no fallback.

**Admission and recovery.** Validate a model/reasoning switch against admitted
routes, capabilities and projected byte/token budgets before its config commit.
A refusal leaves the prior configuration. Resume requires the route for the
committed model and unresolved staged invocations. A pending attempt keeps its
original model/configuration/digest; a new default cannot redirect it. Role
snapshots retain provider identity, never credential bytes. Rotation takes an
explicit host restart/rebinding in M7; no live refresh watcher is added.
The same dispatch rules apply to ADR 0043's separately configured maintenance
model. Composition validates its admitted route before startup. Each admitted
episode freezes that exact model; recovery of a required invocation uses its
provider binding even when the current maintenance option changed or is absent.
Missing custody/route or renderer refuses without switching to the parent model.
An already settled summary needs no new provider dispatch to finish its checkpoint.

<a id="technical-adr-0048-evidence"></a>
### Evidence

Concept: [Observable consequences](0048-host-provider-routing-and-credential-bindings.md#concept-adr-0048-consequences).

- All three durable openers share reserved-name, duplicate-name, partial-bootstrap
  and cleanup vectors. Conflicting daemon credential sources refuse before
  effects. A built CLI chat using the legacy name resolves it once rather than
  deleting it before dispatch; inspection reads no selected value.
- Two credential canaries and interleaved independent sessions prove selected
  binding isolation, no unselected custody resolution during dispatch and no key in durable/public
  planes, jobs, diagnostics or resource subprocess environments.
- Partial bootstrap, missing env value/custody, wrong provider and unknown model
  refuse without fallback or leaked custody; existing teardown tests run for
  every admitted binding.
- Durable and ephemeral environment-lifetime tests remain distinct. Reserved
  names fail before reads/deletions; credential-free ephemeral calls read no key.
  Bootstrap deliberately resolves all configured credentialed bindings.
- Restart before/after configure and staged intent retains exact dispatch identity.
- Real A→B→A with canonical tool history, and parent A/helper B, both succeed.
  A and B have different admitted provider-route prefixes; this is not a
  cross-model-vendor requirement. Before the first attempt, pin B's exact model,
  mapping/renderer revisions and credential reference under the plan's immutable
  pin rule. The phase-2 provider workstream owns B's conformance, including
  explicit disabled thinking for its summarizer use, unchanged reply ceiling,
  canonical history rendering and selected-route isolation.
- Real conversation A/summarizer B uses the selected route, counts maintenance
  usage once in parent/standalone totals and exposes no credential references.
  Changed/absent startup selections, lost B custody and rebinding the same B
  provider preserve the captured request identity and cleanup guarantees.
- Registry loss, bootstrap timeout, cancellation and trace-canary tests retain
  the accepted profile-specific cleanup guarantees.

<a id="technical-adr-0048-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0048-host-provider-routing-and-credential-bindings.md#concept-adr-0048-compatibility).

The named superseded restrictions must appear in the eventual acceptance
record and ADR index; accepted source files remain historical. Same-provider
multi-account routing, endpoint configuration, typed binding records from
ADR 0035, file credentials and live rotation are deferred. No new source copy
or Pi dependency is involved.
