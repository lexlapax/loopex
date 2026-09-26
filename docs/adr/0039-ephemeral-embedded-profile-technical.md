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
| `Loopex.Model` (`complete/3`) | `Loopex.LLM.ReqLLM` through the companion bridge | `Loopex.LLM.ReqLLM.InProcess`. Its `complete/3` starts one cleanup owner through the coordinator's provider-lifetime hook. The owner never calls ReqLLM; it starts one linked caller that resolves the credential, calls `ReqLLM.stream_text/3` and drains the stream over the mapping it shares with the companion (`Loopex.LLM.ReqLLM.Mapping`) |
| `Loopex.Executor` | `Loopex.Executor.Local`, ledger under the state root | `Loopex.Executor.Local`, ledger under the profile's temporary root |
| `Loopex.Policy` | A named host policy | A policy module supplied by the host; the reference CLI maps `allow-all`, `shell-allowlist` and `refuse-all` to its own modules |

**The in-process adapter:**
- **Placement:** it lives in `apps/loopex_llm_reqllm`, the one edge application
  that carries ReqLLM.
- **Selection:** composition selects exactly one of the two adapters per
  runtime, by profile. The companion adapter keeps refusing any in-VM fallback,
  as ADR 0034 fixed.

**Call options and hygiene** (ReqLLM 1.24.0):
- **Every call:** `api_key:` with the value the custodian resolved for this
  call, `max_retries: 0`, and `receive_timeout` set to the time left before the
  request deadline.
- **Inline model:** the model is built inline as
  `ReqLLM.model(%{provider:, id:, base_url:})`.
- **Start ownership:** `:req_llm` appears in no Loopex application's automatic
  start list; `loopex_llm_reqllm` still depends on it and every build that
  embeds the adapter still carries its code. The companion worker already
  starts it explicitly after its settings (`provider_worker.ex:43`, `:78-79`).
- **Before starting ReqLLM:** `load_dotenv: false` for `:req_llm` and `:llm_db`,
  and `warn_unverified_models: false`, then
  `Application.ensure_all_started(:req_llm)`.
- **Error classes:**
  - A refusal met before `ReqLLM.stream_text/3` is called is returned, never
    raised, as `{:not_dispatched, "model_call_failed"}`. That covers model build,
    credential, context, tools and options, and an elapsed deadline.
  - Every return or raise from that call, `{:error, _}` included, is
    `{:dispatched_or_unknown, "model_call_failed"}`, as the companion
    classifies it (`req_llm.ex:416-453`, citing ADR 0018), because ReqLLM may
    already have started its transport.
  - A stream is not a success until its metadata shows no `:error`, no status
    of 400 or more, and no `finish_reason` of `:incomplete`, `:cancelled` or
    `:error`.

**The credential custodian.** `LoopexComposition.Credentials` is one process
per ephemeral runtime, started and linked under the ephemeral owner.
- **Reference:** the runtime's model options carry `credential:
  {custodian_pid, reference}`, where `reference` is the plain string
  `"<provider>"` (for example `"anthropic"`). Nothing else about the credential
  is in runtime state.
- **Resolver:** the host passes `:credential_resolver`, a function of the
  provider reference returning `{:ok, value}`, `:none` or `{:error, reason}`.
  The default reads the provider's variable below at the moment it is asked.
- **Resolve and release:** the caller process asks
  `Credentials.checkout(custodian, reference)` immediately before
  `ReqLLM.stream_text/3`. The custodian resolves, registers the value in the
  filter's set with the caller's monitor, and returns it. The value leaves the
  set when the caller ends (its `DOWN`) and not before, because ReqLLM's
  processes hold it until then. The custodian stores no value outside that
  set.
- **Probe at composition:** composition resolves once and discards the value,
  so a missing credential refuses before any session exists.
- **Filter:** one primary filter with id `:loopex_credential_redaction`,
  installed with `:logger.add_primary_filter/2` by the first ephemeral runtime
  and removed by the last, counted through the custodians alive in the VM. It
  reads the current set from a protected ETS table the custodians own through
  one VM-level holder process. For an event it checks the formatted message,
  the report and the metadata for any value in the set with `:binary.match/2`,
  and returns `:stop` on a match, otherwise `:ignore`. An empty set costs one
  table lookup per event.

| Prefix | Default resolver variable |
| --- | --- |
| `ollama:` | None |
| `openai:` | `OPENAI_API_KEY` |
| `anthropic:` | `ANTHROPIC_API_KEY` |
| `openrouter:` | `OPENROUTER_API_KEY` |

- A credential that cannot be resolved refuses at composition with
  `provider_credential_required`, naming the reference or variable and never a
  value. A later failure before dispatch is `not_dispatched`.
- The library does not delete the host's variable. The `ask` command reads it
  through the default resolver and then deletes it from its own environment.
- The executor's `bash` environment removes `LOOPEX_PROVIDER_API_KEY`,
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY` explicitly.
- The caller process sets `Logger.put_process_level(self(), :none)` before
  calling ReqLLM, so ReqLLM's stream-start error line, written in that process,
  is never emitted. It is Elixir's API; OTP's `logger` exports no per-process
  level setter. The process ends with the call, so no level outlives it.

<a id="technical-adr-0039-relation-0019"></a>
### Shared-State and Diagnostic Facts

Concept: [What changes relative to ADR 0019](0039-ephemeral-embedded-profile.md#concept-adr-0039-relation-0019).

These facts are for ReqLLM 1.24.0, verified in `deps/req_llm`.

**What starting ReqLLM does.** Starting `:req_llm` starts `ReqLLM.Supervisor`,
with its Finch pool `ReqLLM.Finch`, `ReqLLM.TaskSupervisor` and a token cache.
It also initializes a provider registry in `persistent_term` and a named ETS
table. All of these are VM-global and named, so one ReqLLM serves every user in
the VM.

**Why ReqLLM's start must be owned.** `ReqLLM.Application.start/2` reads
`:load_dotenv` (default `true`) and loads `.env` from the working directory at
that moment (`application.ex:25-31`). With the adapter's application listing
ReqLLM for automatic start, any host that starts `loopex_composition` would
start ReqLLM first, and the setting would come too late.

**The composition's start step.** One VM-level step, serialized through the
filter's holder process so concurrent compositions cannot interleave:
1. If `:req_llm` is not running: put `load_dotenv: false` for `:req_llm` and
   `:llm_db` and `warn_unverified_models: false`, then
   `Application.ensure_all_started(:req_llm)`; record `req_llm_started_by:
   :loopex`.
2. If `:req_llm` is running and the host passed `req_llm: :host_started`: check
   `Application.get_env(:req_llm, :load_dotenv) == false`, and refuse
   `{:composition, :req_llm_dotenv_enabled}` otherwise; record
   `req_llm_started_by: :host`.
3. If `:req_llm` is running and the host did not declare it: refuse
   `{:composition, :req_llm_already_started}`.

The settings persist for the VM's life and are not restored: ReqLLM reads them
only at start, so restoring them would change nothing observable, and a later
restart of ReqLLM by the host is the host's act. Removing the profile removes
the step.

**Paths that can carry request data into the host:**
- `Logger.error("Failed to start streaming: …")` at `streaming.ex:174`;
- crash reports from the stream server and Finch tasks;
- the cache warning, which is off unless the `:cache` option is set, and the
  adapter never sets it;
- an `erl_crash.dump`.

**How the companion suppresses them.** It sets the primary logger level to
`:none`, an IO sink as group leader and `ERL_CRASH_DUMP=/dev/null`
(`provider_worker.ex:71-82`). The ephemeral profile instead removes the known
value from every logged event with the redaction filter, in a library host and
in `ask` alike. The `ask` command also sets the primary level to `:none` and
disables crash dumps for its own VM, which a library host does not get.

**Where the value lives during a call.** ReqLLM 1.24.0 takes only a binary
`api_key` (`keys.ex:56-72`) and does no redaction of its own. The value
therefore sits in the caller's frames and in the request state of the stream
server and the Finch task (`streaming/finch_client.ex:168`) while the call runs.
The filter covers their log output; a crash dump taken in that window can hold
it.

<a id="technical-adr-0039-proofs"></a>
### Adapters and Proofs

Concept: [Observable consequences](0039-ephemeral-embedded-profile.md#concept-adr-0039-consequences).

| Obligation | Witness |
| --- | --- |
| The memory store is a store | The store conformance suite's `:memory` kind is bound to `Loopex.Store.Memory` itself and passes unchanged |
| The in-process adapter is a model | Mapping, option and error tests run against a scripted ReqLLM transport. The model streaming conformance suite runs against it. Real-provider lanes call a local Ollama model and one hosted provider |
| The companion is unchanged | Every companion suite passes after the shared mapping is extracted |
| Credentials stay out of every plane | A canary credential value is resolved through the custodian, and a run with tool calls, a provider error reply, a stream-start failure, a stream-server crash and a Finch-task crash is driven. **Required:** the value is absent from every committed record, event, progress item, diagnostic and trace entry in both profiles; from the runtime's, coordinator's and guard's state and status as read by `:sys.get_state/1` and `:sys.get_status/1`; from the stream-start log path; and from every event a capturing handler receives, crash and supervisor reports included, under a library host's default logger configuration and under `ask`. The filter is present exactly while an ephemeral runtime exists and removed after the last one stops. The value leaves the filter's set when the caller ends. No provider variable reaches a tool process, because the executor removes all four names |
| Hygiene holds | `:req_llm` is started by no application start. A `.env` in the working directory is not loaded when composition starts ReqLLM; an already-running ReqLLM refuses unless declared, and a declared one with `.env` loading on refuses; two concurrent compositions start it once. No unverified-model warning is printed |
| The profile is ephemeral and says so | After the runtime stops, or its caller exits, no file remains under the profile's temporary root. The session value and `result` carry `profile: :ephemeral`, and `ask`'s JSON carries `"profile"` |
| No default authority | Composition without `:policy` refuses with `host_policy_required` |
| Skills are truthfully named | A `.agents/skills/<name>` directory in the workspace is `project:<name>`; a directory outside is `user:<name>` with its content digest; any other workspace directory refuses; a shared name admits the project skill and reports the user skill as shadowed |
| Rollback holds for pending interactions | A durable root with a pending interaction written by the candidate recovers and is answered under `v0.2.0`, and one written by `v0.2.0` under the candidate |
| Core is unchanged | `git diff v0.2.0 -- apps/loopex/lib` is empty outside `apps/loopex/lib/mix/`, and `mix loopex.deps_budget` passes unchanged |
| Independent review | A read-only security review of the ephemeral credential path names the tested SHA before closure |

<a id="technical-adr-0039-compatibility"></a>
### Compatibility Mechanics

Concept: [Compatibility and rollback](0039-ephemeral-embedded-profile.md#concept-adr-0039-compatibility).

**New surfaces**, all experimental under the 0.x policy:
- `LoopexComposition.Ephemeral`;
- `ResourcePacks.read_directories/2`;
- the `ask` command and its `-p` alias;
- the `provider:model` grammar.

**Additive options.** The durable `LoopexComposition.start/1` gains `:model`,
`:bounds`, `:sampling` and `:active_tools`, whose defaults reproduce M5.

**Durable policy revision.** The default durable `policy_identity` revision
(`loopex_composition.ex:259-261`) becomes the fixed string `"0.2.0"` instead of
`Loopex.version()`. The revision is persisted with each interaction
(`session_state.ex:1495`) and recovery requires exact equality
(`session_coordinator.ex:6591`), so deriving it from the release version would
leave a pending interaction suspended across an upgrade or a rollback. The
revision changes only when the reference policies' behaviour changes, and that
change is its own compatibility decision.

**Unchanged:** the store format, the public protocol generations 1 and 2, the
executor protocol, the daemon and core's library.

**Removal.** Removing the profile deletes these and touches no durable byte:
- two edge modules, the credential custodian with its filter, and the
  ephemeral composition;
- the `ask` command;
- the directory-reading function.
