<a id="technical-depth"></a>
## Technical depth

Concept: [Bounded provider failure diagnostics](0029-bounded-provider-failure-diagnostics.md#concept).

<a id="technical-adr-0029-decision"></a>
### Finite Terminal Contract

Concept: [Purpose and decision](0029-bounded-provider-failure-diagnostics.md#concept-adr-0029-decision).

Advance the private data codec and handshake from implementation version 1 to
2. Retain the length-prefixed framing, identity fields, caps and ordering. Only
an ambiguous-failure terminal gains one required `failure` map:

```json
{
  "nonce": "<existing invocation binding>",
  "staged_request_digest": "<existing request binding>",
  "status": "dispatched_or_unknown",
  "failure": {"stage": "stream", "class": "stream_transport_timeout"}
}
```

Every other terminal variant keeps its exact field set. Unknown failure fields,
wrong types, unknown enum values, extra keys, missing failure map, duplicate
terminal, mismatched identity and contradictory ordering refuse through the
existing conservative bridge failure path. Provider-supplied diagnostic text
cannot become this map.

`stage` is exactly `handoff`, `stream`, `metadata`, `completion`, `assembly`,
`calls` or `unavailable`. These are the six observed boundaries plus a fallback
when no category was obtained. `class` is one of these fixed binary values:

| Class | Meaning and structural source |
| --- | --- |
| `stream_http_auth` | API.Stream cause is API.Request with status 401 or 403 |
| `stream_http_rate_limit` | Same typed cause, status 429 |
| `stream_http_server` | Same typed cause, status 500–599 |
| `stream_http_status` | Same typed cause, another integer status >=400 |
| `stream_transport_timeout` | Typed Finch or Mint TransportError with reason atom `:timeout` |
| `stream_transport_tls` | Same typed exception with reason shaped `{:tls_alert, _}` |
| `stream_transport_error` | Other typed Finch or Mint TransportError |
| `stream_http_protocol_error` | Typed Finch.HTTPError |
| `stream_finch_error` | Typed Finch.Error |
| `stream_http_task_failed` | API.Stream cause shaped `{:http_task_failed, _}` |
| `stream_wait_timeout` | API.Stream cause is exactly `:timeout` |
| `stream_task_call_timeout` | API.Stream cause shaped `{:exit, {:timeout, {GenServer, :call, _}}}` |
| `stream_decode_error` | API.Stream cause is Jason.DecodeError, directly or wrapped as `{:error, exception}` |
| `stream_other_error` | Other API.Stream exception |
| `genserver_timeout` | Direct caught exit shaped `{:timeout, {GenServer, :call, _}}` |
| `raised`, `exited`, `thrown`, `caught` | Existing fixed exception/catch fallback classes |
| `provider_status`, `stream_failed`, `stream_incomplete`, `assembly_failed`, `returned_error` | Existing structurally tagged unsuccessful return categories from completion/assembly/drain |
| `unclassified` | No recognized unsuccessful stage result was obtained |


Only `unavailable/unclassified` is allowed when no stage was observed; a known
stage may use `unclassified` for an unexpected failure. Apply the listed typed
cases before their broader fallback: auth/rate-limit/server before other HTTP
status, timeout/TLS before other transport errors, and recognized API.Stream
causes before `stream_other_error`. Direct catch categories retain their exact
shape checks before generic fallbacks. Retain the first observed unsuccessful
stage after applying that stage's finite typed-classifier precedence; later
outer fallback results cannot replace it.

Success labels, arguments, returned maps, dynamic module names, exception
messages, raw status numbers, URLs, addresses, headers, bodies, reasons,
credentials and request identifiers never enter this map. Do not call `inspect`
or `Exception.message` to classify anything. A category describes a local
failure shape, not remote execution or retry safety. A typed decoder exception
is distinguishable only when it survives to classification; a parser that drops
an error does not thereby supply successful-decoding evidence.

The map contains exactly two binary values from finite allowlists. Its
standalone encoded representation must fit 256 bytes. This adds no capacity to
existing terminal/frame or semantic admission limits; prove the largest allowed
terminal including the map fits the unchanged cap. Retain one failed pair,
not a category log or event history. Classify before discarding reasons and drop
raw error references immediately after normalizing the original outcome.

Keep classifier helpers within the adapter. Do not integrate the supplemental
instrumented helper's hardcoded output path, exclusive file writer or
process-dictionary event history.

<a id="technical-adr-0029-lifetime"></a>
### Lifetime and Failure Handling

Concept: [Ownership and observable behavior](0029-bounded-provider-failure-diagnostics.md#concept-adr-0029-lifetime).

The worker alone produces the map and sends it within its already-bound
terminal. The bridge validates it before retaining a provisional pair in the
existing guardian state. The bridge must reach `terminal_end` and receive the
clean EOF sealing that single terminal before exposing the pair. Every
intervening failure, duplicate terminal, malformed or additional frame, partial
final frame, or child/channel loss discards the provisional pair before existing
failure handling continues.

Only the sealed terminal-end-plus-EOF path calls one private, side-effect-free
observation function. It does so after EOF validation and before that path's
existing cleanup or retention handling. A syntactically valid terminal alone
never exposes a category. Core still receives exactly
`{:error, {:dispatched_or_unknown, "model_call_failed"}}`; settlement, accounting,
conversation, retry and permit retirement never consume the pair.

The existing test-support phase observer may match that function with static
OTP match-spec messages and `:arity`. No raw arguments or return traces enter
its collector. It retains at most one accepted stage/class pair, emits it only
with failure diagnostics, and preserves existing health, delivery-barrier,
owner-death and cleanup checks. No production observer is installed and no
public observation API or option is added.

Missing category, invalid framing, lost child or failed bridge means unavailable
diagnostic evidence, not a guessed or reused category. An accepted category does
not prove cleanup: retain the separate cleanup verdict. The guardian owns its
provisional/sealed state for its invocation; its termination discards that
state. A test collector owns its bounded retained pair and termination. There
is no additional file, socket, logger output or detached process to clean up.

<a id="technical-adr-0029-compatibility"></a>
### Supersession and Compatibility

Concept: [Compatibility and rollback](0029-bounded-provider-failure-diagnostics.md#concept-adr-0029-compatibility).

This is a new numbered successor pair. ADR 0019's accepted decision and
acceptance bytes remain immutable. The narrow supersession is:

- ADR 0019's Concept launch/diagnostic restriction admits this finite normalized
  status to invocation-local host observation. Raw child stdout, stderr and
  crash output remain unavailable to host logging or retained artifacts.
- ADR 0019's Technical "One invocation, existing authority" closed terminal
  table admits the version-2 ambiguous-failure variant and its ownership rules.
  ADR 0019 requires one version and closed per-kind fields; it does not fix the
  literal codec version to 1. Current `ProviderCodec` version 1 advances to 2.
  Unknown fields, kinds and ordering remain failures.

ADR 0019's descriptor ownership, separate AF_UNIX data channel, one invocation,
exact namespace cleanup, protected readiness and credential handoff remain
unchanged. No TCP listener, distributed node, cookie, service or RPC is added.
No launcher change is proposed. Its same-source build and artifact verification
remain mandatory.

Version mismatch and generated manifest/build mismatch refuse before credential
delivery. Prove old-host/new-worker and new-host/old-worker refusals. There is
no dual decoder or silent downgrade. The private version is an implementation
contract, not a public session protocol or release version.

ADR 0018's "Outcome classification and usage" Model result and "Consequences"
raw-data prohibitions remain intact: no new retry authority, raw provider
structure, exception term or reason crosses Core, Store, public events,
progress, diagnostics, fixtures or rendering. The new map is a finite adapter
category rather than a provider structure.

No session schema or durable record changes, so no data migration is needed.
Rollback restores the matching host/companion pair and loses category reporting.
It cannot grant a retry of an uncertain invocation. Explicit credential
configuration, request deadlines, cleanup grace and accounting remain unchanged.

<a id="technical-adr-0029-evidence"></a>
### Proof Inventory and Alternative

Concept: [Evidence, budget and alternatives](0029-bounded-provider-failure-diagnostics.md#concept-adr-0029-evidence).

The concrete proposed product changes are confined to these paths under
`apps/loopex_llm_reqllm/lib/loopex/llm/`:

| File | Required change |
| --- | --- |
| `req_llm.ex` | Fixed local failure normalization with first-unsuccessful-stage selection |
| `req_llm/provider_worker.ex` | Construct the categorized ambiguous terminal |
| `req_llm/provider_codec.ex` | Private version 2 and exact finite-map validation |
| `req_llm/provider_bridge.ex` | Handshake, provisional state, EOF sealing and private observation |

Keep `provider_launcher.ex`, `ProviderConfiguration`, `ProviderBuildFixture` and
the companion build task unchanged. No new app, dependency, framework, callback
option, API, persistent schema or generic observer is justified. The map's
256-byte cap, one-pair retention and unchanged frame caps bound the addition.

The following existing paths under `apps/loopex_llm_reqllm/test/` own proof:

| File | Required proof or fixture adaptation |
| --- | --- |
| `provider_codec_test.exs` | Update version fixtures and the named "every closed kind round-trips its exact envelope" and "closed fields, identities, result variants and plain-value rules fail closed" cases; prove map cap, closed enums/fields and mixed-version refusal while preserving max-body, cap and partial-frame claims |
| `provider_bridge_test.exs` | Update its private fake-peer handshake; preserve identity, duplicate-terminal, unreadable and real-child cessation claims; add valid categorized-terminal-plus-EOF observation and valid-terminal followed by duplicate, malformed/additional or partial final frame negatives proving discard and zero category observations; assert cleanup separately |
| `provider_attempt_adapter_contract_test.exs` | Same generic public result and retry classification; secret-bearing synthetic causes cover every class and first-unsuccessful-stage precedence, including outer fallback that cannot replace a typed inner failure |
| `credential_plane_test.exs` | Secret-bearing unused fields never enter the map or report, including raises/exits and delayed dependency output |
| `provider_phase_diagnostic_test.exs` | Static-label matching, one-pair bound, unavailable/incomplete evidence, owner-death cleanup and original failure preservation |
| `support/provider_phase_diagnostic.exs` | Existing test-owned observer extended to retain only the validated finite pair |
| `support/provider_isolation_fixture.exs` | Only necessary protocol-version/terminal adaptation; preserve backpressure counts, deadlines and cleanup assertions |

The ordinary codec, bridge, credential and isolation version fixtures above are
neither named locked selectors nor Bound Artifacts in M0–M3. Their listed schema
adaptations alone need no standalone override. M2-gate locks the adapter witness
`the shipped adapter declares not_dispatched only before its transport canary and ambiguity after it`:
its pre-canary `not_dispatched` refusal and post-canary generic ambiguity remain
unchanged. Retain historical witness names and every unaffected assertion; stop
for the applicable scoped approval before changing an actual locked claim, name,
deadline or count. No changed runner,
exclusion, protected selector inventory, model, prompt, request deadline,
cleanup grace or required real-call count is proposed.

Requalification includes existing `provider_test.exs`, `provider_build_test.exs`,
provider startup/deadline/retainer/backpressure/launcher suites and M3's actual
attended source-built CLI workflow. Deterministic real-companion fixtures prove
failure categories; unchanged real-provider paths prove the delivered artifact
and workflow. Supplemental instrumented companions cannot replace required
actual-source evidence, and a real provider need not be forced to fail.

At examined product source `8e9a6c3432fd35784b52a435d12e922b5f33098d`, none of
the four product or seven test/support files above intersects any of the 32
M0–M3 Bound Artifacts rows. M0's protected launcher expressions are unchanged.
Thus this file list needs no Closed-gate artifact rewrite. Verify the actual
candidate diff again: a necessary bound-file edit, larger cap or new locked
selector requires disclosure of the specific extra transaction before that
change. ADR and M3 plan governance still apply.

The no-product-change alternative observes only the exact owned companion
PID/group, correlating its socket file-descriptor inodes with kernel states.
`/proc/<pid>/net/tcp` is namespace-wide, not process-specific. Retain only family,
connection-state transitions and timing; omit addresses, payloads and unrelated
sockets. Prove observer ownership/cleanup and mark sampling gaps unknown. Such
observation cannot recover provider, TLS or application failure categories and
cannot explain historical calls. Independent successful DNS/TCP/TLS checks are
evidence for their own invocations only.

<a id="technical-adr-0029-authority"></a>
### Authority and Scope

Concept: [Authority and implementation boundary](0029-bounded-provider-failure-diagnostics.md#concept-adr-0029-authority).

The maintainer approved the bounded design recorded in this successor contract.
The pair remains Proposed pending exact-candidate acceptance; the design choice
does not need to be asked again. Exact-candidate acceptance of this pair and the corresponding M3 proposal/rebind
record precede dependent implementation. The M3 amendment names the diagnostic
addition in its scope, minimalism budget and evidence envelope; no capability
outcome is deferred. The development-time override alone cannot amend an
accepted architecture ADR.

This proposal accepts no unseen commit, waives no observed failure, authorizes
no additional supplemental diagnostic calls and closes no milestone. Historical
failure causes remain unassigned unless evidence establishes them. A subsequent
pass does not disposition an earlier failure. Required full candidate evidence
continues under existing approved timing with no altered command or pass
criterion. New substantive choices outside this finite contract require a new
maintainer decision rather than inference during implementation.
