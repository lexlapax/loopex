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
  in M6. Any other provider refuses `{:not_dispatched, "credential_required"}`
  before ReqLLM is called, and composition never selects it for one. It passes
  no `api_key`, and ReqLLM's key lookup (`keys.ex:56-72`) is never reached,
  because the Ollama provider requires none.
- **Selection:** composition selects exactly one adapter per runtime, by the
  model's provider. The companion adapter keeps refusing any in-VM fallback, as
  ADR 0034 fixed.

**Call options** (ReqLLM 1.24.0): `max_retries: 0`, and `receive_timeout` set
to the time left before the request deadline. The model is built inline as
`ReqLLM.model(%{provider:, id:, base_url:})`, so no catalog lookup or
unverified-model warning occurs.

**Error classes:**
- A refusal met before `ReqLLM.stream_text/3` is called is returned, never
  raised, as `{:not_dispatched, "model_call_failed"}`. That covers model build,
  context, tools and options, and an elapsed deadline.
- Every return or raise from that call, `{:error, _}` included, is
  `{:dispatched_or_unknown, "model_call_failed"}`, as the companion classifies
  it (`req_llm.ex:416-453`, citing ADR 0018), because ReqLLM may already have
  started its transport.
- A stream is not a success until its metadata shows no `:error`, no status of
  400 or more, and no `finish_reason` of `:incomplete`, `:cancelled` or `:error`.

<a id="technical-adr-0039-tree"></a>
#### The Per-Call Process Tree

Concept: [Context and decision](0039-ephemeral-embedded-profile.md#concept-adr-0039-decision).

In ReqLLM 1.24.0 one `stream_text/3` call creates, in this order, from the
process that calls it:

| # | Process | Started by | Link | Ancestry key |
| --- | --- | --- | --- | --- |
| 1 | Stream server | the caller, `StreamServer.start_link` (`streaming.ex:211`) | caller | `$ancestors` names the caller |
| 2 | HTTP task | the stream server, in its `:start_http` call (`stream_server.ex:495`), through `Task.Supervisor.async` (`streaming/finch_client.ex:168`) on the shared `ReqLLM.TaskSupervisor` | the supervisor at spawn; the stream server once `async` links it | `$ancestors` names `ReqLLM.TaskSupervisor`; `$callers` names the stream server only after the handshake |
| 3 | Metadata handle | the caller, `MetadataHandle.start_link` (`streaming.ex:158`, `:410`; `metadata_handle.ex:17-18`) | caller | `$ancestors` names the caller |
| 4 | Metadata worker | the metadata handle, raw `:erlang.spawn_opt(..., [:link, :monitor])` (`metadata_handle.ex:54-60`) | metadata handle | none |

The stream server traps exits (`stream_server.ex:416`) and ignores an
unrelated linked exit (`:659-662`); its cancellation signals the HTTP task
without waiting for its `DOWN` (`:1593-1601`); and `stream_text/3` returns
neither the HTTP task nor the worker (`streaming.ex:126`). So no single kill
ends the call, and no returned value names every process.

**How the HTTP task starts,** in both supported Elixir versions
(`Task.Supervisor.async/6` and `Task.Supervised.reply/3`, the same in 1.18.5
and 1.20.3):
1. the shared supervisor spawns the task, which records its `$ancestors`,
   monitors its starter, and waits;
2. the starter links to it;
3. the starter sends the handshake, which alone carries the function and its
   arguments, and so the request;
4. the task records `$callers` and runs the function.

Before step 3 the task holds no request and cannot perform the call, and if its
starter dies it exits: through its monitor before step 2, through the link
after it.

**Membership rule.** Starting from the caller, the owner follows links
transitively. A linked process belongs to the call when any of these holds:
- its `$ancestors` or `$callers` names a process already in the call;
- its `$ancestors` names `ReqLLM.TaskSupervisor` and it is linked to a process
  already in the call: only that process's own `async` links a task of the
  shared supervisor to it, so this catches an HTTP task between steps 2 and 4;
- it has neither key and every process it is linked to is already in the call.

Nothing else belongs: the owner itself, `ReqLLM.TaskSupervisor`, the Finch pool
and every other shared process has ancestry outside the call, is never followed
past, and is never suspended or killed. Each member is suspended with
`:erlang.suspend_process/1` before its links are read, so no member can create
a further link or send a handshake during the walk.

**What the walk can miss, and why that is safe.** An HTTP task at step 1, whose
starter was suspended before step 2, is linked to no member and is not found.
The starter never resumes, so the task never receives a request; it exits on
its monitor when the starter dies. That task is the one process that can
outlive the acknowledgement, and it holds nothing of the request.

**The owner's sequence,** on a stop, a deadline, or the caller's completion:
1. suspend the caller, then walk the tree as above, suspending each member;
2. monitor every member and kill each with `:kill`, which a trapping process
   cannot ignore;
3. wait for every member's `DOWN`, up to the cooperative deadline;
4. only then acknowledge `{:loopex_provider_resource_stopped, stop, self()}`,
   or on completion return the reply.

On completion the caller hands its reply to the owner and waits, so it is still
alive and linked when the walk begins. Suspending a member that is waiting on a
shared process, such as the stream server inside the supervisor's `start_child`
call, leaves that shared process's reply queued to a process about to be
killed; the shared process never waits on the member. A killed HTTP task's
Finch connection is returned to its pool by the pool's checkout monitor; a
witness proves the pool serves the next call. A `DOWN` that does not arrive
leaves the acknowledgement unsent, and the coordinator's existing
unproved-cleanup path applies (`session_coordinator.ex:4639-4652`).

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
- `Logger.error("Failed to start streaming: …")` at `streaming.ex:174`, written
  in the caller, which sets `Logger.put_process_level(self(), :none)` first
  (Elixir's API; OTP's `logger` exports no per-process level setter), so it is
  never emitted;
- crash reports from the stream server, the HTTP task and the metadata worker;
- an `erl_crash.dump`.

With no credential in the in-process request, the last two can carry only
request data: the
prompt, the context, tool output and the reply. The companion suppresses them
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
| Its cleanup ends everything that holds the request | Against a scripted transport, a stop and a deadline at each point of ReqLLM's real order: stream server started; HTTP task spawned but not linked; linked but before the handshake; running; metadata handle started; metadata worker running. And a normal completion. In each, the owner answers while the caller is blocked, every member's `DOWN` precedes the acknowledgement, no process that received the request remains, a task spawned but never handed its request exits on its own and never runs it, and `ReqLLM.TaskSupervisor` and the Finch pool are alive and serve the next call. A member whose exit a test seam withholds takes the unproved path. Both toolchain pairs run it |
| The companion path is unchanged | Every companion suite passes after the shared mapping is extracted; an ephemeral runtime with a hosted model composes `CredentialPlane` exactly as the durable one does; the durable profile refuses an `ollama:` model |
| Hygiene holds | `:req_llm` is started by no application start while the escript embeds its modules. A `.env` in the working directory is not loaded when composition starts ReqLLM. Each row of the start table; two concurrent first compositions starting it once; a second composition after a Loopex start proceeding; `loopex_composition` stopped and restarted, then a composition proceeding; ReqLLM stopped and restarted by the host with the persistent setting, loading no `.env`; the host turning loading back on, then refused; `warn_unverified_models` never written |
| The profile is ephemeral and says so | After a proved stop, or its caller exiting, no file remains under the profile's temporary root. The session value and `result` carry `profile: :ephemeral`, and `ask`'s JSON carries `"profile"` |
| No default authority | Composition without `:policy` refuses with `host_policy_required` |
| Skills are truthfully named | A `.agents/skills/<name>` directory in the workspace is `project:<name>`; a directory outside is `user:<name>` with its content digest; any other workspace directory refuses; a shared name admits the project skill and reports the user skill as shadowed; the same holds under `ask --state-root` |
| Rollback holds as stated | A durable root with a pending interaction written by the candidate recovers and is answered under `v0.2.0`, and the reverse; a pending call to `loopex.grep` resumed under `v0.2.0` is committed as `unknown_tool` and the run continues; a completed `loopex.grep` call in history replays under `v0.2.0`; a root with an admitted user skill, written by the candidate, has its retained snapshot reloaded by digest and its session resumed under `v0.2.0` |
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
core validation (`resource_pack.ex:203-216`, `:343-348`), so `0.2` reloads it.

**Unchanged:** the store format, the public protocol generations 1 and 2, the
executor protocol, the daemon, the companion and core's library.

**Removal.** Removing the profile deletes these and touches no durable byte:
- the in-process adapter, the memory store and the ephemeral composition;
- the ReqLLM start step and its holder, restoring automatic start;
- the `ask` command;
- the directory-reading function.
