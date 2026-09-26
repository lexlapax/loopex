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
| `Loopex.Model` (`complete/3`) | `Loopex.LLM.ReqLLM` through the companion bridge | By the model's provider: `Loopex.LLM.ReqLLM.InProcess` for a credential-free provider (`ollama:` in M6); otherwise `Loopex.LLM.ReqLLM` through the companion bridge, composed exactly as the durable profile composes it (`LoopexComposition.CredentialPlane`, the host's provider launch options) |
| `Loopex.Executor` | `Loopex.Executor.Local`, ledger under the state root | `Loopex.Executor.Local`, ledger under the profile's temporary root |
| `Loopex.Policy` | A named host policy | A policy module supplied by the host; the reference CLI maps `allow-all`, `shell-allowlist` and `refuse-all` to its own modules |

**The in-process adapter:**
- **Placement:** it lives in `apps/loopex_llm_reqllm`, the one edge application
  that carries ReqLLM.
- **Scope:** it accepts only a provider on its credential-free list, `ollama`
  in M6, and only in the ephemeral profile. Any other provider refuses
  `{:not_dispatched, "credential_required"}` before ReqLLM is called, and
  composition never selects it for one. It passes no `api_key`, and ReqLLM's
  key lookup (`keys.ex:56-72`) is never reached, because the Ollama provider
  performs no key lookup or authentication (`providers/ollama.ex:113`).
- **Selection:** composition selects exactly one adapter per runtime, by the
  model's provider. The companion adapter keeps refusing any in-VM fallback, as
  ADR 0034 fixed.

**The call** (ReqLLM 1.24.0). The adapter calls the non-streaming
`ReqLLM.generate_text/3` with the model built inline as
`ReqLLM.model(%{provider: :ollama, id:, base_url:})`, and these options on every
call:
- `total_timeout: :infinity`, so ReqLLM's timeout budget calls `Req.request/1`
  directly in the calling process (`timeout_budget.ex:47`) rather than in a
  task on the shared `ReqLLM.TaskSupervisor` (`:101-103`), whatever the host's
  `:req_llm` configuration says;
- `receive_timeout` set to the time left before the request deadline, and
  `max_retries: 0`;
- no `:cache` option, so ReqLLM's response cache is never consulted.

The kernel's own deadline, not ReqLLM's, bounds the call: when it expires the
coordinator stops the call as described below. The inline model never reaches
ReqLLM's catalog lookup or its unverified-model warning, which only the string
lookup path emits (`req_llm.ex:735-750`).

**No streaming.** The in-process adapter delivers the model's reply whole and
reports no progress deltas. Deltas are transient progress, never session truth,
so no outcome depends on them; the companion adapter keeps streaming.

**Error classes:**
- A refusal met before `ReqLLM.generate_text/3` is called is returned, never
  raised, as `{:not_dispatched, "model_call_failed"}`. That covers model build,
  context, tools and options, and an elapsed deadline.
- Every return or raise from that call, `{:error, _}` and a non-2xx status
  included, is `{:dispatched_or_unknown, "model_call_failed"}`, as the companion
  classifies a started call (`req_llm.ex:416-453`, citing ADR 0018), because
  the request may already have reached the server.

<a id="technical-adr-0039-tree"></a>
#### The Per-Call Process

Concept: [Context and decision](0039-ephemeral-embedded-profile.md#concept-adr-0039-decision).

**One process holds the whole call.** On the path above, ReqLLM prepares the
request and runs `Req.request/1` in the process that called
`generate_text/3`. Req runs its steps in that process, and Finch's HTTP/1 pool
checks a connection out to that process, which then performs the socket I/O
itself. No stream server, HTTP task or metadata worker exists. So the call has
exactly two processes of its own:
1. **The cleanup owner.** `complete/3` starts it with
   `ProviderLifetime.start_child/2` and registers it with
   `ProviderLifetime.register/2`, the coordinator hook the companion bridge uses
   for its guardian (`provider_bridge.ex:207`, `:224`), before anything calls
   ReqLLM. It traps exits, never calls ReqLLM and never blocks, so it answers a
   stop at any moment.
2. **The caller.** A process the owner spawns linked, which sets
   `Logger.put_process_level(self(), :none)` (Elixir's API; OTP's `logger`
   exports no per-process level setter), calls `ReqLLM.generate_text/3`, maps
   the response, sends the reply to the owner and exits.

**Cleanup.** On the coordinator's resource stop message
(`session_coordinator.ex:4627-4634`), or its deadline, the owner monitors the
caller, kills it with `:kill`, waits for its `DOWN`, and only then acknowledges
`{:loopex_provider_resource_stopped, stop, self()}` (`:4641`). On completion
the owner waits for the caller's `DOWN` before it returns the reply. A `DOWN`
that does not arrive by the cooperative deadline leaves the acknowledgement
unsent, and the coordinator's existing unproved-cleanup path applies
(`:4646-4652`). When the caller dies, the pool that lent it a connection
learns of it through NimblePool's checkout monitor (`nimble_pool.ex:196`) and
closes or reclaims that connection; the pool is shared and is never killed.

**Pool protocol.** This holds for ReqLLM's default pool, which uses HTTP/1
unless configured otherwise (`application.ex:4`, `:94-100`). An HTTP/2 pool
instead performs the request inside the shared pool process on the caller's
behalf. So the start step refuses `{:composition, :req_llm_pool_unsupported}`
when `:req_llm`'s `:stream_pool_protocols` or its `:finch` pools configuration
includes `:http2`.

**What the witness pins.** The witness counts the processes created during a
call on both toolchain pairs and requires exactly the owner and the caller, so
a ReqLLM update that moves the request into another process fails it.

**Host hygiene.** `ReqLLM.Application.start/2` reads `:load_dotenv` (default
`true`) and loads `.env` from the working directory (`application.ex:25-31`).
`:req_llm` is removed from `loopex_llm_reqllm`'s started applications while it
stays a compile-time and code dependency (`apps/loopex_llm_reqllm/mix.exs:63`),
so every build that carries the adapter carries ReqLLM's code; a host building
its own OTP release lists `req_llm: :load` in that release, as the developer
guide states. The companion worker already starts ReqLLM itself after its
settings (`provider_worker.ex:43`, `:78-79`).

**The start step,** run only when the selected model uses the in-process
adapter. It keeps no process and no state of its own; what it reads is
application configuration, which outlives any Loopex application's restart:

| ReqLLM | `:req_llm` `:load_dotenv` | Loopex marker or host declaration | Result |
| --- | --- | --- | --- |
| Not running | any | any | `Application.put_env(:req_llm, :load_dotenv, false, persistent: true)`, the same for `:llm_db`, the marker `Application.put_env(:loopex_composition, :req_llm_hygiene, true, persistent: true)`, then `Application.ensure_all_started(:req_llm)` |
| Running | `false` | the marker is set, or the host passed `req_llm: :host_started` | Proceed |
| Running | `false` | neither | Refuse `{:composition, :req_llm_already_started}` |
| Running | not `false` | any | Refuse `{:composition, :req_llm_dotenv_enabled}` |
| Any | any | any, when `:req_llm`'s `:stream_pool_protocols` or `:finch` pools include `:http2` | Refuse `{:composition, :req_llm_pool_unsupported}` |

- **Concurrency.** Two compositions that both find ReqLLM not running write the
  same values and both call `Application.ensure_all_started/1`, which the
  application controller serializes; one starts ReqLLM and the other finds it
  started. The marker is written before the start, so a composition that finds
  ReqLLM running after a Loopex start always finds the marker too.
- **Persistence.** `persistent: true` keeps the values across any later load of
  the application (`Application.put_env/4`), so a host that stops and restarts
  ReqLLM restarts it with `.env` loading off. A host that turns loading back on
  changes the value the next composition reads, and is refused.
- **Nothing else changes.** The inline model spec never reaches ReqLLM's
  unverified-model warning, which only the string lookup path emits
  (`req_llm.ex:735-750`), so Loopex leaves `warn_unverified_models` alone. The
  values are never restored, because ReqLLM reads them at its start, and Loopex
  never stops ReqLLM, because another component may use it.

<a id="technical-adr-0039-relation-0019"></a>
### Shared-State and Diagnostic Facts

Concept: [What changes relative to ADR 0019](0039-ephemeral-embedded-profile.md#concept-adr-0039-relation-0019).

These facts are for ReqLLM 1.24.0, verified in `deps/req_llm`.

**What starting ReqLLM does.** Starting `:req_llm` starts `ReqLLM.Supervisor`,
with its Finch pool `ReqLLM.Finch`, `ReqLLM.TaskSupervisor` and a token cache.
It also initializes a provider registry in `persistent_term` and a named ETS
table. All of these are VM-global and named, so one ReqLLM serves every user in
the VM.

**Paths that can carry request data into the host:**
- a log line ReqLLM, Req or Finch writes while handling the call: it is written
  in the caller, which sets `Logger.put_process_level(self(), :none)` first, so
  it is never emitted;
- a crash report from the caller, the one per-call process, or from a shared
  pool process that was handling its connection;
- an `erl_crash.dump`.

With no credential in the in-process request, the last two can carry only
request data: the prompt, the context, tool output and the reply. The companion suppresses them
by running ReqLLM with the primary level `:none`, an IO sink as group leader and
`ERL_CRASH_DUMP=/dev/null` (`provider_worker.ex:71-82`); the `ask` command
reproduces the level and crash-dump parts for its own VM; a library host owns
them.

**Why no credential reaches the in-process path.** The in-process adapter's
options carry no key and it refuses any provider not on its credential-free
list; Ollama itself performs no key lookup or authentication
(`providers/ollama.ex:113`). An ephemeral runtime with an Ollama model opens no
credential plane, so its state holds no credential reference either.

**The companion path is ADR 0034's, unchanged.**
`LoopexComposition.CredentialPlane` reads `LOOPEX_PROVIDER_API_KEY`, removes it
from the VM environment and hands the bytes to the host `CredentialCustody`
process (`credential_plane.ex:41`), the host custody ADR 0034 accepts. The model
options carry only its opaque token, registry and trace capability
(`loopex_composition/edges.ex:40-78`), and the value reaches the companion only
over the bootstrap channel. The ephemeral profile adds nothing to that path and
removes nothing from it.

<a id="technical-adr-0039-proofs"></a>
### Adapters and Proofs

Concept: [Observable consequences](0039-ephemeral-embedded-profile.md#concept-adr-0039-consequences).

| Obligation | Witness |
| --- | --- |
| The memory store is a store | The store conformance suite's `:memory` kind is bound to `Loopex.Store.Memory` itself and passes unchanged |
| The in-process adapter is a model | Mapping, option and error tests run against a scripted ReqLLM transport. The model streaming conformance suite runs against it. A real-provider lane calls a local Ollama model |
| It serves only credential-free providers | Every non-Ollama provider refuses before ReqLLM is called; no `api_key` option is ever passed; an ephemeral runtime with an Ollama model opens no credential plane; with `LOOPEX_PROVIDER_API_KEY` set to a canary in the host environment, an in-process run leaves the canary in no plane, no runtime or adapter process state and no captured log event, and leaves the host variable unchanged |
| Its cleanup ends the whole call | On both toolchain pairs, against a local test server that stalls before its response headers, mid-body and after the body: a stop, a deadline and a normal completion each leave no process created by the call alive, the owner answers while the caller is blocked in socket I/O, and the caller's `DOWN` precedes the acknowledgement or the returned reply. A process census taken during the call finds exactly the owner and the caller as new processes. The Finch pool is alive and serves the next call. A caller whose exit a test seam withholds takes the unproved path. Each pool refusal row of the start table refuses |
| The companion path is unchanged | Every companion suite passes after the shared mapping is extracted; an ephemeral runtime with a hosted model composes `CredentialPlane` exactly as the durable one does; the durable profile refuses an `ollama:` model |
| Hygiene holds | `:req_llm` is started by no application start while the escript embeds its modules. A `.env` in the working directory is not loaded when composition starts ReqLLM. Each row of the start table; two concurrent first compositions starting it once; a second composition after a Loopex start proceeding; `loopex_composition` stopped and restarted, then a composition proceeding; ReqLLM stopped and restarted by the host with the persistent setting, loading no `.env`; the host turning loading back on, then refused; `warn_unverified_models` never written |
| The profile is ephemeral and says so | After a proved stop, or its caller exiting, no file remains under the profile's temporary root. The session value and `result` carry `profile: :ephemeral`, and `ask`'s JSON carries `"profile"` |
| No default authority | Composition without `:policy` refuses with `host_policy_required` |
| Skills are truthfully named | A `.agents/skills/<name>` directory in the workspace is `project:<name>`; a directory outside is `user:<name>` with its content digest; any other workspace directory refuses; a shared name admits the project skill and reports the user skill as shadowed; the same holds under `ask --state-root` |
| Rollback holds as stated | A durable root with a pending interaction written by the candidate recovers and is answered under `v0.2.0`, and the reverse; a pending call to `loopex.grep` resumed under `v0.2.0` is committed as `unknown_tool` and the run continues; a completed `loopex.grep` call in history replays under `v0.2.0`; a root with an admitted user skill, written by the candidate, resumes under `v0.2.0`'s offline `loopex resume` with the skill's retained snapshot reloaded by digest, and under `v0.2.0`'s daemon with the session resumed and that skill's context withheld |
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

**Rollback exceptions.** A pending call is re-resolved against the active tool
set on recovery (`session_coordinator.ex:6602`), and `0.2` answers an unknown
name with `{:error, {:unknown_tool, name}}` (`:6844`), which it commits as a
failed tool call (`:6625-6626`). A user skill's admission is journaled as a
reference, digest, decision and selections (`session_state.ex:4898`), and its
snapshot is retained under the state root by digest and reloaded through core
validation (`resource_packs.ex:333-380`), exactly as for a project pack. Its
`source_id` `user:<name>` and nil Git provenance are both accepted by `0.2`'s
core validation (`resource_pack.ex:203-216`, `:343-348`). `0.2`'s offline
`loopex resume` reads the session's admitted digest and reloads that snapshot
before resuming (`loopex_cli.ex:944-990`), so it gets the skill back. `0.2`'s
daemon instead composes the manifest it discovers in the workspace at start
(`daemon.ex:239-242`), which never contains a user pack, so core declines the
session's admitted binding (`resource_pack.ex:497-505`) and withholds that
skill's context while the session itself resumes. A user skill has nil Git
provenance, so it gets no separate provenance record
(`resource_packs.ex:1584`); its retained manifest carries its identity and
bytes, which is all `load/2` needs.

**Unchanged:** the store format, the public protocol generations 1 and 2, the
executor protocol, the daemon, the companion and core's library.

**Removal.** Removing the profile deletes these and touches no durable byte:
- the in-process adapter, the memory store and the ephemeral composition;
- the ReqLLM start step, restoring automatic start;
- the `ask` command;
- the directory-reading function.
