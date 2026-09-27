<a id="technical-depth"></a>
## Technical depth

Concept: [Ephemeral embedded profile](0039-ephemeral-embedded-profile.md#concept).

<a id="technical-adr-0039-decision"></a>
### Profile Composition

Concept: [Context and decision](0039-ephemeral-embedded-profile.md#concept-adr-0039-decision).

The kernel's ports are unchanged; the profile chooses what fills each one:

| Port | Durable profile | Ephemeral profile |
| --- | --- | --- |
| `Loopex.Store` (six callbacks) | `Loopex.Store.Local` | `Loopex.Store.Memory`: a supervised process over `Loopex.Store.Local.State`, the conformance test wrapper promoted using private Loopex.Store.Memory.checkpoint/3 reproducing the Local library probe protocol (never a test-only module), optional probe active only when supplied, all six GenServer calls explicitly bounded at 30,000 ms and the probe reply at 5,000 ms; production composition supplies no probe, so every conformance case proves it |
| `Loopex.ArtifactStore` | `Loopex.Store.Local.Artifacts` | None; the runtime's existing `artifact_store: nil` behaviour (overflow truncated with the executor's notice, transfers unsupported) |
| `Loopex.Model` (`complete/3`) | `Loopex.LLM.ReqLLM` through the companion bridge | `Loopex.LLM.ReqLLM.InProcess` for every provider the profile serves |
| `Loopex.Executor` | `Loopex.Executor.Local`, ledger under the state root | `Loopex.Executor.Local`, ledger under the profile's temporary root |
| `Loopex.Policy` | A named host policy | A policy module supplied by the host; the reference CLI maps `allow-all`, `shell-allowlist` and `refuse-all` to its own modules |

**The in-process adapter:**
- **Placement:** it lives in `apps/loopex_llm_reqllm`, the one edge application
  that carries ReqLLM.
- **Scope:** the ephemeral profile only. The durable composition always uses
  the companion adapter, which keeps refusing any in-VM fallback, as ADR 0034
  fixed.

**Providers and their credential variables:**

| Prefix | ReqLLM module required at call time | Credential variable |
| --- | --- | --- |
| `ollama:` | `ReqLLM.Providers.Ollama` | None |
| `openai:` | `ReqLLM.Providers.OpenAI` | `OPENAI_API_KEY` |
| `anthropic:` | `ReqLLM.Providers.Anthropic` | `ANTHROPIC_API_KEY` |
| `openrouter:` | `ReqLLM.Providers.OpenRouter` | `OPENROUTER_API_KEY` |

**Session admission and containment.** M6 adds a private lifecycle cell to each
opaque ephemeral handle. It is passed explicitly through composition to the
model and executor options; it is transient host configuration, not a durable
or public member. Values are `0` open, `1` stopping, `2` proved closed and
`3` cleanup-unproved. A second atomics slot tracks provider-attempt outstanding:
0 idle, 1 active-or-unproved. Before any proxy starts, callback asks the
M6 composition session owner for begin-model custody; that owner CAS-reserves 0→1
and records the callback monitor and fresh call reference. Lost/malformed
custody proof starts no proxy/candidate and seals lifecycle3. Each model and
executor effect grant checks open. The
serial session owner moves open to stopping on stop; a participant with missing
call proof compare-exchanges open/stopping to cleanup-unproved before returning
or withholding proof, never overwrites proved-closed, and
notifies that owner. No message or service restart can restore open. Only exact
successful cleanup may move stopping/unproved to proved closed. A delayed
notification therefore cannot admit another effect: model/tool admission asks
the composition session owner to reconcile prior outstanding state with a fresh
reference and bounded reply before granting. Ordinary core model→tool ordering
can precede the session owner's queued cleanup-owner DOWN processing; the owner
may drain/await that exact retirement under the bound, not falsely reject the
normal transition. It grants only after correlated clean-retirement proof and
exact owner DOWN clear the prior outstanding slot. Missing proof by the bound
seals lifecycle slot 1 to value `3` and keeps outstanding slot 2 at value `1`;
no async notification or shared service is
needed for this fence. Already-granted executor
work remains subject to its existing receipt, process-group and stop proof.
There is no VM-wide credential/tool gate, lease, quarantine, persistent poison
or VM-restart recovery rule. Independent sessions have distinct cells and
per-call pool tags. Shared Req/ReqLLM/SSL infrastructure is host-owned and can
still suffer outages affecting its consumers.

An authority-free candidate start receives no cell or call inputs. Before
that registration boundary the callback owns sealing its session on uncertain
proxy/candidate cleanup. After managed registration, the owner receives the
cell only with cleanup-only preparation after managed core registration,
before any begin grant, and records each call-owned process before
allowing it to proceed and seals it on unproved termination. The root and
caller monitor their admitted owner and cannot acquire new dispatch authority
on owner loss; any surviving call root remains an affected-session cleanup
obligation. Complete session teardown requires all owned registered roots,
workers and tagged registry entries proved ended, not merely their parent
terminated. The admitted call's cleanup-owner identity is registered in the affected
session's private census before pool/caller grants. That session owner monitors
it; unexplained owner loss seals the cell before new facade admission unless
its correlated clean-retirement proof was already accepted. An adapter callback
that observes owner loss also seals before returning conservative failure.
Before provisional cleanup transfer, callback DOWN with outstanding attempt is
unknown until the bounded control reconciliation proves exact clean refusal or
staging. Provisional transfer precedes core registration and does not release
work. After provisional transfer,
callback normal DOWN is expected and does not retire the registered owner.
Only matched clean-retirement nonce/phase proof plus its exact owner DOWN lets
the session owner clear outstanding 1→0; missing either keeps it outstanding.
Clean pre-registration no-child or exact candidate/proxy reap may clear
outstanding without creating managed-retirement evidence. This shared session
owner is the M6 facade/census actor, not a kernel actor or another gate service.
The session census retains its reached root/child/tag obligations, so abrupt
owner loss never silently discards the only proof record.
The executor returns its existing nonce-bound exact-instance
process-group proof directly to the session owner before runtime stop; accepted
proof remains in that owner's retry state. No global final release phase
exists.

The model owns inward `InProcess.Admission`; the executor owns inward
`Local.EphemeralAdmission`. Composition's `SessionAdmission` implements both
and sends correlated messages to the composition session owner. Neither edge
imports composition. Each behaviour callback is
`request(handle, operation, absolute_deadline)`. The edge's private dispatcher
is `request(module, handle, operation, absolute_deadline)` and calls that
module's callback. Both return `{:ok, token}` or
`{:error,:session_admission_closed}`; that reason is private and projects to
existing fixed model/pre-effect failures, not a new public code.
Operations are `{:begin_model, callback_pid, call_ref}`,
`{:stage_model, call_ref, candidate_pid, proof_ref, stop_ref,
pre_activation_proof}`,
`{:register_model, call_ref, cleanup_owner_pid, proof_ref}`,
`{:record_model_resources, call_ref, cleanup_owner_pid, revision, entries}`,
`{:tool_grant, executor_pid, instance_ref, dispatch_ref}`,
`{:retire_model, call_ref, cleanup_owner_pid, proof_ref}`, and
`{:cancel_model, call_ref, pre_activation_proof}`. Payloads contain only PID,
references/cell/generation/expiry, admitted credential-free pool identity and
fixed proof state, never request, key or raw result. The callback creates a
fresh retirement `proof_ref` before core registration and supplies it through
stage_model with the reconciled exact successful candidate/proxy proof. Session
owner installs the candidate monitor and sends directly
`{:model_custody_prepare, start_ref, staging_ref, cleanup_deadline,
cleanup_handle}` with constructor-bound start_ref and the cleanup-only handle
`{:model_cleanup_custody, session_owner_pid, generation, call_ref,
candidate_pid, proof_ref}`. Candidate acknowledges directly to that owner;
echoing staging_ref/generation/call/proof after checking its constructor reference,
own PID and bounded expiry. Only then may owner acknowledge staging to callback and callback enter the
registrar. No cell, request, credential or activation token reaches the candidate
through this handle. Lost staging acknowledgement cannot strand retirement
custody. register_model later changes provisional custody to managed activation,
never creates the record. Its live model deadline gates work, not retirement.
Known staging/provisional empty-census retirement requires no managed return/preparation or
later register_model message. The M6 pair defines the complete phases and
staging-acknowledgement/death cases.
An exact delivered handle may retire the known empty staging record even when
its custody acknowledgement was lost/expired; retirement never promotes registrar
permission and suppresses all later activation acknowledgements.
Resource recording
retains at most five fixed-role process entries and the two tagged registry
identities before granting progress. The session owner installs exact monitors
before acknowledging and accepts retirement only after their DOWN and empty
tagged registry lookups. Registry removal is asynchronous: cleanup and session
owners poll exact tagged lookups within their 1,000 ms cleanup-control bound,
not a single immediate lookup after DOWN. Pending retirement reconciles independently delivered
DOWN in the responsive owner loop within its bounded cleanup-control deadline;
an expired model deadline does not prohibit cleanup. M6 defines the revision,
replay and deadline grammar. Token binds
exact PID/reference/session generation and expiry;
identical replay never extends expiry or repeats a transition.
Each operation uses at most 1,000 ms and its enclosing deadline; an expired
queued request mutates nothing. Lifecycle1/3 permits only cleanup staging,
resource recording, retirement and cancel cleanup control, never new model/tool
authority. Only the owner clears the
outstanding slot on its exact correlated proof and monitor conditions. The M6
pair owns the complete message/token schema and adversarial cases.

**Bounded composition startup.** M6 owns the complete closed option/error
contracts, temporary-root claim, startup rollback, facade operation and stop
protocols. Their implementation uses the same session cell. Before any session
input or root authority is released, one unlinked monitored authority-free
bootstrap worker calls `Application.ensure_all_started(:loopex_composition)`.
It has a 5,000 ms decision bound and 1,000 ms reap bound. A late application-
controller completion has no session authority; later callers reconcile current
startup state. Session-owner startup likewise uses one unlinked proxy and
releases activation only after an exact returned PID and normal proxy
termination. A late owner receives no root-start authority. These helpers do
not require a supervising global admission guard or persistent poison.

**Shared ReqLLM startup.** The composition application has temporary
`ReqLLMStarter` under `:one_for_one`, recreated on demand within the startup
bound, not automatically restarted. Service crashes cannot exhaust the
application supervisor's restart budget or terminate its session sibling.
It owns only serialized application
startup and provenance. The worker holds no session, request, credential,
activation or effect authority. A waiter's 5,000 ms deadline or death does not
cancel the service's admitted controller request. Recreation reconciles retained
positive provenance and current dependency state before serving another caller;
uncertainty returns fixed `req_llm_start_failed`, never a VM lockout. M6 defines
the exact service/provenance messages and witnesses. The pre-start guards and
host-declaration requirements below still apply. No waiter may mistake a
running but undeclared or .env-enabled dependency for an admitted start.

**The call** (ReqLLM 1.24.0). The adapter calls the non-streaming
`ReqLLM.generate_text/3` with the model built inline as
`ReqLLM.model(%{provider:, id:, base_url:})`, and on every call:
- `api_key:` the value of the provider's variable, read by the calling process
  immediately before the call after validating a byte length of 1 to 65,536;
  absent, empty or larger values refuse before the ReqLLM call; none for Ollama,
  whose provider performs no key lookup or authentication
  (`providers/ollama.ex:118`);
- `total_timeout: :infinity`, so ReqLLM's timeout budget calls `Req.request/1`
  directly in the calling process (`timeout_budget.ex:48`) rather than in a
  task on the shared `ReqLLM.TaskSupervisor` (`:101-103`);
- `base_url:` always passed, as the host's `:base_url` or else the built-in
  module's `default_base_url/0`; ReqLLM fills an absent one from `:req_llm`'s
  per-provider application configuration or the model catalog
  (`provider/options.ex:1147-1171`), and an explicit option wins
  (`Keyword.put_new_lazy`). A credential-bearing provider accepts only an
  `https` URL; only credential-free Ollama may use `http`;
- `receive_timeout: :infinity`; the cleanup owner, not a dependency timer,
  maps the request's committed absolute system-millisecond deadline to native
  monotonic time with one frozen `native_offset =
  System.time_offset(:native)` and the companion's shared exact formula
  `System.convert_time_unit(deadline_ms, :millisecond, :native) -
  native_offset`. Positive native remainders round upward to
  milliseconds; zero or negative means expired. Every wait and the request's
  `pool_timeout` is capped at 1,000 ms, so no unsigned-64-bit value reaches a
  relative timer. The caller reports exactly
  `{caller_pid, ref, result, finished_at_native}` with its native monotonic
  completion timestamp;
  at expiry one zero-wait receive admits only an already-queued matching result
  stamped no later than the same deadline, otherwise the owner kills the caller
  and refuses every result;
- `max_retries: 0`, retained as defense in depth: every chat path attaches
  ReqLLM's retry step after `Req.new/1` (`providers/anthropic.ex:388`,
  `providers/openai.ex:703`, `providers/ollama.ex:134`,
  `provider/defaults.ex:640`), which overwrites Req's `retry:` option and can
  recursively rerun a request (`deps/req/lib/req/steps.ex:1807-1818`); the
  owner-side dispatch grant below is the authoritative at-most-once fence;
- `req_http_options:` containing the `Loopex.LLM.ReqLLM.OneShotHTTP1` adapter,
  `redirect: false`,
  `finch: [name: Req.Finch, pool_tag: tag, pool_timeout: bounded_timeout]`,
  where `bounded_timeout` is the owner-computed value from 1 through 1,000 ms,
  and bounded
  credential-free Loopex call context in the exact shape
  `finch_private: %{loopex_one_shot: {owner_pid, tag, route_fingerprint}}`,
  where the fingerprint binds the provider, planned surface, POST method,
  normalized explicit base URL, exact final path and nil query before credential
  resolution. All four chat paths
  pass these options to `Req.new/1`
  (`providers/anthropic.ex:199-235`, `providers/openai.ex:435-484`,
  `provider/defaults.ex:255-284` for Ollama and OpenRouter). Anthropic and
  OpenAI try to add their receive-timeout-derived `pool_timeout` to the named
  Finch options, but `merge_finch_options/2` preserves the explicit nested
  value (`provider/defaults.ex:649-667`); Ollama and OpenRouter also receive the
  same exact nested list unchanged;
- no `:cache` option, so ReqLLM's response cache is disabled
  (`cache.ex:125-128`).

Before resolving a hosted credential, the caller uses one exact credential-free
option list for planning: `max_tokens`, `tools`, `total_timeout: :infinity`,
`receive_timeout: :infinity`, `max_retries: 0`, `base_url` and the complete
`req_http_options` above, in that order. Ollama generation uses that same list.
A hosted generation prepends only `api_key: resolved_value` after the final
guard and session admission check.
`ReqLLM.plan(model_spec, :chat, planning_options)` receives the credential-free
list and never the key (`deps/req_llm/lib/req_llm.ex:420-423`); the literal
`:chat` matches the `generate_text/3` path, and neither option list contains an
operation or `cache` member.

**The call-owned pool.** Before the caller starts, the cleanup owner creates
`tag = make_ref()` and `pool = Finch.Pool.new(base_url, tag: tag)`. A reference
is a valid tag and is part of the `{scheme, host, port, tag}` pool identity
(`deps/finch/lib/finch/pool.ex:28-48`, `:80-114`, `:136-143`), so concurrent
calls to one origin do not share a pool and no per-call atom is created.

The owner itself `spawn_monitor`s one request-free **pool-lifecycle root** and
records that PID and monitor before sending it permission to
initialize. The root traps ordinary exits and is the parent of every process it
starts; it never exits until each registered descendant is `DOWN`. It performs
every synchronous or fallible pool operation while the owner stays in its
receive loop. This owner-created, start-blocked root removes the interval in
which a helper could create an unregistered supervisor. The root monitors the
cleanup owner; owner `DOWN` starts the same idempotent graceful teardown from every setup phase.

The root first requires both the duplicate worker-registry lookup
`Registry.lookup(Req.Finch, Finch.Pool.to_name(pool))` and the unique
pool-supervisor-registry lookup
`Registry.lookup(Finch.Pool.Manager.supervisor_registry_name(Req.Finch),
Finch.Pool.to_name(pool))` to be `[]`, then builds
the public `Finch.Pool.child_spec/1`, starts a fresh anonymous
`DynamicSupervisor`, and starts the user-managed pool child beneath it. That API
exists for independently managed pool lifetimes (`pool.ex:145-190`) and returns
the pool-supervisor child specification (`pool/manager.ex:187-198`). The root
synchronously registers the anonymous supervisor and each later returned PID
with the owner and receives its acknowledgement before continuing. It then requires
`Supervisor.which_children(pool_supervisor)` to be exactly
`[{1, owned_worker_pid, :worker, [Finch.HTTP1.Pool]}]`, the full duplicate-key
worker-registry lookup to equal exactly
`[{owned_worker_pid, Finch.HTTP1.Pool}]`, and the unique supervisor-registry
lookup to equal exactly one entry whose PID is the recorded pool supervisor and
whose value is `{Finch.HTTP1.Pool, 1, expected_pool_config}`.

`expected_pool_config` is the expanded, sanitized map returned inside the
single `Finch.Pool.child_spec/1` result, not the submitted keyword options.
Before start, the root extracts it from that spec's
`{Finch.Pool.Supervisor, :start_link, [{name, {registry, pool, config, false}}]}`
start tuple and requires `name` to carry the same tagged identity and config.
It validates the fixed projection: HTTP/1 module, size/count 1, infinite idle
limits, metrics off, HTTP/2 defaults `wait_for_server_settings?: false`,
`ping_interval: :infinity`, `max_connection_age: :infinity` and jitter 0,
and `conn_opts` containing
protocols `[:http1]`, push disabled, nil key-log device, timeout 5,000 ms,
nodelay and keepalive true, plus the three exact HTTPS retention values
(HTTP has none). It then compares stored config to that exact expanded map.
An unexpected spec refuses without starting it. There is no second
side-effecting configuration cast to derive the expectation. Expansion and
sanitization are pinned at `finch.ex:525-580`, `pool/manager.ex:187-198,238-269`.

The complete setup must produce that exact result before the earlier of 1,000
ms and the call deadline. Only then does the owner start the caller. A stop
remains answerable during registry access,
`Finch.Pool.child_spec/1`, root start, `DynamicSupervisor.start_child/2` and
inspection. Before dispatch, cancellation or setup expiry tells the lifecycle
root to unwind and awaits it; the root stops and awaits every descendant before
it exits. The owner never sends it an untrappable kill. If a dependency call
does not return so the root cannot prove its unwind, the path remains
`cleanup_unproved`, returns no provider result or successful stop
acknowledgement, seals only this session and retains its process census rather
than treating the root's death as proof. The owner also awaits every PID already reported and
requires both Loopex-created registry entries gone before returning a fixed
pre-dispatch refusal or stop acknowledgement. A child-start failure, partial
start, missing worker or unexpected result follows the same path.

For normal teardown the same lifecycle root performs the bounded graceful
anonymous-supervisor stop while the owner remains responsive. The owner
requires the lifecycle root, pool supervisor and worker `DOWN`, plus disappearance of
both Loopex-created registry entries. It never adopts or stops a foreign
registry entry. A foreign same-tag entry in either registry before or after
owned startup makes the exact-list check fail; the call tears down its own root and refuses. Host code
that inserts one after the final dispatch check is trusted same-VM interference,
but it cannot reroute the direct PID call.

The pool's fixed options are `protocols: [:http1]`, `size: 1`, `count: 1` and
`start_pool_metrics?: false`. The only permitted plain HTTP pool is
credential-free Ollama. An HTTPS pool also sets exactly
`conn_opts: [transport_opts: [reuse_sessions: false, session_tickets: :disabled,
keep_secrets: false]]`; an HTTP pool omits `conn_opts`. Finch passes the outer
`conn_opts` to Mint, whose HTTP/1 connector reads SSL options only from the
nested `transport_opts`
(`deps/finch/lib/finch/http1/conn.ex:8-17,48-53`;
`deps/mint/lib/mint/http1.ex:167-177`).
Mint merges explicit transport options over its defaults
(`deps/mint/lib/mint/core/transport/ssl.ex:449-456`), and defaults TLS 1.2
session reuse to true (`:561-573`), so the explicit values are part of the
credential-lifetime contract: no TLS 1.2 session is registered for reuse, no
TLS 1.3 resumption ticket is retained, and no key-log secret is kept. The
two-toolchain source trace and TLS witnesses pin those OTP behaviours.

`Req.Finch`, started by Req's application (`deps/req/lib/req/application.ex:7-14`),
supplies only the duplicate worker registry and unique pool-supervisor registry
in which the user-managed pool registers. The normal
Finch route looks up a request's full `{scheme, host, port, tag}` identity and,
when it is absent, automatically starts a replacement under the named Finch
(`deps/finch/lib/finch/pool/manager.ex:94-139`; selected from
`deps/finch/lib/finch.ex:1011-1019`). This adapter never uses that route. Neither
the default `Req.Finch` pool nor `ReqLLM.Finch` carries the call. The tagged pool
is stopped after the call and its connection cannot be reused or retained by a
pool. A checked-out socket and its OTP TLS controller can still drain
asynchronously under the cleanup rule below.

**The one-shot Req adapter.** Req invokes a module adapter only after request
steps have produced the final request (`deps/req/lib/req/request.ex:1035-1067`).
`OneShotHTTP1.run/1` validates the final normalized origin, the exact
`Req.Finch` name and tag, the permitted `pool_timeout`, and the absence of
`connect_options`, proxy, Unix-socket, plug, alternate `into` or other routing
substitution. It also requires compression disabled and no final
`accept-encoding` header except `identity`. It requires the exact
`finch_private` shape, removes that Req-only option before building transport
data so Finch telemetry never receives the private owner context or PID, and
asks the owner synchronously to claim dispatch from the expected caller. The
first claim sends one inspection command to the already registered
pool-lifecycle root while the owner remains responsive; it starts no second
helper. The owner grants only when that root confirms the recorded PID is
alive, the recorded pool supervisor still reports exactly
`[{1, recorded_pid, :worker, [Finch.HTTP1.Pool]}]`, the full-tag worker registry
is still exactly `[{recorded_pid, Finch.HTTP1.Pool}]`, and the unique
supervisor registry is still exactly one entry for the recorded pool supervisor
and expected pool configuration. The grant returns that PID
and atomically marks dispatch. An inspection timeout, lifecycle-root loss or
mismatch refuses without a network write and starts or joins the same
cooperative root teardown. If the root is stuck in a dependency call, cleanup
remains unproved; the owner does not return a fixed refusal while that root is
live. It never selects through
`Finch.find_pool/2`, whose duplicate-registry strategy may choose a random
entry (`pool/manager.ex:116-128`). Granting marks the call
`dispatched_or_unknown` before any socket write.

The adapter then builds a `%Finch.Request{}` directly from the final Req method,
URL, headers and already encoded non-streaming body with
`Finch.build(method, url, headers, body, [pool_tag: tag])`, and calls
`Finch.HTTP1.Pool.request/6` on that exact PID, literal name argument
`Req.Finch`, and exactly
`[pool_timeout: bounded_timeout, receive_timeout: :infinity,
request_timeout: :infinity]`. Final validation refuses `:pool_strategy`, a
different timeout or any other Finch build/request option. This avoids the
locked HTTP/1 pool's otherwise implicit 15,000 ms receive timeout
(`deps/finch/lib/finch/http1/pool.ex:42-45`). That exported
`Finch.Pool` callback performs the synchronous caller checkout
(`deps/finch/lib/finch/http1/pool.ex:42-74`). It does not consult a registry or
pool manager. If the worker dies or its supervisor restarts it after the grant,
the call to the old PID fails; no replacement can receive the request. The
adapter never calls `Req.Finch.run/1`, `Finch.request/3`, `Finch.stream/5` or
`Finch.stream_while/5`, because each would perform the auto-starting lookup.

For that direct call, the adapter implements the small response accumulator and
error normalization that the locked `Req.Finch` adapter would otherwise supply
(`deps/req/lib/req/finch.ex:286-302`, `:338-360`). It sets
`accept-encoding: identity`, rejects a content-encoding header before retaining
body data, and accumulates at most 8,388,608 response-body bytes. When another
  chunk would cross the limit, its Finch callback returns
  `{:halt, accumulator_with_private_overflow_sentinel}`, which closes an HTTP/1
  connection while preserving the sentinel
  (`deps/finch/lib/finch.ex:723-730`). The adapter restores the
original Req `into` and private context only to the returned Req request, so a
ReqLLM retry or redirect reaches the same owner fence. It replaces an overflow
with the fixed `:loopex_response_too_large` transport sentinel and an encoded
response with `:loopex_response_encoding_unsupported`; the caller maps their
private diagnostic names `model_response_too_large` and
`model_response_encoding_unsupported` to the public
`{:dispatched_or_unknown, "model_call_failed"}` form. The caller never accumulates or
decompresses an unbounded response. Every later adapter invocation is refused
before network activity. The non-secret tag and exact pool-worker PID are
visible to Finch telemetry; the private owner PID is not. Host code that
deliberately tampers with the same VM's processes or request between validation
and dispatch remains trusted host code. After the direct pool call returns or
raises, the adapter asks the owner to stop the tagged pool and waits for proved
owned-subtree teardown before it returns or reraises. That is the early
transport-completion path, not the only cleanup trigger: once the anonymous
root exists, every later pool-child failure or partial start, terminal caller
reply, refusal, spawn failure or exit starts or joins the same teardown. The
owner's first atomic claim marks dispatch and returns the exact recorded worker
PID; every later claim is refused by the fence without performing a pool lookup
or failing incidentally during dispatch. An
untrappable caller kill skips the adapter path, so the owner retains the
fallback described below.

**Why HTTP/1 only.** Both ways of reaching HTTP/2 through the locked Finch
fail this adapter's contract. Its multiplexed HTTP/2 pool can send again below
Req's retry control when a connection turns read-only mid-upload
(`finch/http2/pool.ex:562`, `finch.ex:824-830`). HTTP/2 negotiated by ALPN on
its HTTP/1 pool sends the whole body in one `Mint.HTTP.request/5` call
(`finch/http1/conn.ex:118-124`), which Mint refuses above the 65,535-byte
initial window (`mint/http2.ex:1496-1507`); ReqLLM guards the same case on its
streaming path (`req_llm/streaming/finch_client.ex:333-359`). HTTP/2 is future
work for a transport that removes both limits.

The kernel's own deadline bounds the call. Inline model construction skips
selected-model resolution and the string path's unverified-model warning
(`req_llm.ex:313-329,735-750`). It does not prevent provider metadata queries.
Anthropic planning and generation always run thinking normalization
(`request_plan/diagnostic.ex:84-109`, `providers/anthropic.ex:853-865,1494-1524`),
whose native-model fallback calls `LLMDB.model/2`
(`model_helpers.ex:94-123,159-174`). With M6's exact list and no thinking option,
the query leaves those options unchanged but can initialize shared metadata.
Under the default compiled source (`config/config.exs:23`,
`llm_db/packaged.ex:58-69`), loading needs no runtime snapshot file or download.
Catalog state is VM-wide and retained, not part of a call's cleanup census.
Loopex changes neither preloaded state nor catalog configuration. Host-selected
files, remote snapshots and overlays are trusted shared-dependency behavior:
remote `ReleaseStore` may use ordinary `Req.get`, disk cache and ambient
`GH_TOKEN`/`GITHUB_TOKEN` (`llm_db/loader.ex:580-606`,
`llm_db/snapshot/release_store.ex:675-684,902-953`). That traffic is not a model
dispatch through the one-shot adapter and is not covered by its transport
or credential-injection guarantees. Packaged and host-preloaded catalog cases
and exact request bodies have distinct witnesses in the M6 plan.

**Guards.** Composition checks the host-global guards. The cleanup owner checks
them again before it casts or starts the pool, the caller checks them before
`ReqLLM.generate_text/3`, and the one-shot adapter validates the final request
at the dispatch boundary:
- The fixed model-prefix mapping chooses the existing provider atom and expected
  module (`:ollama`, `:openai`, `:anthropic` or `:openrouter`) without consulting
  ReqLLM state. The pre-start global guards and guarded ReqLLM hygiene decision
  run next. Only after that decision initializes or verifies the application does
  `ReqLLM.provider(provider_atom)` have to return `{:ok, expected_module}` with
  the exact module in the table above (`req_llm.ex:260-266`). The default address
  is then read directly from that verified module. ReqLLM's registry lets a later
  registration replace a provider (`providers.ex`), and generation resolves the
  module at call time, so the cleanup owner and caller repeat the registry check.
- `System.get_env("SSLKEYLOGFILE")` is unset. Finch falls back to it when no
  `:ssl_key_log_file` is given and opens it while casting pool options
  (`deps/finch/lib/finch.ex:550-558`). When Loopex must start ReqLLM and Req,
  this guard runs before that application start. With host-started dependencies,
  the guard prevents Loopex's call-owned pool from opening or appending to the
  destination but cannot undo a file open that happened earlier. The fixed
  `keep_secrets: false` means the locked OTP returns no key-log material.
- `Application.get_env(:req, :default_options, [])` is `[]`. `Req.new/1` merges
  it into every request, plugins included (`deps/req/lib/req.ex:475-479`,
  `:1359-1361`), so any value could add an `Authorization` header, a response
  cache, a plugin, another pool, `into:` or a transport.
- The base URL is a non-empty valid UTF-8 absolute URL of at most 65,536 bytes,
  parsed by one private byte parser rather than by provider code. Its exact
  grammar is `<scheme>://<host>[:<port>][<path>]`; any other authority syntax
  refuses. The literal lowercase scheme is `https` for a credential-bearing
  provider, or `http` or `https` for Ollama. A host is either canonical dotted
  IPv4—four decimal octets from 0 through 255, with no leading zero except
  `0`—or an ASCII DNS name of at most 253 bytes: one or more dot-separated
  1-to-63-byte labels, each beginning and ending with an ASCII letter or digit
  and containing only those bytes or `-`. DNS bytes normalize to lowercase; a
  trailing dot, empty label, bracketed IPv6, Unicode, percent escape and user
  information refuse. An optional port is canonical decimal with no leading
  zero, from 1 through 65,535; explicit `:80` on `http` and `:443` on `https`
  normalize away, and omission has that same effective port. The path is empty
  or slash-prefixed non-empty segments made only of RFC 3986 unreserved ASCII
  bytes; query, fragment, percent escapes, backslashes, repeated interior
  separators and literal `.` or `..` segments refuse. All trailing slashes,
  including a lone root slash, are removed before the same canonical string is
  passed to the inline model, pool and ReqLLM. A library URI parse may only
  verify that canonical result; it does not admit or normalize input.
  The exact POST route appended to that prefix is `/chat/completions` for
  Ollama and OpenRouter, `/v1/messages` for Anthropic, and either
  `/chat/completions` or `/responses` for the OpenAI surface. Before reading a
  key the caller derives the Anthropic/OpenAI surface with credential-free
  `ReqLLM.plan(model_spec, :chat, planning_options)` on the exact planning list
  above; Ollama and OpenRouter use
  their fixed rows because RequestPlan does not admit them. The owner retains
  the resulting fingerprint and requires the adapter's final Req method, URI,
  effective port, path, nil query and, where present, ReqLLM plan metadata to
  match it at the atomic dispatch claim. The pool is fully started before
  ReqLLM runs; the final request must also use the one-shot adapter, exact fixed
  Finch name and reference tag, and none of the routing substitutions the
  adapter refuses.
A failed guard at composition refuses `{:composition, :provider_module_replaced}`,
`{:composition, :ssl_key_log_enabled}` or
`{:composition, :req_default_options_unsupported}`, and an invalid address
refuses `{:composition, :provider_base_url_unsupported}`. The caller repeats
those checks before entering `ReqLLM.generate_text/3`, where a refusal is
`{:error, {:not_dispatched, "model_call_failed"}}`. A mismatch found by the
one-shot adapter is still refused before network activity, but is reported
conservatively as `dispatched_or_unknown` because the ReqLLM call has begun.
The prefix maps through the fixed table, never through `String.to_atom/1`. A
host mutation after a check is same-VM trusted-code interference; the final
adapter still closes the request-routing path it can validate.

**No streaming.** The adapter delivers the model's reply whole and reports no
progress deltas. Deltas are transient progress, never session truth, and the
streaming conformance suite already admits an adapter that declares
`streamed: false` with no deltas. Locked `generate_text/3` discards the outer
`Req.Response` headers when it returns the decoded `%ReqLLM.Response{}`. The
one-shot Req adapter therefore records only Anthropic's `request-id` or
OpenAI's `x-request-id`, as applicable, in the same sensitive caller's process
dictionary under the per-call tag; Ollama and OpenRouter record no header. The
caller deletes the key before generation and in an `after` clause on every exit.

On an exact successful response struct, metadata contains `usage` (or `%{}`),
`finish_reason`, that zero-or-one-element header list, and `error` only when the
response error is non-nil. The shared completion rule rejects that error and
`:error`, `:incomplete` or `:cancelled`; the shared tool-call validator reads
each buffered `%ReqLLM.ToolCall{}` that locked ReqLLM exposes; requires
`ToolCall.builtin?/1` and `provider_native?/1` both false; rejects atom- or
string-keyed error metadata still visible there; requires a non-empty binary id
and name and exact type `"function"`; decodes its binary argument JSON with
repair disabled; and accepts only a map. A visible provider-executed builtin or
provider-native call is not a replayable application call, fails the whole
ordered list and never becomes a local core tool request. Invalid binary JSON,
`null`, arrays and incomplete JSON that reach this seam do the same. ReqLLM's buffered builders run
before the seam: depending on the provider path they can generate a replacement for a missing id,
normalize missing, nil, empty or unsupported arguments to literal `"{}"`, force
type `"function"`, omit a malformed call, and remove earlier error metadata
(`provider/defaults/response_builder.ex:164-206`, `tool_call.ex:93-103`,
`provider/defaults.ex:1556-1571`,
`providers/openai/responses_api.ex:2415-2427`). Those erased distinctions are
not reconstructible here. The builtin flag remains visible on
`ToolCall.new_builtin/3`; an existing `%ToolCall{}` can retain provider-native
metadata (`tool_call.ex:106-178`,
`providers/openai/responses_api.ex:2322-2337`). The mapper accepts a visible
literal `"{}"` as an empty object and an omitted call executes nothing; only a
visible application call passes tool resolution, schema validation and policy. Text is
`ReqLLM.Response.text(response) || ""`; and the shared reply builder receives
delta count zero. Any other return, malformed response, rejected completion or
dependency-visible malformed tool call is the fixed started-call failure.
Before the mapped reply leaves the sensitive
caller, a recursive check of every provider-controlled binary in that
reply, including binary map keys, values, nested lists, assistant text, tool-call fields and
`provider_response_id`—rejects an exact occurrence of the resolved credential
and substitutes the fixed `dispatched_or_unknown` failure. This does not claim
to recognize a transformed or encoded derivative a malicious provider invents.

**Error classes:**
- A clean, proved refusal met before `ReqLLM.generate_text/3` is called is returned, never
  raised, as `{:not_dispatched, "model_call_failed"}`. That covers model build,
  a missing credential, a failed guard, context, tools and options, and an
  elapsed deadline. Missing candidate/proxy/pool proof is never clean refusal:
  it seals only this session and retains conservative failure.
- The locked process-local provider-lifetime registration and activation
  interval is the conservative exception. If core interrupts it, the callback
  emits no adapter result; the coordinator uses its existing provider-call
  failure or cleanup-unproved path. It is not retried even though the adapter
  authorized no network dispatch. Exact `:unmanaged` from
  `ProviderLifetime.starter/0` refuses before a candidate exists. Exact
  `:unmanaged` or `{:error, :provider_resource_refused}` from
  `ProviderLifetime.register/2`, with proved candidate `DOWN`, remains the
  pre-call `not_dispatched` form.
- Every return or raise from that call, `{:error, _}` and a non-2xx status
  included, is `{:dispatched_or_unknown, "model_call_failed"}`, as the companion
  classifies a started call
  (`apps/loopex_llm_reqllm/lib/loopex/llm/req_llm.ex:416-453`, citing ADR 0018),
  because the request may already have reached the server.

<a id="technical-adr-0039-tree"></a>
#### The Per-Call Process

Concept: [Context and decision](0039-ephemeral-embedded-profile.md#concept-adr-0039-decision).

1. **Authority-free candidate.** The callback first calls
   `ProviderLifetime.starter/0` (`provider_lifetime.ex:35-45`). Exact
   `:unmanaged` creates nothing and returns fixed `not_dispatched`. A managed
   callback first reserves the outstanding slot and completes session-owner
   attempt custody; only then it gives the opaque starter to an unlinked monitored proxy.
   The callback retains a one-use activation token. Candidate closure captures
   only callback/proxy PIDs, start reference and the earlier of the model
   deadline and 1,000 ms; no token, session cell, model request, option, key,
   pool, root or starter. Proxy and candidate reports are correlated in either
   order. The proxy executes only one `ProviderLifetime.start_child/2`, reports
   provisionally and exits normally after exact finish; it first tells the
   candidate `proxy_retiring`. Candidate accepts normal proxy DOWN only after
   that notice, and remains otherwise inert. Known candidate monitoring and
   exact normal proxy DOWN precede registration. The transferable starter
   matches the locked companion (`provider_bridge.ex:69-79,216-227`).

2. **Cleanup custody and core registration.** Callback first completes
   cleanup-only stage_model: exact candidate/proxy/stop/retirement identities
   committed at session owner, custody delivered directly to candidate,
   candidate acknowledgement to owner, then staging acknowledgement to callback.
   Staging uses a fresh cleanup-control deadline, not the model deadline.
   Callback next sends correlated `registration_pending`
   with the exact private stop reference, awaits candidate acknowledgement,
   then calls `ProviderLifetime.register/2` in that same callback. Candidate
   stores the stop reference and cancels short start expiry, but gains no call
   input or authority. The process-local registrar cannot be moved to another
   helper or given a synthetic timeout. Core's provider worker first retains
   the resource, then its guard registers it
   (`session_coordinator.ex:4172-4195`). Only exact
   `{:managed, retainer_pid, cleanup_grace_ms}` permits activation preparation
   with that tuple/token, session handle/cell and the already-staged retirement
   proof reference. Candidate records them and acknowledges while still inert.
   Callback next requests register_model carrying that proof reference, and
   requires its exact live activation-registration acknowledgement before
   distinct one-use `begin`. Cleanup custody was committed before the registrar;
   lost or expired managed acknowledgement cannot prevent empty retirement.
   Call inputs and work grants arrive only after begin. Missing acknowledgement produces no adapter result;
   core owns interruption/classification.

3. **Pre-registration failures.** Exact returned start refusal plus exact
   normal proxy DOWN and no candidate report is clean `not_dispatched`.
   Unknown/malformed/missing start reports or DOWN seal this session, withhold
   activation, kill known proxy/candidate and await exact DOWN at most 1,000 ms.
   Missing proof is conservative `dispatched_or_unknown`, never clean
   `not_dispatched`. A killed proxy cannot retract a queued Task.Supervisor
   start; any later candidate remains authority-free and exits on dead
   callback/proxy or expiry. A blocked proxy may outlive callback return but
   has no call input, cannot submit another start and retires on callback loss.
   Exact `:unmanaged` or `{:error, :provider_resource_refused}` registration
   with session-recorded cancellation preparation, proved candidate DOWN and
   final clean-cancel acknowledgement is clean `not_dispatched`; missing candidate
   DOWN seals this session and returns only conservative failure.
   `{:error, :provider_guard_unavailable}`, raise or malformed registrar return
   uses the fixed private exit `:provider_lifetime_registration_failed` after
   known candidate reap. Core catches/discards it as
   `{:error, :provider_call_failed}` (`session_coordinator.ex:4149-4152`).
   Missing proof seals the session before that exit. No global admission state
   is changed. The exact no-registration return is recorded before candidate
   kill, so its normal proof cannot race into unexplained provisional-owner
   loss. M6 defines correlated preparation/final acknowledgement and bounded
   DOWN reconciliation.
   After managed lifetime registration, any activation/admission refusal uses
   that same fixed private exit and leaves settlement to core; it never returns
   adapter `not_dispatched`, even when ReqLLM has not begun.

4. **Locked registration race.** Before `registration_pending` is acknowledged,
   callback loss ends the authority-free candidate. After that acknowledgement,
   callback DOWN before begin disables activation permanently but leaves the
   candidate inert and responsive to its stored exact core stop reference.
   It cannot exit merely because stop is not queued: core kills the callback
   first and sends stop later (`session_coordinator.ex:4573-4576`, `:4627-4634`).
   On callback DOWN before begin, the candidate always asks retire_model with
   its earlier cleanup-only handle and proof reference, even before managed
   preparation or core stop. The session owner accepts that exact known staging,
   provisional or managed census without awaiting a later
   activation-registration transition
   before retirement acknowledgement. Candidate remains alive and activation
   stays permanently disabled. It acknowledges a later exact core stop only
   after recording, then exits. If guard registration never committed, subtree
   teardown instead ends this already-retired inert candidate and its genuine
   DOWN clears outstanding with any reason. Empty retirement must not await a
   core stop that may never exist.
   Missing proof withholds acknowledgement. In the worker-retained/guard-
   unregistered interval, model settlement may precede authority-free
   candidate DOWN. This proves no registered provider-resource obligation or
   released input/authority, not candidate termination. Core's force cleanup
   can find callback pending slots and queued guard registrations
   (`session_coordinator.ex:4776-4849`), but cannot close every normal race
   without a kernel change. Complete session-subtree cleanup reaps candidates.
   Without a registered stop, this inert candidate remains beneath the session
   worker supervisor until complete subtree teardown. It has no call input,
   credential, pool or dispatch authority. Once guard registration committed,
   the exact stop handshake is required (`session_coordinator.ex:4621-4667`). Candidate never
   invents its own non-dispatch result.
   Before registration_pending, a staged candidate on callback loss first
   obtains empty retirement acknowledgement, then exits, including start-deadline
   expiry after custody delivery. During staging, known
   candidate DOWN before any registrar permission was issued can cancel only
   that exact reconciled empty start. The inert candidate does not trap exits;
   abnormal parent exit ends it. No delayed begin can reactivate a retiring or
   retired record.

5. **Registered cleanup owner.** At activation it traps ordinary exits, stays in a receive loop,
   never calls ReqLLM and holds only identities, census, deadlines/dispatch
   state and a bounded mapped result. It marks itself sensitive and processes
   exit reasons by shape without retaining raw failures. It directly creates
   and monitors one start-blocked request-free lifecycle root before granting
   pool setup. That root parents the anonymous supervisor, registers each
   returned PID with the owner before proceeding, performs setup and both
   inspections, and graceful teardown. A stuck dependency leaves cleanup
   unproved; killing a parent is not a descendant-proof substitute.
   Parent exit permanently disables activation and starts teardown; it is never
   ignored as permission to keep running.

6. **Sensitive caller.** For every provider the trapping active owner creates
   one atomically linked-and-monitored
   start-blocked caller, records it before begin and grants only while the
   session cell is open. The caller sets
   `Process.flag(:sensitive,true)` and
   `Logger.put_process_level(self(),:none)`, excludes its exact one-MFA inventory
   `[{Loopex.LLM.ReqLLM.InProcess.Caller,:run,1}]` through
   `Loopex.Trace.exclude_self/2` (`trace.ex:56`), and requires exact :ok before
   any key read. Its argument is credential-free. Exclusion/guard refusal
   reads no key and takes owned cleanup. Hosted callers alone read the selected
   variable and validate 1..65,536 bytes; Ollama reads none. Hosted and local
   callers may run in sessions with either tool preset and ambient variables.
   The caller catches raise/throw/exit, maps and exact-key-checks a reply,
   sends only that bounded reply/fixed class and then blocks until ended.
   Caller never traps exits. Immediately after spawn, the rest of the owner
   lifetime is inside a lexical try/after capturing that caller PID; after
   always issues its kill, even on unexpected normal return/catchable exit.
   Untrappable owner kill instead propagates its non-normal link signal.
   Ordinary successful result/stop still awaits exact caller DOWN first, and
   the session census requires that independent proof after owner loss.
   Neither kill request nor link delivery is synchronous termination proof.

7. **Tagged subtree and one shot.** The lifecycle root owns its anonymous
   DynamicSupervisor, pool supervisor and exact one HTTP/1 worker. All are
   recorded and monitored before caller start. Shared Req.Finch registries are
   infrastructure, not request owners. Final dispatch requires the session
   cell still open and the grant correlated to this admitted outstanding attempt, validated final route, exact registered worker/tag and
   owner's unused dispatch grant. Cell closure, owner loss or a spent grant
   cannot cause fallback or replacement dispatch.

**Cleanup.** Teardown is idempotent and owner-gated. Once the lifecycle root
exists, every later pool-child failure or partial start, terminal caller reply,
refusal, spawn failure or exit starts or joins it; no result or fixed error
returns merely because the pool or one-shot adapter was never reached. On the
transport path, after the Req adapter's direct worker call and checkout return,
it asks the owner to have the lifecycle root start teardown early and waits.
The owner requires the lifecycle root, anonymous supervisor, pool supervisor
and worker `DOWN` messages, plus disappearance of both tagged registry entries,
before releasing that adapter. The
caller then maps the response, sends the owner its reply and blocks. On a
pre-adapter failure it sends only the fixed reply and blocks, and the owner
performs the same proof. In either case the owner releases or kills the caller,
waits for its `DOWN`, and only then sends the fixed reply to the waiting
`complete/3` callback. The registered owner does **not** exit at that point: it
remains responsive while `complete/3` returns the model result to core. Core
then sends the coordinator's resource-stop message. With cleanup proved, the
owner registers its correlated clean-retirement reference with the session
owner, waits for the independent census proof acknowledgement, then sends
the exact core stop acknowledgement and exits only after
that handshake. This reply-before-stop two-stage order satisfies the
coordinator's requirement that the registered resource remain alive through
resource cleanup (`session_coordinator.ex:4397-4435`, `:4508-4513`). On the coordinator's
resource stop message
(`session_coordinator.ex:4627-4634`) or a deadline, it first makes every result
inadmissible, kills the caller and waits for `DOWN`, then starts or continues
the graceful lifecycle-root stop and proves the applicable root, owned-child and registry conditions
before acknowledging `{:loopex_provider_resource_stopped, stop, self()}`
(`:4641`), then exits. It never kills the lifecycle root or pool supervisor,
because that could bypass child termination. A missing `DOWN`, timed-out
graceful stop or remaining tagged registry entry withholds the reply or acknowledgement, and the coordinator's existing
unproved-cleanup path applies (`:4646-4652`). Before withholding proof,
the owner sets the session cell to cleanup-unproved and notifies its session
owner; no other session cell changes. Exact resource DOWN before the mandatory
acknowledgement is unproved, not a successful owner-loss cleanup.

**What the acknowledgement covers, and what it does not.**
- **The request runs in the caller.** The pool checks its single connection out
  to the caller, which performs the request's socket I/O
  (`finch/http1/pool.ex:42-74`). Killing the caller stops further I/O. On stop or deadline, the
  owner stops the pool only after caller `DOWN`, closing the race in which
  a still-running caller could invoke its recorded worker. The adapter never
  performs a lookup that can materialize a replacement. Bytes
  already handed to the operating system or a TLS sender may still leave; the
  call was already `dispatched_or_unknown`, so this creates no retry.
- **One network dispatch.** HTTP/1 has no lower-level read-only redispatch, and
  the owner's atomic claim permits only the first invocation of the Req
  adapter to call the recorded worker. `max_retries: 0` and `redirect: false` remain secondary
  controls. A transport failure before any bytes were sent can therefore be
  conservatively classified unknown, but it cannot cause a second send.
- **Owned teardown and transport drain are different frontiers.** NimblePool
  sends check-in asynchronously (`deps/nimble_pool/lib/nimble_pool.ex:461-471`),
  and its termination callback closes only idle resources (`:732-741`). A root
  stop can therefore race a check-in or the pool's caller-`DOWN` cancellation.
  On normal fresh-request return, Finch transfers the socket to the
  NimblePool process before `request/6` returns
  (`deps/finch/lib/finch/http1/pool.ex:314-328`;
  `deps/nimble_pool/lib/nimble_pool.ex:445,462`), so graceful pool shutdown
  closes its idle connection. Finch's checked-out cancellation callback only
  updates bookkeeping (`http1/pool.ex:295-302`); NimblePool then removes the
  original resource and invokes its termination callback
  (`nimble_pool.ex:770-794,916-925,1012-1022`). For a fresh checked-out request,
  that original resource still has `mint: nil` (`http1/pool.ex:178-186`), whose
  close is a no-op (`http1/conn.ex:242`). Caller death closes its socket;
  terminate_worker (`http1/pool.ex:287-293`) does not close a connection it
  never received. If root shutdown wins before
  check-in/cancellation is handled, the checked-out socket and OTP TLS
  controller may instead finish from caller ownership asynchronously.
  The acknowledgement proves the caller,
  owned root and pool gone and both tagged registry entries removed. It does not prove
  that checked-out transport has already finished. The release witness bounds
  server-observed EOF and TLS-controller drain after caller `DOWN`. No guarantee
  depends on a `Connection: close` header or peer behaviour, and the fixed TLS
  options prohibit reusable session state and key-log secrets.
- **Credential exposure is named.** During a call the request's bytes, key
  included, pass through the caller, TLS state for an `https` address and
  Finch telemetry metadata (`finch/http1/pool.ex:47-49`), which any handler the
  host installs can copy. After owned cleanup there is no tagged pool, reusable
  TLS state or result path. A checked-out socket and its OTP TLS controller may
  still drain. Under isolated release conditions the witness requires both gone
  within 5,000 ms of caller `DOWN`; runtime cleanup does not wait for or prove
  that threshold. They, the host environment and a host-made copy are outside
  the owned-lifetime proof and have the host-VM exposure the vision amendment
  accepts.

Nothing any of this holds can reach the session: the result path ended with
the caller, and the call is already `dispatched_or_unknown`. Those copies, and
whatever a host's handler copies, are the exposure the vision amendment
names.

**What the witness pins.** On both toolchain pairs, an isolated VM first warms
only shared Req and SSL infrastructure, then records every client process and
port created while one tagged call is stalled. Normal completion, stop and
deadline must leave the caller, lifecycle root, anonymous supervisor, pool
supervisor and exact recorded worker dead and
both tagged pool registry entries absent before a provider result or successful cleanup
acknowledgement. Separately, under the isolated release witness the server must
observe EOF and every call-created TLS controller must drain within 5,000 ms of
caller `DOWN`; the witness records that interval rather than treating it as
part of the acknowledgement or a runtime proof.
A seam that fails pool-child startup after the root
exists, including after an owned child or either registry entry appears, must leave
every owned child and the root dead and every Loopex-created entry absent before
the refusal returns. When the credential or a guard changes after pool
creation, ReqLLM request preparation fails before the one-shot adapter, the
final route is refused before delegation, or caller spawn is made to fail, the
same applicable process and registry proof holds and no connection is accepted.
The witness records dependency and TLS lifecycles but does not
assert a fixed process count or universal heap inspection. Separate TLS
1.2-only and TLS 1.3-only servers prove two sequential calls do not resume a
session. Positive controls use the same TLS servers: Mint defaults demonstrate
TLS 1.2 resumption. The TLS 1.3 fixture server explicitly enables
`session_tickets: :stateful` for both the positive control and production-client
comparison; server defaults are disabled too, floor `ssl.erl:4277-4309`, current
`ssl_config.erl:991-1025`. The first TLS 1.3 control explicitly uses
`session_tickets: :manual`. The socket owner must receive
`{:ssl, :session_ticket, ticket}` with a map ticket within its deadline. It
performs exactly one second connection with
`session_tickets: :manual, use_ticket: [ticket]` and requires
`:ssl.connection_information(socket, [:session_resumption])` to report true
on the client or relayed accepted-server socket. No ticket is logged. Pin the
actual handlers, floor `tls_gen_connection_1_3.erl:361-400`, current `:371-410`,
and resumption information floor `ssl_gen_statem.erl:1971-1977`, current
`:1934-1940`; do not use the floor documentation's stale nested-ticket example.
Missing/malformed ticket, timeout or non-resumption fails or is unavailable
evidence, never a reconnect retry. This proves a resumed connection before testing the
production `session_tickets: :disabled` case. Mint strips `reuse_sessions`
for TLS 1.3-only (`ssl.ex:473-485`), so its defaults are not falsely credited
as a TLS 1.3 positive control. Production client versions stay unchanged;
only test servers are protocol-restricted. An explicitly TLS-1.3-only client
would make OTP reject the production `reuse_sessions` option. TLS 1.3
non-resumption rests on `session_tickets: :disabled`, OTP's client default,
not on that TLS 1.2 option (floor `ssl.erl:4259-4261`; current
`ssl_config.erl:964-968`). The TLS 1.2 control waits for the first handshake's
asynchronous cache installation before its single second handshake. A test-only
cache callback in the isolated VM delegates unchanged to OTP's default cache
and emits credential-free readiness after the matching client host/port/session
update; server cache installation is likewise observed before reconnect.
Missing readiness or a non-resuming control fails or is unavailable evidence;
no repeated handshake retries manufacture a pass. Two concurrent same-origin calls prove distinct tags and that cleaning
one does not disturb the other.

<a id="technical-adr-0039-public"></a>
#### Admission and Packaging Mechanics

Concept: [Public contracts](0039-ephemeral-embedded-profile.md#concept-adr-0039-public).

The Concept table owns the address grammar, first-failure order, named refusals
and host release `:load` requirement. The guard checks and shared-start table
below prove that public contract. M6's paired public contract owns the full
composition/invalid-option vocabulary, helper schema and embedded/command
lifecycle. This ADR adds no alternate public codes in Technical depth.

The final Req request refuses alternate-pool/router options `:inet6`,
`:pool_max_idle_time`, `:unix_socket` and `:finch_request`, in addition to
`:connect_options`, external `:into`, compression, noncanonical Finch
request/build options and adapters. Req selects a custom pool for the first
three connection-configuration cases (`deps/req/lib/req/finch.ex:545-607`);
`unix_socket` changes build routing (`:153,225-228`), and `finch_request`
invokes a callback or rewrites the request (`:253-260`). The one-shot direct
worker adapter never delegates to those alternate entrypoints.

The submitted HTTPS transport input is exactly the three retention options.
The root compares the entire stored Registry value to the single extracted
`expected_pool_config` map after validating the fixed projection above.
Finch expansion must add exactly its pinned cast defaults and nil
`ssl_key_log_file_device`; any extra/missing member or nested transport option
refuses. A containment check is insufficient (`deps/finch/lib/finch.ex:525-580`). Its default connect timeout
is 5,000 ms (`:16,537`); the external owner deadline bounds a stalled connect.

**Host hygiene.** `ReqLLM.Application.start/2` reads `:load_dotenv` (default
`true`) and loads `.env` from the working directory (`application.ex:25-31`).
`loopex_llm_reqllm` declares `req_llm` and its direct exact `req` and `finch`
dependencies with `runtime: false`. They remain compile-time and code
dependencies but none enters the edge application's automatic start list, so
every build carries the three modules without starting their applications
before Loopex's guards. The adapter explicitly lists `:logger` alongside
`:crypto` in `extra_applications`, so removing runtime ReqLLM does not remove
Elixir Logger from either escript's application tree. Both escripts must carry
`logger.app` and Logger BEAMs and actually start the dependency set; inventory
alone is insufficient. The companion and a host OTP release list all three as
`:load`, as the developer guide states. The companion worker already starts
ReqLLM and its dependencies itself after its settings
(`provider_worker.ex:43`, `:78-79`).

**The start step.** Before an admitted controller start, require unset
`SSLKEYLOGFILE`, empty Req defaults and `TIDEWAVE_REPL != "true"`.
The last condition is fixed `req_llm_tidewave_enabled`; ReqLLM would otherwise
start the optional listener (`application.ex:43,152-162`). Already-started host
applications may have opened files/listeners earlier; Loopex does not undo
those host effects.

The temporary `ReqLLMStarter` service implements M6's serialized provenance
protocol. Its worker performs application reads/configuration/start only and
receives no session data, selected key or effect authority. One caller's
declaration never authorizes another: only matching declaration cohorts join.
Validation-only workers have no start authority and write no persistent key.
For an actual admitted start the service retains initializer identity before
a one-use start grant. Its unlinked worker survives service loss after that
grant. Only an exact successful start list containing `:req_llm` lets that
worker record `{:started, req_llm_supervisor_pid, initialization_ref}` before
reporting; no start intent proves origin. Capture the exact registered
`ReqLLM.Supervisor` (`application.ex:45-46`) and require it live with dotenv off.
Running reuse requires that same live PID or explicit host declaration, never
bare VM-lifetime start history. Service monitors it and each validation cohort
rechecks current identity. A host stop/restart creates a new incarnation; old
provenance is only history for guarded stopped-instance restart. Host mutation
between controller return and PID capture remains trusted-host interference.
Recreation observes that exact worker through DOWN, then validates actual state
without waiting on a result sent to the dead predecessor. Preparing alone is
not Loopex-originated application-start provenance. One caller's
5,000 ms waiting deadline/death does not cancel admitted shared work. Service
recreation reconciles positive provenance before reuse. Running without that
proof requires explicit host declaration and dotenv-off. An unresolved operation
or worker/service loss returns `req_llm_start_failed`; later declaration or
host correction can resolve it without VM restart. No service crash loop
exhausts session-supervisor restart intensity.
The complete service message/schema and recovery witnesses are owned by the
M6 plan pair; this ADR introduces no alternate shared-start algorithm.

| State/precedence | Public result |
| --- | --- |
| Pre-start defaults/keylog/Tidewave guard fails | Its named guard refusal before any dependency start |
| Host declares already-started but ReqLLM is not running | `req_llm_host_declaration_invalid` |
| Running or previously Loopex-started ReqLLM has `load_dotenv != false` | `req_llm_dotenv_enabled`; no host mutation overwritten |
| Running, .env off, exact live supervisor PID matching retained Loopex provenance or explicit host declaration | Proceed |
| Running, .env off, no matching-incarnation provenance or declaration, including a host restart after an earlier Loopex instance | `req_llm_already_started` |
| Not running, safe prior provenance, .env off | Service performs admitted restart |
| Not running, no prior provenance/declaration | Persist .env off, then perform admitted first start |
| Start failure, unresolved provenance, service loss or wait expiry | `req_llm_start_failed`; later requests may reconcile; no session/root/key/effect was released |

`Application.put_env/4` with `persistent: true` keeps .env off across reloads.
Loopex never restores it or stops ReqLLM because other host components may use
it. Host mutation/declaration races remain trusted-host interference.
`:llm_db`, `warn_unverified_models` and all other settings are unchanged.

<a id="technical-adr-0039-relation-0019"></a>
### Shared-State and Diagnostic Facts

Concept: [What changes relative to ADR 0019](0039-ephemeral-embedded-profile.md#concept-adr-0039-relation-0019).

These facts are for ReqLLM 1.24.0, verified in `deps/req_llm`.

**What starting ReqLLM does.** Starting `:req_llm` starts `ReqLLM.Supervisor`,
with its Finch pool `ReqLLM.Finch`, `ReqLLM.TaskSupervisor` and a token cache.
It also initializes a provider registry in `persistent_term` and a named ETS
table. All of these are VM-global and named, so one ReqLLM serves every user in
the VM. Req's application also keeps the `Req.Finch` worker and pool-supervisor
registries and default infrastructure alive. M6 uses those registries to route to the tagged user-managed
pool, but uses neither shared default pool for a model call.

**Paths that can carry the request, and a hosted provider's credential, into
the host:**
- the host environment, for as long and as broadly as the host keeps it;
- a log line written by the sensitive caller is suppressed by its process
  level, but a call-owned pool or OTP TLS process may emit through the host's
  logger;
- a crash report from the caller, tagged pool or an OTP TLS process handling
  the connection;
- a telemetry handler the host installs: Finch's events carry the request,
  headers and body included (`finch/http1/pool.ex:47-49`), and ReqLLM's carry
  payloads when configured to; handlers run in the caller but may send data
  anywhere;
- an `erl_crash.dump`, which omits the sensitive caller's stack, messages and
  dictionary but not all dependency-process state.

The caller and tagged pool are gone before a provider result or successful
cleanup acknowledgement. `Req.Finch`'s remaining registries and supervision
infrastructure holds no request, connection or credential. This is not a proof
that arbitrary host memory has been erased or that checked-out transport has
already closed: a host handler can keep what it copied, and the call's socket
and OTP TLS controller can drain asynchronously. The isolated release witness
requires both gone within 5,000 ms of caller `DOWN`; runtime cleanup does not
wait for or prove that threshold.

The companion suppresses all of these by running ReqLLM in its own BEAM. The
ephemeral profile does not; the `ask` command sets the primary logger level to
`:none` and disables crash dumps for its own VM, and a library host owns the
rest.

<a id="technical-adr-0039-vision"></a>
### The Vision Amendment

Concept: [The vision amendment](0039-ephemeral-embedded-profile.md#concept-adr-0039-vision).

Acceptance applies all seven affected places together. The scope paragraph
below is the exact common credential exception to insert in each named place;
its lifetime, tool audience and session containment are identical everywhere:

> ADR 0039's ephemeral profile uses a host-VM provider path. The host
> environment and host-made copies have host-owned lifetimes and audiences.
> During a call, the sensitive caller, provider HTTP/TLS state, crash reports,
> crash dumps and host-installed telemetry/logger handlers can observe the
> selected credential. Loopex proves its caller and tagged pool subtree gone
> before a provider result or successful cleanup acknowledgement. A checked-out
> socket and OTP TLS controller may drain asynchronously afterward, without a
> result route. The isolated release witness requires them gone within 5,000 ms
> of caller DOWN; runtime cleanup does not wait for or prove that threshold.
> TLS reuse, tickets and secret retention are disabled; credential-bearing
> endpoints are HTTPS-only. Hosted and local tools are permitted with ambient
> credential variables. A host-authorized tool or trusted host code may read,
> copy or disclose those values, including through ordinary tool-result planes;
> this profile provides no structural secrecy from that audience. Loopex does
> not inject provider credentials into jobs or its own diagnostics, and rejects
> the exact selected value from a mapped provider reply before publication.
> Cleanup uncertainty seals only the affected session; there is no VM gate,
> lease, quarantine or VM-restart lockout. Shared-service outages remain
> possible. The durable profile retains its separate-process credential rules.

| Place | Placement and context owned by that section |
| --- | --- |
| `docs/vision.md` §12 | After the credential exclusion, insert the common exception and clarify that the survival guarantee governs profiles represented as durable. ADR 0039's declared non-durable history ends with its runtime; there is no recovery/migration surface or durable listing. This applies Technical §12.2's existing in-memory posture. |
| `docs/vision.md` §16 | After observability's secret-exclusion sentence, insert the common exception, including host telemetry and logger handlers, crash reports and crash dumps; Loopex-owned provider observability still excludes its selected key. |
| `docs/vision-technical.md` §6.1 | The host custody cell adds environment resolution just in time at the approved model boundary. Insert the common exception beside the row and link §12.7 for lifetime and audience. |
| `docs/vision-technical.md` §6.2 | Insert the common exception after diagnostics-plane definition. Host provider crash/telemetry/logger copies remain host diagnostics; host-authorized tool disclosures follow the ordinary tool planes and their existing retention. |
| `docs/vision-technical.md` §12.7 | Insert the common exception after the excluded-plane list. Add an environment-held-value clause to narrowest lifetime/audience: that environment's lifetime and audience are the host's. Preserve reference-only runtime state, just-in-time selected-key resolution and the mapped-provider-reply check. |
| `docs/vision-technical.md` §23 | Append the common exception to the prohibited-plane criterion; require the selected-key model canary witnesses, session-only failure-containment witnesses, tool-audience disclosure witness and separate 5,000 ms release transport-drain witness. |
| `AGENTS.md` credential/context non-negotiable | Append the common exception after the scoped hand-secret clause. Its change is part of the explicit acceptance packet; this proposed file does not edit the accepted authority. |

This common exception is prospective text. The ADR remains Proposed until its
acceptance and all seven affected authority texts land together. The
2026-09-27 maintainer design approvals are not that acceptance.

<a id="technical-adr-0039-proofs"></a>
### Adapters and Proofs

Concept: [Observable consequences](0039-ephemeral-embedded-profile.md#concept-adr-0039-consequences).

| Obligation | Witness |
| --- | --- |
| The memory store is a store | The store conformance suite's `:memory` kind is bound to `Loopex.Store.Memory` itself and passes unchanged |
| The in-process adapter is a model | Mapping, option and error tests run against a scripted ReqLLM transport. The model streaming conformance suite runs against it with `streamed: false` and no deltas. Real-provider lanes call a local Ollama model and one hosted provider |
| The committed deadline remains authoritative | Pure vectors freeze one native offset and cover positive and negative offsets, separated clock samples, the unsigned-64-bit maximum, one positive native tick rounded up to 1 ms, zero and negative remainder, and the 1,000 ms cap; no full durable duration or native remainder reaches an OTP or Finch timer. Caller-result vectors require the exact native completion timestamp, admit an already-queued in-time result in the expiry zero-wait race, reject a late timestamp and make every later result inadmissible |
| The guards and dispatch fence hold | At the sensitive caller, an absent, empty or greater-than-65,536-byte selected hosted credential; at their stated boundaries, a replaced provider module, a set `SSLKEYLOGFILE`, a non-empty `:req` `:default_options` (including an `auth:` default and a plugin), `TIDEWAVE_REPL="true"` before a Loopex-owned ReqLLM start, an unsupported or userinfo-bearing base URL, plain HTTP for any credential-bearing provider, and each final-request routing substitution refuse. Composition never reads the selected hosted credential value; the caller's value refusals accept no connection and take owned teardown. In a fresh VM the fixed provider table and pre-start global guards require no registry; SSL and Tidewave checks run before ReqLLM or Req starts; the hygiene decision initializes the registry; and only then do exact module verification, default-address lookup and address normalization run. Thus the default Ollama composition succeeds while a replaced module still wins over an address fault. The named key-log file is not created and no Tidewave listener opens. With host-started dependencies, a set key-log variable causes refusal and the call-owned pool neither opens nor appends to the file, without claiming what the host did earlier. ReqLLM application or catalog base URLs and its Finch settings cannot change the explicit origin or tagged pool. Anthropic and OpenAI route planning calls literal `ReqLLM.plan(model_spec, :chat, planning_options)` with the exact credential-free generation-option list; `generate_text/3` follows that chat path and adds only the hosted credential. Each prepared request names `OneShotHTTP1`, `Req.Finch`, the exact reference tag, optional bounded `pool_timeout`, exact credential-free private context, `max_retries` 0 and `redirect` false, with no pool configuration mixed into the named `finch` request option. Finch telemetry receives neither private owner context nor owner PID; the non-secret routing tag and exact recorded worker PID remain visible. A returned Req request regains the private context only so a retry reaches the owner fence. The submitted pool input has exact HTTP options and, for HTTPS only, the exact three nested TLS retention options. The entire stored Registry value equals the single extracted and validated expanded expected_pool_config, including exactly pinned cast defaults and nil ssl_key_log_file_device; extra/missing members or transport options refuse, never a containment-only check. Each final option inet6, pool_max_idle_time, unix_socket and finch_request is independently faulted and refused; they cannot select another pool or route. Forced retry, 429, 529, redirect and closed-transport cases get at most one dispatch grant, accepted connection and request-start marker; a second adapter invocation is refused by the grant before pool lookup or network activity, and no response is cached. The internal collector accepts exactly 8,388,608 response-body bytes, halts fixed-length and chunked bodies at the next byte with `model_response_too_large`, and refuses a content-encoded response without decompressing it |
| Credentials stay out of Loopex's planes | With tools not deliberately reading ambient values, each provider-variable canary stays absent from adapter-produced committed records, events, progress, diagnostics/trace, runtime/coordinator state, sensitive owner retained state, owner crash reports and Loopex logs on ordinary reply, error and request-bearing caller crash. Sensitive process_info queue/dictionary is not evidence. A test-only owner state seam returns a boolean scan of actual retained state; a deliberate canary insertion positive control must detect it. No owner-mailbox absence claim is made. Every provider-controlled mapped binary, including binary map keys, nested values, text, tool-call fields and provider_response_id, is faulted with an exact-key echo and discarded as fixed started-call failure. Trace witnesses see the credential-free pre-exclusion call and a nonsensitive control, but no raw caller trace after exact exclusion; refusal reads no key. Hosted/local compositions with active presets and supported key variables set succeed; a policy-authorized tool deliberately reading a canary demonstrates the named host-tool disclosure exception through ordinary output. Existing executor environment semantics are preserved, not scrubbed. No arbitrary heap erasure or absence from host copies is claimed. |
| Session failure is contained | Every session has its own opaque lifecycle cell and tagged calls. Every model and executor grant checks open0 and reconciles outstanding attempts with the M6 composition session owner before effect authority. Callback reserves outstanding before any proxy and custody transfer is faulted. Clean managed retirement requires nonce/phase proof plus exact owner DOWN; callback DOWN alone never clears it. Delay owner-DOWN delivery between a normal model result and tool admission: the correlated reconciliation waits/processes the existing exact proof and normal tool use succeeds. Withhold proof, owner DOWN, custody reply or reconciliation reply: only that session seals3 and outstanding remains1. Stop sets1; missing provider/proxy/candidate/root proof sets3 before notification/return; exact proof alone sets2. No1/2/3 transition reopens0. Withhold failure notification and suspend the session owner: same-session model/tool admission still refuses. Prove already-granted effects retain their group/receipt obligations. Concurrent hosted tools and ambient variables are permitted. Fault one session cleanup and show another hosted/local session continues through an independent cell/pool. Shared-service loss is separately reported and is not mistaken for per-session confidentiality or availability isolation. |
| Its cleanup owns the call | On both toolchain pairs, local HTTP, TLS 1.2-only and TLS 1.3-only servers deliberately keep their side of a completed connection open. The owner-candidate start witness proves exact `:unmanaged` starter acquisition creates no proxy or candidate, while the managed path passes the opaque starter only to an unlinked proxy and permutes ready/grant, proxy result, candidate report, `finish`, `proxy_retiring`, proxy `DOWN`, stage_model commitment, direct custody delivery/acknowledgement, `registration_pending`, activation preparation/registration and `begin`; it faults every missing, late, duplicated, replayed, malformed, mismatching and abnormal form. It covers wrong stop reference and retainer tuple, callback death before disclosure, after disclosure, during registration, after managed return and on both sides of `begin`, plus core stop before and after managed return. Suspending the locked owner `Task.Supervisor`, expiring and killing the proxy, then resuming it may materialize an undisclosed request-free candidate; that candidate receives no `begin` and exits on its first scheduled dead-proxy, dead-callback or expired-deadline step without a session-cell capability, root, caller, credential read or dispatch. The worker-retained/guard-unregistered witness lets model settlement precede candidate `DOWN` and proves the result has no registered provider-resource obligation. When custody was staged, genuine pre-begin callback DOWN records empty retirement immediately while the candidate remains alive; session-subtree termination then produces real candidate DOWN, clears slot 2 and permits successful stop_session/1 with root removal. Lost direct custody acknowledgement permits that empty retirement but neither registrar entry nor work; late acknowledgement cannot reopen the record. After registration_pending, genuine callback DOWN disables activation but leaves the candidate responsive for the later exact core stop. Cleanup-only staging and direct candidate custody acknowledgement precede core registration. Fault staging delivery/acknowledgement loss and every death order. Core guard commitment before managed return, absent preparation/register_model, expired activation registration and lost acknowledgement still permit exact provisional empty retirement, core acknowledgement and owner DOWN without false sealing. Exact no-registration cancellation is recorded before kill; reordered DOWN/final acknowledgement cannot turn proved cancellation into unexplained owner death. Queued activation cannot recreate a retired record. No branch uses a registration fallback timer or invents adapter `not_dispatched`. An exact returned start refusal plus normal proxy `DOWN` remains clean `not_dispatched`. Normal completion, stop and deadline after exact managed registration, each before headers, mid-body and after the body, prove caller, lifecycle root, anonymous supervisor, pool supervisor and exact recorded worker DOWN plus both tagged entries absent before the callback returns a model result; the registered cleanup owner remains live through core's stop handshake, then exact acknowledgement and owner DOWN precede coordinator publication. Separately, under isolated release conditions the server observes EOF and every call-created TLS controller drains within 5,000 ms of caller `DOWN`; runtime cleanup does not wait for or prove that threshold. Every exact `:unmanaged`, `{:error, :provider_resource_refused}` and `{:error, :provider_guard_unavailable}` form, plus raised and malformed lifetime registration, starts no pool, caller or credential read. Exact `:unmanaged` or `{:error, :provider_resource_refused}` returned from registration with candidate `DOWN` returns fixed `not_dispatched`; if that still-start-blocked candidate's DOWN is missing, the affected session is sealed and only conservative failure is permitted; no not_dispatched result is invented. Guard-unavailable, raised and malformed registration forms retain the locked core-owned conservative result. Once lifetime registration succeeds, a missing owner or child `DOWN` instead withholds success and cleanup acknowledgement and takes the unproved path. A failed or partial pool-child start after root creation removes every owned child, the root and every Loopex-created registry entry before refusal. Setup and dispatch-time inspection run in the registered lifecycle root with no helper process; a stuck inspection withholds dispatch and fixed refusal, and cannot return success unless cooperative teardown proves that root and its descendants gone. Credential or guard loss after pool creation, request-preparation failure, final-route refusal before the direct worker call and caller-spawn failure produce the applicable process and registry proof with no accepted connection. A request body larger than 64 KiB succeeds over HTTP and TLS; the separate response-boundary witnesses are stated above. A close during upload produces at most one accepted connection and request-start marker and a `dispatched_or_unknown` result. Sequential production TLS calls never resume a session. Same-server positive controls prove TLS1.2 resumption with Mint defaults and TLS1.3 resumption with stateful-ticket server, manual client receipt of the exact map ticket and exactly one use_ticket reconnect; an incapable server is unavailable evidence. Two concurrent same-origin calls have distinct tags; stopping one leaves the other to complete, and each removes only its own pool. An isolated-VM lifecycle census records every call-created client process and port without fixing a count or claiming arbitrary heap erasure. Seams that withhold a registered caller, lifecycle root, anonymous supervisor, pool supervisor or exact worker termination, or leave either tagged registry entry take the unproved path and return no success; transport drain beyond 5,000 ms fails the release lane but is not a runtime acknowledgement condition |
| Hygiene holds | Direct embedded and built-escript creation cover already-started, exact success/error, malformed/late reply, abnormal/missing worker DOWN, bounded refusal, late application-controller completion and concurrent first calls. Bootstrap uses one authority-free monitored worker and 5,000 ms decision plus 1,000 ms reap; no session input or root authority reaches it. Escript app:nil reaches main before a Loopex application start; invalid ask starts no project application, ephemeral creation follows the bounded path, durable ask uses application_start_failed and legacy commands preserve exact startup/error/status. Combined faults preserve workspace/skill/provider/pre-start-guard → bootstrap → shared hygiene precedence. Generated application lists omit runtime:false deps, escript embeds their code, fixture host/companion releases list req_llm/req/finch as load and boot stopped. No .env is loaded and Tidewave true refuses before first start. Every startup table branch runs through ReqLLMStarter: joined requests start once, one waiter expiry/death never cancels service, suspended controller return is later reconciled, service/worker loss and restart retain safe provenance or refuse fixed startup failure. No uncertain branch poisons independent sessions or requires VM restart. Temporary service crash loops never exhaust the session parent's restart budget; later creations recreate the service within their own bound. Already-running validation writes no persistent keys. Unknown or different-incarnation running origin requires explicit host declaration rather than stale-intent/history promotion, and current waiters fail fixed on service/worker loss. Undeclared host start, false declaration state, .env reenabled and restarted dependency are faulted. Existing sessions may suffer an actual shared-dependency outage; the witness reports it. llm_db/warn settings stay unchanged, persistent .env-off is not restored, and shared default pools contain no per-call request/key. |
| The composition bootstrap has one bounded owner | One authority-free monitored bootstrap worker is faulted before/after its controller submission, with requester death, delayed/malformed/reordered reply, normal/abnormal/missing DOWN and both deadline races. In-time success plus normal worker DOWN alone permits creation; missing proof yields the fixed bounded startup refusal with no root or session input/authority. Late controller completion cannot publish a handle and later calls reconcile state. Built escript grammar/profile/startup branches retain their exact witnesses. No guard/worker double-handshake or VM poison is required. |
| Host catalog settings remain host-owned | M6's named in_process_catalog_test.exs cold-file/overlay and cold GitHub ReleaseStore fixtures preserve source options and metadata/epoch/cache through call cleanup and subsequent reuse. Source-local Req adapter options intercept only catalog traffic, check synthetic GH_TOKEN/GITHUB_TOKEN headers internally and emit fixed Booleans; no global Req defaults or new dependency is needed. A selected provider key supplied only after the blocked catalog fetch must reach the actual model call. Forced packaged metadata, omitted overlay or deleted retained state/cache fails the corresponding control. Separate extracted-code witnesses prove the default compiled catalog; real-provider lanes remain required. |
| Escript base startup is distinguished | Mix starts its embedded Elixir base before `main/1`; every no-start claim here means no Loopex project application. Invalid ask forms leave every Loopex `.app` stopped. A valid ephemeral form leaves `:loopex_cli` stopped until the bounded composition path starts its dependency graph. Durable and legacy forms start the exact M6 CLI graph with ReqLLM, Req and Finch still load-only; durable ask uses its fixed-diagnostic helper, while legacy commands use the exact-Mix-compatible helper |
| The companion's valid path is preserved | Every companion suite passes after the shared mapping is extracted. Valid application-call request and reply vectors stay byte-identical, while a malformed binary argument payload that reaches the buffered `ToolCall` seam now takes fixed post-dispatch failure instead of becoming executable `%{}`; visible provider-executed and provider-native markers likewise fail instead of becoming local requests; fixtures prove no local tool dispatch. Vectors separately pin the locked dependency's earlier normalization: replacement ids for missing provider ids and literal `{}` for the provider paths that erase missing, nil, empty or unsupported arguments, omitted malformed calls, forced function type and stripped error metadata are not claimed as mapper refusals. The M6 timer-safety fix makes ReqLLM's internal total, stream-idle and receive waits infinite so the unchanged coordinator's sliced committed deadline remains authoritative across the newly exposed unsigned-64-bit durable bound; protocol and durable formats do not change. The durable profile refuses an `ollama:` model |
| The profile is ephemeral and says so | After proved cleanup and successful recursive removal, including the owner-exit path, no file remains under the profile's temporary root. An unproved cleanup or failed root removal returned to a caller keeps and names the root; an owner-exit path with no waiting caller emits it only to the host logger. Standalone `ask` suppresses that logger, so the named post-timeout background-drain limitation can leave the retained root unnamed. The result carries `profile: :ephemeral`, and `ask`'s JSON carries `"profile"` |
| The embedded API is bounded and coherent | The M6 ephemeral API witness proves the prompt refusals and exact 32,768-byte limit; every completed result and non-completed terminal observation; both timeout and post-admission `session_unavailable` no-ending snapshots with the same bounded text, tool and shadowed-skill projection; nullable definition ids for unresolved tools; the defensive 64 KiB answer projection and 256-entry tool-result projection with their truncation flags; the closed pending-interaction shape and full post-`Interaction.view/1` validation, including minimum, maximum and out-of-domain `turn` and `expires_at` values; every answer-then-defer transition through ADR 0024's ceiling; the one-shot `interaction_requires_session` result; timeout continuation and the later `last_result/1` transition; and `history/1`'s 256-entry, defensive 64 KiB-per-text limits, ordering and truncation flags. Concurrent stop never publishes a stale question and replies to a still-waiting ask or answer with a terminal observation or the `session_unavailable` no-ending snapshot, without adding an attachment reader. Stop, retryable and permanent failed-stop states, and caught session-path failures prove every cleanup obligation, every precedence case and the kept-root contract; a pending interaction followed by an unproved stop is retained exactly in `cleanup_unproved.ending`. A timeout followed by background-drain failure proves that no second snapshot is published, later calls are bare-unavailable, cleanup ends the poll and owned resources when proved, and an unproved root is only host-logged and can be unnamed under standalone `ask`. Adversarial terminal and wall-clock numeric values prove the projector never exposes an out-of-domain public member. A forced unmarked owner crash proves the separately named bare-unavailable, no-cleanup-proof limitation |
| The `ask` machine contract is closed | The M6 command witnesses prove the grammar, profile-specific default model, profile selection, exact JSON member and per-outcome detail sets, run-local text and tool provenance and order, literal shadowed source ids, nullable unresolved tool ids, decimal values beyond `2^53`, every Loopex-owned exit status, the durable `cleanup: null` and resumable-state meaning, and zero standard-output bytes on pre-run refusal and on an unmarked owner failure with no public cleanup proof, before observation or after a terminal observation. Ephemeral JSON is derived only from the public observation or no-ending snapshot plus the mandatory stop return; timeout and caught post-admission session loss render the two fixed `no_ending` reasons, while a bare-unavailable stop takes status 1 and emits no object. An ordinary provisional result must be followed by exact worker `DOWN` through the 1,000 ms kill-and-reap protocol before stop or rendering; withheld `DOWN` hard-halts status 1 with no output or cleanup claim. A real stalled call proves that the main process receives the first signal, calls stop while a monitored worker remains in `ask/3`, drains its one reply and renders once. A pre-handle signal is latched, forwarded and reaped but retains the platform child status without a Loopex cleanup or output promise; second-signal and backstop cases remain named hard kills |
| The interrupt admission race is closed | Exact ask-mode installation precedes worker start, is bounded and returns the exact `:erl_signal_server` manager PID; install refusal, duplicate claim, replacement or manager loss stops the new session, emits no result and exits 1. A provisional worker result stays protected through exact `DOWN` and mandatory stop. One synchronous correlated finish call on that manager serializes with signal callbacks and returns ordinary or interrupted before it disarms; fault witnesses race a first signal before, during and after stop and prove only one branch renders. A missing or malformed finish reply, handler loss or manager loss emits no result and exits 1. First-notice witnesses suspend the monitored worker before owner registration, after registration but before grant, and after grant. The pre-registration branch permits successful stop plus bare `session_closed` or unavailable, emits no object and invents no `no_ending`; every branch performs one stop and at most one render before exit 130, proves worker `DOWN` within its reap bound or takes the hard halt. Direct `SIGTERM`, `SIGHUP` and `SIGQUIT`, plus launcher-forwarded terminal `SIGINT`, share one handler path. It accepts only its fresh manager PID/reference notice, ignores forged, stale, old-manager and replayed notices, disarms its backstop on exact finish or main `DOWN`, and hard-halts only on a later handled signal or backstop expiry while stopping. Launcher fixtures close the pre-child lost-signal window without asserting status 130 |
| Temporary-root ownership is conservative | Exact claim-return witnesses distinguish owned root from lost mkdir result. Ordinary failures name root_ownership:owned. Loss after the mkdir grant but before exact return names unknown and never deletes/retries the possible path. Missing actor/subtree proof retains session_subtree and prevents root removal. Only all earlier resource proofs reach root_removal. Side-effect-free candidate preparation plus exact actor DOWN proves no filesystem mutation; missing DOWN seals only that session and preserves the unproved census. JSON/fixed diagnostic projections preserve ownership, reached obligations and startup cause. There is no gate release phase. |
| Base URLs have one canonical grammar | Vectors cover omitted, explicit default and explicit non-default ports; lowercase schemes; canonical IPv4; lowercase and uppercase-input ASCII DNS; normalized origin and path; and provider defaults. They reject uppercase schemes, IPv6, Unicode or percent-encoded hosts, userinfo, empty or malformed authorities, non-canonical numeric ports, ports 0 and 65,536, query, fragment, dot segments and every path spelling outside the stated grammar before a root or credential read |
| No default authority | Composition without `:policy` refuses with `host_policy_required` |
| Skills are truthfully named | A `.agents/skills/<name>` directory in the workspace is `project:<name>`; a directory outside is `user:<name>` with its content digest; any other workspace directory refuses; a shared name admits the project skill and reports the user skill as shadowed; the same holds under `ask --state-root`. `ask` passes the helper's explicit manifest, even when empty, through the released `resource_manifest` option and never discovers project context. A direct host can reproduce the path by passing the helper's `result.manifest` through one released composition bracket, which retains it once, then issuing ADR 0025's admission and canonical ordered activation commands; the raw durable constructors have no `skill_directories` option and submit no session command |
| Rollback holds as stated | A public embedding host using shipped `Loopex.AppServer.Policy.Ask` and unchanged default revision `0.2.0` writes a pending interaction under the candidate; a same-policy `v0.2.0` successor recovers and answers it, and the reverse holds; a `loopex.grep` call not yet dispatched, resumed under `v0.2.0`, is committed as `unknown_tool` and the run continues; a `loopex.grep` call already dispatched is never run under `v0.2.0`, and matching receipt is admitted, absent/unresolved/settling commits outcome_unknown, and in-flight/declined evidence remains pending for a fresh host query; a completed `loopex.grep` call in history replays under `v0.2.0`; a root with an admitted user skill, written by the candidate, resumes under `v0.2.0`'s offline `loopex resume` with the retained snapshot reloaded by digest, and under `v0.2.0`'s daemon with the session resumed and all of that session's skill context withheld, project skills included |
| The vision amendment is recorded | The acceptance change applies all seven named authority places together. Semantic/security review proves one exception covering host environment/copies, sensitive provider path and host crash/logger/telemetry, authorized ambient-tool disclosure, exact-key mapped-provider-reply exclusion, HTTPS-only hosted endpoints, disabled TLS retention, owned-process versus separately witnessed 5,000 ms transport drain and session-only failure containment. It contains no VM-wide gate, lease, quarantine or VM-restart requirement. A tools-reading-key witness demonstrates the accepted audience limit. The retained security-review result/reference/digest use the closure evidence scaffold. |
| Core is unchanged | `git diff v0.2.0 -- apps/loopex/lib ':(exclude)apps/loopex/lib/mix'` is empty, the only additions under `apps/loopex/lib/mix/tasks/` are the two closure tasks, with the existing dependency check's literal parser and edge-declaration/materialization oracles narrowly updated, and `mix loopex.deps_budget` preserves its core budget and locked package closure while its edge-declaration and materialization-root oracles recognize only the three exact load-only tuples; negative vectors refuse missing, duplicate, auto-starting, wrong-version, extra-option and unauthorized-app declarations |

<a id="technical-adr-0039-compatibility"></a>
### Compatibility Mechanics

Concept: [Compatibility and rollback](0039-ephemeral-embedded-profile.md#concept-adr-0039-compatibility).

**New surfaces**, all experimental under the 0.x policy:
- `LoopexComposition.Ephemeral`;
- `LoopexComposition.ResourcePacks.read_directories/2`;
- the `ask` command and its `-p` alias;
- the `provider:model` grammar.

**Recognized options.** The durable `LoopexComposition.start/1`, `with_runtime/2`
and `start_edges/2` entrypoints gain `:model`, `:bounds`, `:sampling` and
`:active_tools`, whose defaults reproduce M5. Named directories use the public
helper and released `resource_manifest` plus ADR 0025 session commands. Their
released outer-list, error-shape and duplicate-key conventions remain: non-list
input keeps each entrypoint's own error shape, other unknown keyword keys remain
ignored and the first repeated key wins. The four added keys were ignored in
`0.2`; M6 recognizes and validates them, so a formerly ignored invalid value now
refuses before startup.

**Durable policy revision.** The default durable `policy_identity` revision
(`loopex_composition.ex:259-261`) becomes the fixed string `"0.2.0"` instead of
`Loopex.version()`. The revision is persisted with each interaction
(`session_state.ex:1509`) and recovery requires exact equality
(`session_coordinator.ex:6593`), so deriving it from the release version would
leave a pending interaction suspended across an upgrade or a rollback. The
revision changes only when the reference policies' behaviour changes, and that
change is its own compatibility decision.

**Rollback exceptions.**
- **A call to an M6-only tool.** Core resolves a tool name against the active
  set only at dispatch (`session_coordinator.ex:5609-5614`), at the post-policy
  continuation (`:6401`) and when resuming a pending policy evaluation
  (`:6602`). For a call not yet dispatched, `0.2` answers an unknown name with
  `{:error, {:unknown_tool, name}}` (`:6846`) and commits it as a failed
  tool call in that dispatch error branch. A call already dispatched follows core's
  dispatched-effect recovery unchanged: activation queries the executor once
  and never redispatches (`session_coordinator.ex:2789-2796,7651-7736`). A
  matching receipt is validated and admitted (`:7800-7847`); `:absent`,
  `:effect_unresolved` or `:effect_settling` commits `outcome_unknown`.
  `:effect_in_flight`, malformed/mismatching evidence or another executor error
  declines reconciliation and leaves work pending for a fresh host query.
  A failed store commit also declines; no failed commit is reported as proof.
  `0.2`'s executor defines no such tool, so it never runs it again.
- **An admitted user skill.** Its admission is journaled as a reference,
  digest, decision and selections (`session_state.ex:4898-4909`), and its
  snapshot is retained under the state root by digest and reloaded through
  core validation (`resource_packs.ex:333-380`), as for a project pack. Its
  `source_id` `user:<name>` and nil Git provenance are both accepted by `0.2`'s
  core validation (`resource_pack.ex:203-216`, `:343-348`). `0.2`'s offline
  `loopex resume` reads the session's admitted digest and reloads that
  snapshot before resuming (`loopex_cli.ex:944-1003`). `0.2`'s daemon instead
  composes the manifest it discovers in the workspace at start
  (`daemon.ex:239-242`), which never contains a user pack, so its snapshot never
  matches the session's one admitted digest: core reports `binding_changed`
  (`runtime/resource_snapshot.ex:112-121`), stages no resource entries
  (`:136-140`, `runtime/resource_context.ex:38-47`), and withholds all of that
  session's skill context while the session itself resumes. A user skill has
  nil Git provenance, so it gets no separate provenance record (the nil-commit
  branch of `retain_provenance/2`, `resource_packs.ex:1584` onward); its
  retained manifest carries its identity and bytes, which is all `load/2`
  needs.

**Unchanged:** the store format, the public protocol generations 1 and 2, the
executor protocol, the daemon, the companion's valid application-call request
and reply behavior and core's library. The companion deliberately changes two
private mechanics: dependency-visible tool-call admission fails a malformed
binary argument rather than producing `%{}` and rejects visible
provider-executed or provider-native classifications rather than flattening
them; and ReqLLM-relative waits become infinite so the coordinator remains the
deadline authority. Provider defects ReqLLM already normalized or omitted
retain the locked dependency's behavior described above.

**Removal.** Removing the profile deletes these and touches no durable byte:
- the in-process adapter, the memory store and the ephemeral composition;
- the ReqLLM start step, restoring automatic start;
- the `ask` command;
- the directory-reading function.
The vision amendment would then describe no shipped profile, and a later change
would retire it.
