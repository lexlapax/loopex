<a id="technical-depth"></a>
## Technical depth

Concept: [Ephemeral embedded profile](0039-ephemeral-embedded-profile.md#concept).

<a id="technical-adr-0039-decision"></a>
### Profile Composition

Concept: [Context and decision](0039-ephemeral-embedded-profile.md#concept-adr-0039-decision).

The kernel's ports are unchanged; the profile chooses what fills each one:

| Port | Durable profile | Ephemeral profile |
| --- | --- | --- |
| `Loopex.Store` (six callbacks) | `Loopex.Store.Local` | `Loopex.Store.Memory`: a supervised process over `Loopex.Store.Local.State`, the conformance test wrapper `LoopexStoreLocalTest.Memory` promoted with its optional fault probe (active only when supplied, as `Loopex.Store.Local`'s is), so every conformance case proves it |
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

**The call** (ReqLLM 1.24.0). The adapter calls the non-streaming
`ReqLLM.generate_text/3` with the model built inline as
`ReqLLM.model(%{provider:, id:, base_url:})`, and on every call:
- `api_key:` the value of the provider's variable, read by the calling process
  immediately before the call; none for Ollama, whose provider performs no key
  lookup or authentication (`providers/ollama.ex:118`);
- `total_timeout: :infinity`, so ReqLLM's timeout budget calls `Req.request/1`
  directly in the calling process (`timeout_budget.ex:48`) rather than in a
  task on the shared `ReqLLM.TaskSupervisor` (`:101-103`);
- `base_url:` always passed, as the host's `:base_url` or else the built-in
  module's `default_base_url/0`; ReqLLM fills an absent one from `:req_llm`'s
  per-provider application configuration or the model catalog
  (`provider/options.ex:1147-1171`), and an explicit option wins
  (`Keyword.put_new_lazy`);
- `receive_timeout` set to the time left before the request deadline;
- `max_retries: 0`, the control that stops retries: every chat path attaches
  ReqLLM's retry step after `Req.new/1` (`providers/anthropic.ex:388`,
  `providers/openai.ex:703`, `providers/ollama.ex:134`,
  `provider/defaults.ex:640`), which overwrites Req's `retry:` option and
  retries a POST on 429, 529 and some transport errors (`step/retry.ex:57-67`,
  `:112-142`), and only Req's `retry_count < max_retries` check stops it
  (`deps/req/lib/req/steps.ex:1808-1813`);
- `req_http_options: [redirect: false, finch: pool]`, which each provider's
  chat path passes into its `Req.new/1` (`providers/anthropic.ex:199-229`,
  `providers/openai.ex:435-473`, `provider/defaults.ex:259-267` for Ollama and
  OpenRouter), so no redirect is followed. `pool` is one fixed keyword list of
  Finch pool options with no `:name`, for every provider and scheme:
  `[protocols: [:http1], size: 8, count: 1]`.

  Finch runs it as its HTTP/1 pool (`finch.ex:563-567`), which checks a
  connection out to the caller for one request at a time. ReqLLM keeps a
  name-less `finch:` list as given (`provider/defaults.ex:650-667`), and Req,
  given pool options and no name, starts or reuses one Finch instance under
  `Req.FinchSupervisor` whose name is a hash of those options
  (`deps/req/lib/req/finch.ex:545-613`). So the list names one pool with
  Loopex's fixed configuration, independent of `ReqLLM.Finch`, of `:req_llm`'s
  `:finch` and `:stream_pool_protocols` settings, and of how a host-started
  `ReqLLM.Finch` was configured. ReqLLM adds a per-call `pool_timeout`
  (`providers/anthropic.ex:229`, `providers/openai.ex:467`), a request option
  that Req splits off before hashing (`req/finch.ex:154`, `:567-570`), so it
  never creates another pool; an IPv6-literal host adds `inet6`, which gives
  one other fixed pool. The pool is shared under Req's supervisor rather than
  owned by a Loopex process: another caller using the same options shares it,
  and host code that registers a Finch under the public hashed name first, or
  adds a pool to it with `Finch.start_pool/3`, is trusted host code, which the
  guards do not defend against.

  **Why HTTP/1 only.** Both ways of reaching HTTP/2 through the locked Finch
  fail this adapter's contract. Its multiplexed HTTP/2 pool drops a request
  whose connection turns read-only mid-upload, from its age limit or a
  server's `GOAWAY`, and sends it again up to three times below Req's retry
  control (`finch/http2/pool.ex:562`, `finch.ex:824-830`), which would resend a
  possibly delivered provider call. HTTP/2 negotiated by ALPN on its HTTP/1
  pool sends the whole body in one `Mint.HTTP.request/5` call
  (`finch/http1/conn.ex:118-124`), which Mint refuses above the 65,535-byte
  initial window (`mint/http2.ex:1496-1507`), so any request over 64 KiB fails
  on a fresh connection; ReqLLM guards the same case on its streaming path
  (`req_llm/streaming/finch_client.ex:333-359`, Finch issue #265). HTTP/2 is
  future work, for a Finch release that removes one of these limits;
- `req_http_options: [headers: [{"connection", "close"}]]` as well, so the
  server closes the connection when the response ends. Mint then marks it
  closed, Finch's check-in fails on it and removes the worker
  (`finch/http1/pool.ex:218-233`), and the connection's TLS processes exit,
  taking the plaintext copies of the request, key included, that `:ssl.send`
  gave them. A fresh TLS handshake per call is the cost; against a model call's
  seconds it is small. HTTP/1 keeps no header-compression state, so nothing
  else on the connection holds the key;
- no `:cache` option, so ReqLLM's response cache is disabled
  (`cache.ex:125-128`).

The kernel's own deadline bounds the call. The inline model never reaches
ReqLLM's catalog lookup or its unverified-model warning, which only the string
lookup path emits (`req_llm.ex:735-750`).

**Guards, checked by composition and by the calling process immediately before
each call:**
- `ReqLLM.provider(prefix)` returns exactly the module in the table above;
  ReqLLM's registry lets a later registration replace a provider
  (`providers.ex`), and generation resolves the module at call time.
- `System.get_env("SSLKEYLOGFILE")` is unset. Finch falls back to it when no
  `:ssl_key_log_file` is given and appends each TLS session's secrets to that
  file (`finch.ex:550-553`), which, with a capture of the traffic, recovers the
  key after the call.
- `Application.get_env(:req, :default_options, [])` is `[]`. `Req.new/1` merges
  it into every request, plugins included (`deps/req/lib/req.ex:475-479`,
  `:1359-1361`), so any value could add an `Authorization` header, a response
  cache, a plugin, another pool, `into:` or a transport.
A failed guard at composition refuses `{:composition, :provider_module_replaced}`,
`{:composition, :ssl_key_log_enabled}` or
`{:composition, :req_default_options_unsupported}`; before a call it returns
`{:error, {:not_dispatched, "model_call_failed"}}`. The prefix maps to its
provider atom through the fixed table, never through `String.to_atom/1`. The
registry is read again inside the call, so a registration made between the
guard and the call is a narrow race with host-trusted code, which the guard
does not claim to close.

**No streaming.** The adapter delivers the model's reply whole and reports no
progress deltas. Deltas are transient progress, never session truth, and the
streaming conformance suite already admits an adapter that declares
`streamed: false` with no deltas.

**Error classes:**
- A refusal met before `ReqLLM.generate_text/3` is called is returned, never
  raised, as `{:not_dispatched, "model_call_failed"}`. That covers model build,
  a missing credential, a failed guard, context, tools and options, and an
  elapsed deadline.
- Every return or raise from that call, `{:error, _}` and a non-2xx status
  included, is `{:dispatched_or_unknown, "model_call_failed"}`, as the companion
  classifies a started call
  (`apps/loopex_llm_reqllm/lib/loopex/llm/req_llm.ex:416-453`, citing ADR 0018),
  because the request may already have reached the server.

<a id="technical-adr-0039-tree"></a>
#### The Per-Call Process

Concept: [Context and decision](0039-ephemeral-embedded-profile.md#concept-adr-0039-decision).

Each call has exactly two processes of its own:
1. **The cleanup owner.** `complete/3` starts it with
   `ProviderLifetime.start_child/2` and registers it with
   `ProviderLifetime.register/2`, the coordinator hook the companion bridge uses
   for its guardian (`provider_bridge.ex:207`, `:224`), before anything calls
   ReqLLM. It traps exits, never calls ReqLLM and never blocks, so it answers a
   stop at any moment. It is marked sensitive, and it matches an `EXIT` or
   `DOWN` from the caller only by shape, never keeping or reporting its reason,
   so an exception that carries the request cannot reach its state or a crash
   report.
2. **The caller.** A process the owner spawns linked. It sets
   `Process.flag(:sensitive, true)` and `Logger.put_process_level(self(), :none)`
   (Elixir's API; OTP's `logger` exports no per-process level setter), excludes
   itself from Loopex trace sessions through the runtime's trace capability
   (`Loopex.Trace.exclude_self/2`, `trace.ex:56`), checks the guards, reads the
   credential variable, calls `ReqLLM.generate_text/3` inside a `try` that
   catches every raise, throw and exit, maps the response, sends the owner
   either the reply or a fixed error class, and exits `:normal`. Its only
   abnormal exit is the owner's `:kill`.

The caller is the only process that can return a provider result to Loopex:
the reply reaches the coordinator only through the owner, and only from the
caller.

**Cleanup.** On the coordinator's resource stop message
(`session_coordinator.ex:4627-4634`), or its deadline, the owner monitors the
caller, kills it with `:kill`, waits for its `DOWN`, and only then acknowledges
`{:loopex_provider_resource_stopped, stop, self()}` (`:4641`). On completion
the caller exits after sending its reply, and the owner waits for its `DOWN`
before it returns the reply, killing it if the cooperative deadline passes
first. A `DOWN` that does not arrive leaves the acknowledgement unsent, and the
coordinator's existing unproved-cleanup path applies (`:4646-4652`).

**What the acknowledgement covers, and what it does not.**
- **The request runs in the caller.** The pool checks a connection out to the
  caller, which performs the request's socket I/O itself
  (`finch/http1/pool.ex:52-74`, `nimble_pool.ex:443-471`). A fresh connection
  is opened in the caller and owned by it until checked in; a reused one stays
  owned by the pool, with the caller driving passive sends and receives
  (`finch/http1/pool.ex:188-199`, `:314-322`). Either way a killed caller
  sends nothing more. A fresh connection's socket closes because its
  controlling process, the caller, died; a reused connection is closed by the
  pool when its checkout monitor sees the caller gone (`nimble_pool.ex:578`,
  `:669-674`, `:786-793`; `finch/http1/pool.ex:290-293`). Bytes already handed to the operating system
  or a TLS sender may still leave; the call is already `dispatched_or_unknown`,
  so that changes nothing.
- **No hidden resend.** Finch's HTTP/1 pool has no read-only redispatch, and
  neither it nor Req retries a stale idle connection; with `max_retries: 0` and
  `redirect: false` the request is sent at most once. A reused connection the
  server closed while idle can fail before sending anything; that error is
  still classified `dispatched_or_unknown`, which is safe but can overstate the
  uncertainty.
- **No credential outlives the call in a connection.** During a call the
  request's bytes, key included, pass through the caller, the connection's TLS
  processes for an `https` address, and Finch's telemetry metadata
  (`finch/http1/pool.ex:47-49`), which any handler the host installs can read.
  The `connection: close` header makes the server close the connection when
  the response ends, so the connection is removed and its TLS processes exit
  with their copies; HTTP/1 keeps no other header state. No connection that
  carried a key stays idle in the pool.

Nothing any of this holds can reach the session: the result path ended with
the caller, and the call is already `dispatched_or_unknown`. Those copies, and
whatever a host's handler copies, are the exposure the vision amendment
names.

**What the witness pins.** On both toolchain pairs, after one call has warmed
the pool for the test server's origin (the first request to an origin starts
Finch's pool shards, `finch/lib/finch/pool/manager.ex:96-134`), a census
during a second call finds exactly the owner and the caller as new processes,
once over plain `http` and once over TLS; after a completed call no process of
that call's connection remains, its TLS processes included. A ReqLLM, Req or
Finch update that moves the call into a new per-call process, or keeps its
connection open, fails it.

**Host hygiene.** `ReqLLM.Application.start/2` reads `:load_dotenv` (default
`true`) and loads `.env` from the working directory (`application.ex:25-31`).
`:req_llm` is removed from `loopex_llm_reqllm`'s started applications while it
stays a compile-time and code dependency (`apps/loopex_llm_reqllm/mix.exs:63`),
so every build that carries the adapter carries ReqLLM's code; a host building
its own OTP release lists `req_llm: :load` in that release, as the developer
guide states. The companion worker already starts ReqLLM itself after its
settings (`provider_worker.ex:43`, `:78-79`).

**The start step,** run by every ephemeral composition. It keeps no process and
no state of its own; what it reads is application configuration, which
outlives any Loopex application's restart:

| ReqLLM | `:req_llm` `:load_dotenv` | Loopex marker or host declaration | Result |
| --- | --- | --- | --- |
| Not running | any | any | `Application.put_env(:req_llm, :load_dotenv, false, persistent: true)`, the same for `:llm_db`, the marker `Application.put_env(:loopex_composition, :req_llm_hygiene, true, persistent: true)`, then `Application.ensure_all_started(:req_llm)` |
| Not running, and the start returns an error | any | any | Refuse `{:composition, :req_llm_start_failed}`; ReqLLM's own start-time behaviour, such as the REPL server it adds when `TIDEWAVE_REPL` is set (`application.ex:43`, `:152-162`), is the host environment's |
| Running | `false` | the marker is set, or the host passed `req_llm: :host_started` | Proceed |
| Running | `false` | neither | Refuse `{:composition, :req_llm_already_started}` |
| Running | not `false` | any | Refuse `{:composition, :req_llm_dotenv_enabled}` |

- **Concurrency.** Two compositions that both find ReqLLM not running write the
  same values and both call `Application.ensure_all_started/1`, which the
  application controller serializes; one starts ReqLLM and the other finds it
  started. The marker is written before the start, so a composition that finds
  ReqLLM running after a Loopex start always finds the marker too.
- **Persistence.** `persistent: true` keeps the values across any later load of
  the application (`Application.put_env/4`), so a host that stops and restarts
  ReqLLM restarts it with `.env` loading off. A host that turns loading back on
  changes the value the next composition reads, and is refused.
- **A host declaration is trusted as given.** With `req_llm: :host_started`,
  composition reads the current `:load_dotenv`, not the value in force when the
  host started ReqLLM; a false declaration is the host's.
- **Nothing else changes.** Loopex leaves `warn_unverified_models` alone,
  never restores the values, because ReqLLM reads them at its start, and never
  stops ReqLLM, because another component may use it.

<a id="technical-adr-0039-relation-0019"></a>
### Shared-State and Diagnostic Facts

Concept: [What changes relative to ADR 0019](0039-ephemeral-embedded-profile.md#concept-adr-0039-relation-0019).

These facts are for ReqLLM 1.24.0, verified in `deps/req_llm`.

**What starting ReqLLM does.** Starting `:req_llm` starts `ReqLLM.Supervisor`,
with its Finch pool `ReqLLM.Finch`, `ReqLLM.TaskSupervisor` and a token cache.
It also initializes a provider registry in `persistent_term` and a named ETS
table. All of these are VM-global and named, so one ReqLLM serves every user in
the VM.

**Paths that can carry the request, and a hosted provider's credential, into
the host:**
- a log line ReqLLM, Req or Finch writes while handling the call: it is written
  in the caller, whose process level is `:none`, so it is never emitted;
- a crash report from a shared pool or TLS connection process that was
  handling the caller's connection;
- a telemetry handler the host installs: Finch's events carry the request,
  headers and body included (`finch/http1/pool.ex:47-49`), and ReqLLM's carry
  payloads when configured to; handlers run in the caller but may send data
  anywhere;
- an `erl_crash.dump`, which omits the sensitive caller's stack, messages and
  dictionary but not the shared processes' state.

The companion suppresses all of these by running ReqLLM in its own BEAM. The
ephemeral profile does not; the `ask` command sets the primary logger level to
`:none` and disables crash dumps for its own VM, and a library host owns the
rest.

<a id="technical-adr-0039-vision"></a>
### The Vision Amendment

Concept: [The vision amendment](0039-ephemeral-embedded-profile.md#concept-adr-0039-vision).

Acceptance of this decision changes the paired vision files and AGENTS.md in
the same change. Each place gets the same bounded exception, worded for its
context:
- **`docs/vision-technical.md` §12.7** gains, after the list of planes from
  which known credential material is excluded, an exception: a host may
  compose a profile whose model adapter runs the provider library in the host
  VM; there a resolved credential exists in the calling process and in the
  provider library's HTTP and TLS processes during a call, until the call's connection closes when its response ends, so their crash
  reports, a crash dump and host-installed telemetry handlers can observe it.
  The reference-only runtime state, resolution at the model boundary, the
  calling process's trace exclusion and sensitive flag, and every other listed
  exclusion still hold, and a host that needs structural exclusion composes a
  profile that isolates the provider in its own OS process.
- **`docs/vision.md` §12** gains the matching Concept sentence: a host may
  choose an in-VM model profile in which a credential is present in the host VM
  during a call, until the call's connection closes when its response ends; the separate-process profile keeps full isolation.
- **`docs/vision.md` §16**, after "Observability uses references and redaction
  rather than capturing secrets or unrestricted payloads", gains: "In an in-VM
  model profile a host chooses, the provider library's own crash reports and a
  host's telemetry handlers can capture a credential during a call, until the call's connection closes when its response ends; Loopex's own observability
  still never does."
- **`docs/vision-technical.md` §6.1**, in the credential custody row, the host
  column reads "Owns encryption, resolution, rotation; may resolve by supplying
  the value through a variable it names, read at the model boundary"; and
  §12.7's "narrowest possible lifetime and audience" gains "; a value a host
  supplies through its environment has that environment's lifetime and
  audience, which the host owns".
- **`docs/vision-technical.md` §6.2**, after the diagnostics plane's
  definition, gains: "Crash detail from a provider library the host runs in its
  own VM is the host's diagnostics, outside Loopex's diagnostics plane, as
  §12.7 states."
- **`docs/vision-technical.md` §23**, the bullet "Known credential material
  never appears in prohibited planes" gains "; an in-VM model profile's
  provider-library crash reports and host telemetry are the §12.7 exception".
- **`AGENTS.md`**, Product Non-Negotiables, "Credentials and context", after
  "beyond an approved scoped ephemeral hand secret", gains: "; in an in-VM
  model profile a host chooses, a credential may also reach the provider
  library's processes and their crash reports during a call, until the call's connection closes when its response ends, never a Loopex
  plane (ADR 0039)". Editing AGENTS.md is the maintainer's to approve with the
  acceptance.

<a id="technical-adr-0039-proofs"></a>
### Adapters and Proofs

Concept: [Observable consequences](0039-ephemeral-embedded-profile.md#concept-adr-0039-consequences).

| Obligation | Witness |
| --- | --- |
| The memory store is a store | The store conformance suite's `:memory` kind is bound to `Loopex.Store.Memory` itself and passes unchanged |
| The in-process adapter is a model | Mapping, option and error tests run against a scripted ReqLLM transport. The model streaming conformance suite runs against it with `streamed: false` and no deltas. Real-provider lanes call a local Ollama model and one hosted provider |
| The guards hold | A replaced provider module, a set `SSLKEYLOGFILE` and a non-empty `:req` `:default_options` (including an `auth:` default and a plugin) each refuse at composition, and each refuses the next call before dispatch when set after composition. With `:req_llm` per-provider `base_url` configuration and a catalog override set, the request still goes to the explicit address. With `:req_llm`'s `:finch` set to a proxy and `:stream_pool_protocols` changed, and with a host-started `ReqLLM.Finch` configured differently, the call still uses Loopex's pool. After `prepare_request`, the final request has `max_retries` 0, `redirect` false, a `connection: close` header, and `finch` options that equal Loopex's fixed list once the request-only `pool_timeout` is removed. A 429, a 529 and a `:closed` transport error are each sent exactly once; a redirect response is not followed; no response is cached |
| Credentials stay out of Loopex's planes | With each provider's variable set to a canary, a run with tool calls, a provider error reply, and a caller crash raised inside a Req step whose exception embeds the request leaves the canary in no committed record, event, progress item, diagnostic or trace entry, in no runtime, coordinator or owner state or mailbox, in no owner crash report, in no log line Loopex emits, and, after the call, in no live process's heap as read by `Process.info(pid, :binary)` over every process the call started or used; the caller is sensitive and excluded from a runtime trace session; no provider variable reaches a tool process |
| Its cleanup owns what can return a result | On both toolchain pairs, against a local `http` test server and a local TLS test server, each stalling before its response headers, mid-body and after the body: a stop, a deadline and a normal completion each leave the caller dead before the acknowledgement or the returned reply, the owner answers while the caller is blocked, no reply reaches the coordinator after acknowledgement, and after a kill the server sees the connection close. After a completed call the server sees the connection close and no process of that connection, TLS processes included, remains. A request body larger than 64 KiB is sent and answered over both. A server close during a body upload yields one request on the wire and a `dispatched_or_unknown` result. After one warming call, a census during a second call finds exactly the owner and the caller as new processes over both. A caller whose exit a test seam withholds takes the unproved path |
| Hygiene holds | `:req_llm` is started by no application start while the escript embeds its modules, and a fixture release built with `req_llm: :load` boots without starting it. A `.env` in the working directory is not loaded. Each row of the start table; two concurrent first compositions starting it once; a later composition proceeding, including after `loopex_composition` restarts; a host restart of ReqLLM loading no `.env`; a host turning loading back on, then refused; `warn_unverified_models` never written |
| The companion path is unchanged | Every companion suite passes after the shared mapping is extracted; the durable profile refuses an `ollama:` model |
| The profile is ephemeral and says so | After a proved stop, or its caller exiting, no file remains under the profile's temporary root. The result carries `profile: :ephemeral`, and `ask`'s JSON carries `"profile"` |
| No default authority | Composition without `:policy` refuses with `host_policy_required` |
| Skills are truthfully named | A `.agents/skills/<name>` directory in the workspace is `project:<name>`; a directory outside is `user:<name>` with its content digest; any other workspace directory refuses; a shared name admits the project skill and reports the user skill as shadowed; the same holds under `ask --state-root` |
| Rollback holds as stated | A durable root with a pending interaction written by the candidate recovers and is answered under `v0.2.0`, and the reverse; a `loopex.grep` call not yet dispatched, resumed under `v0.2.0`, is committed as `unknown_tool` and the run continues; a `loopex.grep` call already dispatched is never run under `v0.2.0`, and its work either has a matching receipt admitted or stays pending; a completed `loopex.grep` call in history replays under `v0.2.0`; a root with an admitted user skill, written by the candidate, resumes under `v0.2.0`'s offline `loopex resume` with the retained snapshot reloaded by digest, and under `v0.2.0`'s daemon with the session resumed and all of that session's skill context withheld, project skills included |
| The vision amendment is recorded | The acceptance change carries both vision edits, and `bash scripts/check.sh --docs` passes on it |
| Core is unchanged | `git diff v0.2.0 -- apps/loopex/lib` is empty outside `apps/loopex/lib/mix/`, and `mix loopex.deps_budget` passes unchanged |

<a id="technical-adr-0039-compatibility"></a>
### Compatibility Mechanics

Concept: [Compatibility and rollback](0039-ephemeral-embedded-profile.md#concept-adr-0039-compatibility).

**New surfaces**, all experimental under the 0.x policy:
- `LoopexComposition.Ephemeral`;
- `ResourcePacks.read_directories/2`;
- the `ask` command and its `-p` alias;
- the `provider:model` grammar.

**Additive options.** The durable `LoopexComposition.start/1` gains `:model`,
`:bounds`, `:sampling`, `:active_tools` and `:skill_directories`, whose defaults
reproduce M5.

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
  set only at dispatch (`session_coordinator.ex:5609`), at the post-policy
  continuation (`:6401`) and when resuming a pending policy evaluation
  (`:6602`). For a call not yet dispatched, `0.2` answers an unknown name with
  `{:error, {:unknown_tool, name}}` (`:6845-6847`) and commits it as a failed
  tool call (`:6625-6626`). A call already dispatched follows core's
  dispatched-effect recovery unchanged: `0.2` queries the executor, admits a
  matching receipt, and otherwise leaves the work pending for reconciliation;
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
executor protocol, the daemon, the companion and core's library.

**Removal.** Removing the profile deletes these and touches no durable byte:
- the in-process adapter, the memory store and the ephemeral composition;
- the ReqLLM start step, restoring automatic start;
- the `ask` command;
- the directory-reading function.
The vision amendment would then describe no shipped profile, and a later change
would retire it.
