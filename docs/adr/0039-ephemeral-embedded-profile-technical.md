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
| `Loopex.Policy` | A named host policy | A named host policy: `allow_all`, `shell_allowlist`, `refuse_all` or a module |

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
- The executor's `bash` environment is constructed with the credential unset.

<a id="technical-adr-0039-proofs"></a>
### Adapters and Proofs

Concept: [Observable consequences](0039-ephemeral-embedded-profile.md#concept-adr-0039-consequences).

| Obligation | Witness |
| --- | --- |
| The memory store is a store | The store conformance suite's `:memory` kind is bound to `Loopex.Store.Memory` itself and passes unchanged |
| The in-process adapter is a model | Mapping, option and error tests run against a scripted ReqLLM transport. The model streaming conformance suite runs against it. Real-provider lanes call a local Ollama model and one hosted provider |
| The companion is unchanged | Every companion suite passes after the shared mapping is extracted |
| Credentials stay out of every plane | A canary credential value is set. A run with tool calls, a provider failure and a stream-start failure is driven. The value must be absent from every committed record, event, progress item, diagnostic, trace entry, captured log line and `IO.warn` output |
| Hygiene holds | A `.env` in the working directory is not loaded, and no unverified-model warning is printed |
| The profile is ephemeral and says so | After the runtime stops, or its caller exits, no file remains under the profile's temporary root, and the effective options name the profile |
| No default authority | Composition without `:policy` refuses with `host_policy_required` |
| Core is unchanged | `git diff v0.2.0 -- apps/loopex/lib` is empty, and `mix loopex.deps_budget` passes unchanged |
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
