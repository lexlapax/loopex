<a id="technical-depth"></a>
## Technical depth

Concept: [Ephemeral embedded profile](0039-ephemeral-embedded-profile.md#concept).

<a id="technical-adr-0039-decision"></a>
### Profile Composition

Concept: [Context and decision](0039-ephemeral-embedded-profile.md#concept-adr-0039-decision).

The kernel's ports are unchanged; the profile chooses what fills each one:

| Port | Durable profile | Ephemeral profile |
| --- | --- | --- |
| `Loopex.Store` (six callbacks) | `Loopex.Store.Local` | `Loopex.Store.Memory`: a supervised process over `Loopex.Store.Local.State`, the conformance test wrapper `LoopexStoreLocalTest.Memory` promoted without its fault probe |
| `Loopex.ArtifactStore` | `Loopex.Store.Local.Artifacts` | None; the runtime's existing `artifact_store: nil` behaviour (overflow truncated with the executor's notice, transfers unsupported) |
| `Loopex.Model` (`complete/3`) | `Loopex.LLM.ReqLLM` through the companion bridge | `Loopex.LLM.ReqLLM.InProcess`, calling `ReqLLM.stream_text/3` in the coordinator's model attempt over the mapping it shares with the companion (`Loopex.LLM.ReqLLM.Mapping`) |
| `Loopex.Executor` | `Loopex.Executor.Local`, ledger under the state root | `Loopex.Executor.Local`, ledger under the profile's temporary root |
| `Loopex.Policy` | A named host policy | A policy module supplied by the host; the reference CLI maps `allow-all`, `shell-allowlist` and `refuse-all` to its own modules |

**The in-process adapter:**
- **Placement:** it lives in `apps/loopex_llm_reqllm`, the one edge application
  that carries ReqLLM.
- **Selection:** composition selects exactly one of the two adapters per
  runtime, by profile. The companion adapter keeps refusing any in-VM fallback,
  as ADR 0034 fixed.

**Call options and hygiene** (ReqLLM 1.24.0):
- **Every call:** `api_key:`, `max_retries: 0`, and `receive_timeout` set to the
  time left before the request deadline.
- **Inline model:** the model is built inline as
  `ReqLLM.model(%{provider:, id:, base_url:})`.
- **Before starting ReqLLM:** `load_dotenv: false` for `:req_llm` and `:llm_db`,
  and `warn_unverified_models: false`.
- **Error classes:**
  - Everything before `stream_text/3` returns `{:ok, _}` is
    `{:not_dispatched, "model_call_failed"}`.
  - Everything after is `{:dispatched_or_unknown, "model_call_failed"}`.
  - A stream is not a success until its metadata shows no `:error`, no status
    of 400 or more, and no `finish_reason` of `:incomplete`, `:cancelled` or
    `:error`.

**Credential variables:**

| Prefix | Credential variable |
| --- | --- |
| `ollama:` | None |
| `openai:` | `OPENAI_API_KEY` |
| `anthropic:` | `ANTHROPIC_API_KEY` |
| `openrouter:` | `OPENROUTER_API_KEY` |

- A missing or empty variable refuses at composition with
  `provider_credential_required`, naming the variable and never the value.
- The library does not delete the host's variable. The `ask` command does,
  after reading it.
- The executor's `bash` environment removes `LOOPEX_PROVIDER_API_KEY`,
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY` explicitly.
- The adapter installs no logger filter or handler, changes no group leader,
  and never restarts ReqLLM's supervision tree. It sets
  `Logger.put_process_level(self(), :none)` only for its own model-attempt
  process, so ReqLLM's stream-start error line, which is written in that
  process, is never emitted. Its only change to shared state
  is the two ReqLLM application settings it makes before first starting ReqLLM.

<a id="technical-adr-0039-relation-0019"></a>
### Shared-State and Diagnostic Facts

Concept: [What changes relative to ADR 0019](0039-ephemeral-embedded-profile.md#concept-adr-0039-relation-0019).

These facts are for ReqLLM 1.24.0, verified in `deps/req_llm`.

**What starting ReqLLM does.** Starting `:req_llm` starts `ReqLLM.Supervisor`,
with its Finch pool `ReqLLM.Finch`, `ReqLLM.TaskSupervisor` and a token cache.
It also initializes a provider registry in `persistent_term` and a named ETS
table. All of these are VM-global and named, so one ReqLLM serves every user in
the VM.

**The adapter's settings.** Before first starting ReqLLM, the adapter sets
`load_dotenv: false` for `:req_llm` and `:llm_db`, and
`warn_unverified_models: false`. When ReqLLM is already running, it sets
nothing and records that ReqLLM was already started.

**Paths that can carry request data into the host:**
- `Logger.error("Failed to start streaming: …")` at `streaming.ex:174`;
- crash reports from the stream server and Finch tasks;
- the cache warning, which is off unless the `:cache` option is set, and the
  adapter never sets it;
- an `erl_crash.dump`.

**How the companion suppresses them.** It sets the primary logger level to
`:none`, an IO sink as group leader and `ERL_CRASH_DUMP=/dev/null`
(`provider_worker.ex:71-82`). The `ask` command reproduces the logger and
crash-dump parts for its own process. A library host does not get them.

<a id="technical-adr-0039-proofs"></a>
### Adapters and Proofs

Concept: [Observable consequences](0039-ephemeral-embedded-profile.md#concept-adr-0039-consequences).

| Obligation | Witness |
| --- | --- |
| The memory store is a store | The store conformance suite's `:memory` kind is bound to `Loopex.Store.Memory` itself and passes unchanged |
| The in-process adapter is a model | Mapping, option and error tests run against a scripted ReqLLM transport. The model streaming conformance suite runs against it. Real-provider lanes call a local Ollama model and one hosted provider |
| The companion is unchanged | Every companion suite passes after the shared mapping is extracted |
| Credentials stay out of every plane | A canary credential value is set. A run with tool calls, a provider error reply, a stream-start failure and a stream-task crash is driven. The value must be absent from every committed record, event, progress item, diagnostic, trace entry, captured log line and `IO.warn` output under the default logger configuration. The `ask` command runs with the primary logger level `:none` and `ERL_CRASH_DUMP=/dev/null`. No provider variable reaches a tool process, because the executor removes all four names |
| Hygiene holds | A `.env` in the working directory is not loaded, and no unverified-model warning is printed |
| The profile is ephemeral and says so | After the runtime stops, or its caller exits, no file remains under the profile's temporary root, and the effective options name the profile |
| No default authority | Composition without `:policy` refuses with `host_policy_required` |
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

**Unchanged:** the store format, the public protocol generations 1 and 2, the
executor protocol, the daemon and core's library.

**Removal.** Removing the profile deletes these and touches no durable byte:
- two edge modules and the ephemeral composition;
- the `ask` command;
- the directory-reading function.
