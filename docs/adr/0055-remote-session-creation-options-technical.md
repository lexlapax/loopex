<a id="technical-depth"></a>
## Technical depth

Concept: [Remote session creation options](0055-remote-session-creation-options.md#concept).

<a id="technical-purpose"></a>
### Authority and current evidence

Concept: [Purpose and scope](0055-remote-session-creation-options.md#concept-purpose).

The accepted [M7 protocol inventory](../plans/M7-technical.md#technical-plan-prerequisites)
requires versioned `session.create` options for resolved configuration,
instructions and immutable selections. ADRs [0042](0042-host-composed-instructions-technical.md#technical-depth),
[0044](0044-run-model-and-reasoning-configuration-technical.md#technical-depth),
[0049](0049-explicit-host-configuration-technical.md#technical-depth) and
[0050](0050-host-configuration-preparation-technical.md#technical-depth) constrain
capture, budgets, host authority and preparation. ADR 0050 expressly leaves the
complete remote creation grammar undecided.

Source evidence is base `4ee52100dbe6a532f8cf83fa250c1f4c6b52c66d`:

| Boundary | Existing evidence and required change |
| --- | --- |
| `LoopexAppServer.Mapping.session_options/1`; `LoopexDaemon.Request.parse_method/2` | Currently accept a plain options map without this member grammar. Both must use the same closed decoder. |
| `Runtime.SessionGenesis.resolve/2`, `normalize/1` | Complete `session_genesis_v3` already captures normalized options, initial configuration, tool definitions/names, derived artifact-read binding, runtime cleanup and policy-defer mode; whole record costs at most 65,536 canonical bytes. Reuse this format. |
| `SessionConfiguration.update/5`, `validate_candidate/4` | Pure next-version algebra and exact authored/canonical candidate verification; creation needs the explicit rebase below. |
| `Runtime.Instructions.capture/1` | Pure exact four-section input, five-member retained capture and deterministic digest; no filesystem or environment reads. |
| `Composition.DurableOptions.capture_defaults/1`; `ProviderBindings` | Host-owned baseline, definitions, names, physical workspace and admitted provider routes. A remote caller cannot supply their private inputs. |
| `Runtime.Control.create_session/6`, `validate_fresh_selection/3` | Serial exact create writer; current fresh model equality to startup model needs the narrow trusted prepared-creation path below. |
| `Store.create_session/3`, `runtime_command/2`, `creation_provenance/3`, `load_records/4` | Existing exact transaction, key absence, bounded provenance and genesis-history read support pre-resolution replay without another Store callback. |

This proposal changes the remote input contract and initial preparation scope.
It does not add a Model callback, Store callback, port, record kind, credential
route, instruction renderer, tool registry, alias registry or creation provenance
schema. The native explicitly supplied complete-genesis facade remains a
host-authorized boundary; decoding remote fields never grants its authority.

<a id="technical-options"></a>
### Closed input and capture

Concept: [Recommended options](0055-remote-session-creation-options.md#concept-options).

In foreground `loopex.experimental/3` and daemon `loopex.experimental/4`, a create
request has exactly `request_id`, `method`, `command_id`, `session_options`.
`method` is `session.create`. Existing request/command identity encodings and
connection/controller authorization apply; creation adds no session ID,
attachment token or writer epoch. This ADR changes only the options member and
its admitted creation semantics, not the existing admission/result envelope.

The options object has required `version` and only these optional members:

| Member | Wire domain | Omission and normalization |
| --- | --- | --- |
| `version` | JSON integer exactly `1` | Required; not decimal string, null, fraction or another revision. |
| `configuration` | Nonempty closed object described below | Omission preserves the captured baseline; retain supplied members only. `{}` and null refuse. |
| `tools` | Ordered unique array of zero through 1,024 names, each ASCII `^[a-z][a-z0-9_]{0,63}$` | Omission selects the host-captured default definitions/order. `[]` selects none. Each explicit name selects exactly its captured default definition and retained generation. |

The existing frame byte/string/depth/member limits apply before this decoder.
An explicit array cannot exceed the host's captured name set, and the complete
genesis cap still applies. Reject unknown option members, duplicate JSON keys,
duplicate names and malformed UTF-8 before retained-command inspection. Fresh
selection additionally rejects unknown names and ambiguous host default names;
historical replay compares retained selections without consulting today's set.
No sorting, registry search, aliasing of tool names or first-match selection is
permitted. Explicit tool order determines retained definition order; the names
map is derived from those exact definitions. Derive `artifact_read` only with the
existing native rule. Host helper bindings stay exact; selecting a helper tool
cannot create or modify a role, model route, instructions or delegation policy.

Configuration contains any nonempty subset of this six-member allowlist:

| Member | Wire domain |
| --- | --- |
| `model` | Nonempty exact UTF-8 string, subject to existing frame string and complete genesis caps; authored aliases permitted through admitted host resolution. |
| `reasoning` | Exactly `default`, `none`, `low`, `medium` or `high`; the resolved model must support the selection. |
| `instructions` | Exactly the raw instruction object below; no client digest. |
| `max_tokens` | Canonical decimal string in 1 through 18,446,744,073,709,551,615. |
| `context_token_budget` | Same positive uint64 decimal domain. |
| `system_class_tokens` | Same positive uint64 decimal domain. |

Quantities have no sign, whitespace, leading zero, exponent, fraction or numeric
JSON alternative. Convert them exactly to native integers, before candidate
validation. Effective model/context/reply/system constraints may refuse a
representable quantity. Omitted mutable members inherit the captured baseline;
explicit origins and derived budget recomputation follow ADR 0044/0050 exactly.
Clients cannot provide configuration_version, budget_origins, model_capabilities,
provider_mapping or maintenance configuration.

The raw instructions object has exactly four UTF-8 members:

| Member | Exact domain |
| --- | --- |
| `version` | 1–64 ASCII bytes matching `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`. |
| `base` | 1–32,768 UTF-8 bytes. |
| `environment` | 0–4,096 UTF-8 bytes. |
| `appendix` | 0–16,384 UTF-8 bytes. |

`Instructions.capture/1` preserves bytes and adds the deterministic digest.
It performs no path lookup, templating, environment discovery or authority
promotion. The complete system text and selected tools must fit the same strict
system ceiling; instructions do not bypass that preflight.

Reject remote host state, workspace/root paths, runtime/model modules or options,
provider bindings, credentials/references, route inventories, tool definitions,
capability maps, registry identifiers, cleanup grace, policy-defer mode, helper
roles/delegation, tracing and derived tool/artifact bindings. They are absent from
the closed grammar rather than accepted and ignored.

Native normalized options retain the required integer version, supplied member
presence, exact authored model/reasoning, native integer ceilings and explicit
tool-name order. For supplied instructions, retain only `{version, digest}` in
options and the complete capture in `initial_configuration.instructions`.
Reconstruction for replay uses the retained four sections plus descriptor and
requires exact equality with the caller's captured sections. A rendered digest
alone is insufficient because distinct section boundaries can render identically.
Instruction bytes occur once in the v3 genesis. No absent optional member is
manufactured in normalized authored options; complete effective defaults are
captured in the existing complete configuration/selection fields.

<a id="technical-preparation"></a>
### One owned preparation and initial version

Concept: [Fresh creation preparation and lifetime](0055-remote-session-creation-options.md#concept-preparation).

After connection/host authority and strict input validation, start the owned
creation worker and capture its one work cutoff before the retained-command
Store reads below. Its deadline includes those reads, host capture and any
callback/catalog preparation. After authoritative freshness, capture the
host's complete initial version-1 configuration, exact
selected definitions/names, policy-defer mode and cleanup grace. The baseline
must validate against those definitions. Physical workspace and host provider/
helper bindings retain their existing checks. No live mutable defaults are read
again after this capture.

If configuration is omitted, pure validation of this captured configuration and
selected tools suffices. Tool-only creation does not call preparation. If
configuration is supplied, require the existing optional Model preparation
capability and its admitted host resolution inputs. No completion fallback or
external-adapter shortcut is permitted.

For baseline P, normalized captured changes A and selected definitions D:

1. P has configuration_version 1 and passes complete validation against D.
2. Invoke the existing `prepare_configuration(P, A, D, context, private_options)`
   in one owned worker. Keep the five-argument signature and existing private
   wrapper/underlying option separation.
3. Returned C must satisfy ADR 0050's complete `validate_candidate(P,A,C,D)`
   alias rule, including exact next version 2, unchanged omitted model and all
   non-model authored settings/origins. It cannot retarget an omitted model.
4. Replace only C.configuration_version with 1, obtaining G. Validate the
   complete G against D and the existing exact initial-genesis preflight.
   No other value changes during rebasing; no configure record/event is emitted.
5. Bind G, normalized authored options, D and host runtime facts in the existing
   complete v3 genesis and exact Store create transaction. Enforce the full
   65,536-byte record cap before any mutation or session activation.

This explicitly extends ADR 0050: its current baseline is a committed session
and its cleanup comes from that session. Here the runtime-local Control owns
fresh-creation preparation before a session exists, with host-captured initial
facts as baseline and cleanup grace. At most one fresh creation preparation is
active per runtime, using its serial mutation-domain admission and the overlap
dispositions below. Stop/status remain serviceable. Bind results to exact
runtime owner/incarnation, create command, captured defaults/definitions and
original invocation. Stale, cancelled, expired or replaced-owner results refuse.
No worker writes Store, publishes durable events or allocates an active session.

Context remains exactly `deadline_monotonic_ms` and `cleanup_grace_ms`. The work
cutoff is captured once at creation worker start plus 60,000 ms; a later callback
start cannot refresh it. Control independently
enforces it; catalog contention consumes it. The runtime-owned private group
retains and joins callback-created invocation work under the host-captured
cleanup grace, using the existing absolute cleanup selection/observation rules.
Caller DOWN, runtime/control loss, runtime stop and expiry cannot renew either
allowance. Failed/unproved cleanup prevents successful creation or activation;
no process DOWN alone is promoted to semantic cleanup proof. Pre-existing shared
host catalog services retain accepted host custody, not invocation custody.
No provider credential acquire, model dispatch or executor dispatch occurs.

Existing fresh-selection validation still requires exact host-admitted
selected definitions and valid model request staging. For this verified
prepared-creation path only, replace startup-model equality with validation of
the canonical model's admitted host route through the selected Model wrapper.
An arbitrary remote candidate or unchecked supplied native genesis cannot take
that path. Core performs no provider/catalog lookup and imports no host adapter.

<a id="technical-overlap"></a>
### Admission without a waiting queue

Concept: [Overlapping creates](0055-remote-session-creation-options.md#concept-overlap).

Control retains one active entry: exact original command ID, complete normalized
original authored input/captured instruction sections, original caller identity,
captured defaults/definitions, work cutoff, cleanup facts and owned invocation
identities. Original input uses existing bounded plain-record validation; no
unbounded duplicate waiter list or second preparation entry is retained. The slot
is acquired before asynchronous Store reads and held through preparation,
retirement and terminal creation disposition. Refused or cancelled work releases
it only after the existing cleanup truth is established. An unjoined invocation
keeps this one slot unavailable for new creation preparation; no second group or
fresh cleanup allowance is manufactured. Existing unrelated session work stays
serviceable. Normal runtime retirement retains the original actor cleanup
obligations; a restart still needs exact Store unknown recovery. This is part of
the proposed pre-session custody behavior, not an existing settled-session rule.

After ordinary connection/host authority and strict bounded syntax validation,
Control handles an overlapping request as follows:

| Request while slot is active | Native detailed result | Wire result for that request | Work and retained effect |
| --- | --- | --- | --- |
| Different create command ID, including a would-be historical replay | Error `creation_in_progress`, disposition `no_activation` | Existing admission envelope, status `refused`, reason `creation_in_progress`, no session ID | No Store lookup, resolver call, queue entry or command reservation. |
| Same command ID, exact same normalized authored input | Same `creation_in_progress` result | Same request-correlated refused admission | Do not add a waiter, return the original caller's eventual result to this request, or extend the first cutoff. |
| Same command ID, different normalized authored input | Error `runtime_command_conflict`, disposition `no_activation` | Existing admission envelope, status `refused`, reason `runtime_command_conflict`, no session ID | No Store/resolver call and no replacement or cancellation of the first entry. |

Normalize integers and capture instruction sections purely before comparison;
compare exact supplied-member presence, authored alias, ordered tools and all
instruction section bytes. Each response carries that request's own request ID
and supplied command identity under the existing foreground/daemon envelopes.
`creation_in_progress` is a new closed refusal reason for both generations,
requiring explicit manifest/client vectors; neither `runtime_unavailable` nor
`commit_unknown` is reused to mean pre-admission work. These transient refusals
are not durable terminal command dispositions. Later same-ID presentation is
permitted under existing idempotency rules; it cannot repeat a committed create.

The original caller alone waits for its already-owned invocation under the one
work cutoff and cleanup obligations. Runtime Control, not a transport task,
owns the active entry and its retirement. Transport/connection/ticket intake,
existing capacities and caller-loss behavior remain mandatory. This adds zero
application-level queued create entries, not a claim that an OTP mailbox has
zero messages. Respond when the serial owner handles the request; do not add a
new queueing deadline or promise that scheduling consumes zero elapsed time.
Stop/status remain serviceable. After the slot is released, a request performs
the retained-command/freshness procedure below rather than using this transient
refusal as an authoritative absent key.

<a id="technical-replay"></a>
### Retained binding before resolution

Concept: [Capture, identity and replay](0055-remote-session-creation-options.md#concept-replay).

Store transaction identity continues to bind the entire canonical v3 genesis,
not just a new authored-options hash. No new authored command record or digest
replaces `Store.create_session/3`. Native normalized authored options and complete
canonical captures coexist in that existing transaction. In particular, alias
spelling remains authored while initial_configuration.model is canonical.

Replay must precede host resolution, including refresh of captured defaults:

1. Check Control's existing runtime-domain unknown fence/frozen OwnerLane
   proposal for the command. An exact incoming authored request reuses that
   exact proposal and transaction identity; a changed request conflicts.
   Never reconstruct a pending candidate from today's defaults or catalog.
2. For committed history, use the existing command selector on bounded
   `Store.creation_provenance/3`, then `Store.load_records(session_id,0,1)` to
   capture the original v3 genesis. Require exactly its original first-record
   envelope (journal_version 1, owner_epoch 0, owner_incarnation_id nil) and
   validate its payload with SessionGenesis. Require matching runtime/command/
   session, valid complete genesis and its recomputed canonical create digest equal to
   the provenance digest. Compare reconstructed original authored options,
   including exact instruction sections and supplied member presence.
3. Present that retained exact genesis to existing exact create-result lookup.
   A historical result returns its original session without new preparation,
   owner succession or activation. The bounded projection alone is not enough
   to bless a replacement genesis.
4. If command-selected provenance is authoritatively absent and no local
   unknown fence exists, test the exact key using the read-only probe below.
   Only `Store.runtime_command/2` returning `:absent` permits preparation.
   A missing callback or unavailable/contradictory provenance is not this
   branch. Completed or conflicting key evidence requires retained
   inspection/resolution or refusal, never a replacement prepared candidate.
5. Only authoritative absence proceeds to preparation. Control rechecks its
   runtime mutation fence before the one create transaction. A concurrent
   retained result wins through the existing exact transaction binding;
   differing captures conflict, never overwrite.

The absence probe uses exactly the immutable `session_creation_defaults`
already captured and validated when this runtime started. Construct a complete
native v3 genesis with private `options: %{}` from that baseline, then use
`Store.create_session(runtime_id, requested_command_id, baseline_genesis)` and
the existing `Control.create_command/3` construction. The resulting probe has
exactly runtime_id, command_id, command_kind `:create`, mutation_domain,
succession_id, canonical_command_bytes and canonical_command_digest; its digest
is the hash of those canonical bytes. Do not pass the probe to `transact`,
activate its candidate, select the request's tool subset, resolve its alias or
recapture defaults. The empty private probe options are not admitted remote
options and never become a new genesis record. A baseline failure refuses; it
cannot manufacture a key-only query with invented canonical bytes.

The existing Store query contract supports this probe: `:absent` is authoritative
for the exact runtime/command key. `Store.validate_runtime_command_members/2`
checks the seven-member identity/binary/hash binding. It does not require a
lookup candidate to equal a future as-yet-unprepared request. Local
`State.runtime_command/2` checks key absence before comparing any retained
canonical binding; its retained-create branch compares bytes and digest before
returning a result. Therefore the baseline probe may show key absence without
being the request's future candidate. A conflicting retained binding is evidence
that the key is occupied, not evidence that the authored request conflicts. Current create lookup normalizes an open
callback shape to `:unavailable`; only resume has a validated open projection.
A remote create must not reinterpret that shape as a pending creation receipt.

| Evidence after the local active/frozen check | Required behavior |
| --- | --- |
| Historical provenance + exact first genesis record + matching recomputed create digest | Compare reconstructed authored request; exact lookup returns the retained result, with no baseline probe/preparation. Changed authored input returns `runtime_command_conflict`. |
| Provenance `:absent` + baseline key probe `:absent` | Freshness proved at the read; capture the requested selection and prepare under the same original work cutoff. Existing exact transaction binding handles a later competing Store commit. |
| Provenance `:absent` + probe completed/conflict evidence | Occupied/inconsistent key; make one bounded provenance reread to observe a racing completed create. If a matching retained capture is then available, take the historical path. Otherwise return `store_unavailable`; do not infer payload conflict or prepare. No loop/repeated catalog work. |
| Provenance unavailable/missing callback/malformed; historical capture missing or contradicting its digest | Return `store_unavailable`; absence and current settings are not substitutes for evidence. |
| Provenance explicitly `:conflict` | Return `runtime_command_conflict`; do not resolve host inputs. |
| Probe `:unavailable` or malformed/open create result normalized to unavailable | Return `store_unavailable`; never treat an open observation as absence. |
| Local frozen unknown proposal for the same command and exact authored request | Re-present only the original immutable Store transaction through its OwnerLane; retained unknown returns `commit_unknown`, terminal resolution uses its actual original result. No baseline probe/callback. |
| Local frozen unknown proposal and different authored input under that ID | Return `runtime_command_conflict`; retain the original fence. |
| Local runtime mutation domain fenced by a different unresolved command | Return existing `commit_unknown` with no activation or preparation. |

OwnerLane stores an immutable transaction binding, not a recoverable authored
options API. Control must retain/reconstruct the original proposal and exact
authored comparison from that binding while it owns the lane; a successor
cannot inherit process-local pending authority. After runtime loss, use the
Store's durable current transaction/status and retained capture rules. If these
cannot recover an exact unknown binding, report unavailable/unknown and remain
fenced rather than assuming absence or resolving a replacement. There is no new
Store query/callback or exposed candidate projection in this proposal.

All Store reads and preparation participate in existing owned/cancellable work;
no unbounded synchronous transport lookup or new work allowance is introduced.
Missing optional creation provenance means this remote creation capability is
unavailable, not a blind current-default retry. Prepared native exact-create
calls keep their current contracts.

Replay distinguishes omitted configuration from supplied equal values, alias
from canonical spelling, omitted tools from an explicit equal list and different
tool orders. It distinguishes exact instruction section captures even with the
same rendering. A fresh command can capture changed defaults/catalogs. Unknown
mutation retains its original complete transaction; no acknowledgement,
publication or activation until its exact identity resolves. Store/session
restart validates captured current facts without callbacks or catalog access.
A pre-proposal current v3 history remains validated by its retained grammar;
it is not reinterpreted as a newly authored version-1 wire request.

<a id="technical-impact"></a>
### Activation, alternatives and proof

Concept: [Alternatives and acceptance impact](0055-remote-session-creation-options.md#concept-impact).

Acceptance narrowly amends these scopes together:

| Authority | Amendment |
| --- | --- |
| ADR 0044 remote creation | Pin the closed versioned authored options, descriptor/capture join, immutable name selection, fresh trusted model selection and explicit transient overlap refusal. Preserve complete v3 genesis, budgets, Store atomicity and public allowlist. |
| ADR 0049 host configuration | Permit a remote ordered subset of captured host default tools and authored initial configuration. Host immutable authority and private runtime options remain host-only. |
| ADR 0050 preparation | Reuse its optional callback for a host-captured creation baseline, runtime-owned pre-session invocation and pure version-2-to-1 rebase. Preserve alias validation, private option separation, catalog scope, work/cleanup bounds and replay-before-resolution. |

The viable smaller alternative requires exactly `{version:1}` and captures all
host startup defaults. It removes callback expansion and rebasing, but requires
an explicit amendment dropping M7 remote initial configuration/instruction/tool
selection. A subsequent configure is not atomic creation, cannot change tools
and may fail after a session has already been created. Selecting another host
configuration moves that workflow to host administration. It therefore reduces
observable capability and does not satisfy the current M7 creation row.

Before activation, complete both new seven-member manifests with every input,
result/event/snapshot and nested grammar, then migrate foreground/daemon decoders
and independent clients together. Preserve accepted generation negotiation and
schema-digest verification. Old option objects refuse under the new generation;
there is no old-generation decoder or fallback. Current-format history/replay
remains required; no old-root migration or cross-version rollback is introduced.
Disabling new remote admission on rollback does not permit rewriting captures,
unknown candidates or retained configuration into host defaults.

Required evidence is broader than grammar vectors:

- Closed positive/negative vectors for both transports; every forbidden authority
  member, null/wrong version, decimal overflow/noncanonical integer, instruction
  boundary, duplicate/unknown tool and complete-record/system-budget refusal.
- Host-default, tool-only/none and explicit configuration actual creation;
  canonical alias binding, strict selected-definition identity/order, pure rebase
  to version 1 and no intermediate configured event/session.
- Exact command replay after default/catalog/alias drift and current-format
  runtime/session restart, with callback count zero on replay and changed inputs
  conflicting before resolution. Compare exact sections, not rendered digest only.
- Actual Store commit_unknown at creation, retained exact proposal through
  resolution/restart, missing/contradictory provenance refusal, no blind retry,
  historical lookup with no owner activation and one confirmed fresh activation.
- Held original Store/preparation/cleanup controls with distinct, identical and
  conflicting overlapping creates: exact transient reasons, zero queued waiters,
  unchanged original cutoff/caller, no Store/resolver calls for overlaps and
  correct later replay/freshness. Occupied-probe/missing-provenance controls must
  not fabricate authored conflict or authoritative absence.
- Real preparation owner/caller loss, runtime stop, deadline and stale completion
  controls; exact work/cleanup joins before successful reply, no credential/model/
  executor dispatch, shared catalog lifetime distinguished from invocation work.
- Native unchecked candidate cannot bypass startup/host route authority; both
  independently pinned clients and current generation/restart barriers agree.

These are required future proofs, not results of this source-only proposal.
No formatter, compiler, documentation gate, runtime test, activation or milestone
closure is claimed here.
