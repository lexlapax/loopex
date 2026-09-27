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
- `receive_timeout` set to the time left before the request deadline;
- `max_retries: 0`, and `req_http_options: [redirect: false, retry: false]`,
  which ReqLLM passes to `Req.new/1` (`provider/defaults.ex:259-267`), so the
  request is made once, to the named address;
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
- `Application.get_env(:req, :default_options, [])` is `[]`. `Req.new/1` merges
  it into every request, plugins included (`deps/req/lib/req.ex:475-479`,
  `:1359-1361`), so any value could add an `Authorization` header, a response
  cache, a plugin, another pool, `into:` or a transport.

A failed guard at composition refuses `{:composition, :provider_module_replaced}`
or `{:composition, :req_default_options_unsupported}`; before a call it returns
`{:error, {:not_dispatched, "model_call_failed"}}`.

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
   stop at any moment.
2. **The caller.** A process the owner spawns linked. It sets
   `Process.flag(:sensitive, true)` and `Logger.put_process_level(self(), :none)`
   (Elixir's API; OTP's `logger` exports no per-process level setter), excludes
   itself from Loopex trace sessions through the runtime's trace capability
   (`Loopex.Trace.exclude_self/2`, `trace.ex:55`), checks the guards, reads the
   credential variable, calls `ReqLLM.generate_text/3`, maps the response,
   sends the reply to the owner and exits.

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

**What the acknowledgement does not cover.** With an HTTP/1 pool the caller
performs the socket I/O itself (`finch/http1/pool.ex:52-74`,
`nimble_pool.ex:443-471`); with an HTTP/2 pool, and for every `https`
connection, shared pool or TLS processes also hold the request. Those are
shared infrastructure. They learn of the caller's death through their own
monitors (`nimble_pool.ex:578`, `:669-674`, `:786-793`) and close its
connection afterwards, asynchronously. Nothing they hold can reach the session:
the result path ended with the caller, and the call is already
`dispatched_or_unknown`. Their residual copy of the request and credential is
the exposure the vision amendment names.

**What the witness pins.** On both toolchain pairs, after one call has warmed
the pool for the test server's origin (the first request to an origin starts
Finch's pool shards, `finch/lib/finch/pool/manager.ex:96-134`), a census during
a second plain-`http` call finds exactly the owner and the caller as new
processes. A ReqLLM, Req or Finch update that moves the call into a new
per-call process fails it.

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

Acceptance of this decision changes the paired vision files in the same change:
- **`docs/vision-technical.md` §12.7** gains, after the list of planes from
  which known credential material is excluded, an exception: a host may
  compose a profile whose model adapter runs the provider library in the host
  VM; there a resolved credential exists in the calling process and in the
  provider library's HTTP and TLS processes for one call, so their crash
  reports, a crash dump and host-installed telemetry handlers can observe it.
  The reference-only runtime state, resolution at the model boundary, the
  calling process's trace exclusion and sensitive flag, and every other listed
  exclusion still hold, and a host that needs structural exclusion composes a
  profile that isolates the provider in its own OS process.
- **`docs/vision.md` §12** gains the matching Concept sentence: a host may
  choose an in-VM model profile in which a credential is present in the host VM
  for the duration of a provider call; the separate-process profile keeps full
  isolation.

<a id="technical-adr-0039-proofs"></a>
### Adapters and Proofs

Concept: [Observable consequences](0039-ephemeral-embedded-profile.md#concept-adr-0039-consequences).

| Obligation | Witness |
| --- | --- |
| The memory store is a store | The store conformance suite's `:memory` kind is bound to `Loopex.Store.Memory` itself and passes unchanged |
| The in-process adapter is a model | Mapping, option and error tests run against a scripted ReqLLM transport. The model streaming conformance suite runs against it with `streamed: false` and no deltas. Real-provider lanes call a local Ollama model and one hosted provider |
| The guards hold | A replaced provider module and a non-empty `:req` `:default_options` (including an `auth:` default and a plugin) each refuse at composition, and each refuses the next call before dispatch when set after composition; a redirect response is not followed; no call is retried; no response is cached |
| Credentials stay out of Loopex's planes | With each provider's variable set to a canary, a run with tool calls, a provider error reply and a caller crash leaves the canary in no committed record, event, progress item, diagnostic or trace entry, in no runtime, coordinator or owner state, and in no log line Loopex emits; the caller is sensitive and excluded from a runtime trace session; no provider variable reaches a tool process |
| Its cleanup owns what can return a result | On both toolchain pairs, against a local `http` test server that stalls before its response headers, mid-body and after the body: a stop, a deadline and a normal completion each leave the caller dead before the acknowledgement or the returned reply, the owner answers while the caller is blocked in socket I/O, and no reply reaches the coordinator after acknowledgement. After one warming call, a census during a second call finds exactly the owner and the caller as new processes. The Finch pool serves the next call. A caller whose exit a test seam withholds takes the unproved path |
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
