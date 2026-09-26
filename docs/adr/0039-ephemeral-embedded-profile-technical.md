<a id="technical-depth"></a>
## Technical depth

Concept: [Ephemeral embedded profile](0039-ephemeral-embedded-profile.md#concept).

<a id="technical-adr-0039-decision"></a>
### Profile Composition

Concept: [Context and decision](0039-ephemeral-embedded-profile.md#concept-adr-0039-decision).

The kernel's ports are unchanged, and the profile only chooses what fills each one:

| Port | Durable profile | Ephemeral profile |
| --- | --- | --- |
| `Loopex.Store` (six callbacks) | `Loopex.Store.Local` | `Loopex.Store.Memory`, new, promoted from the core test fixture `Loopex.M1RuntimeTestStore` and held to `store_conformance_helper` |
| `Loopex.ArtifactStore` | `Loopex.Store.Local.Artifacts` | The memory store's artifact half, bounded by the same ceilings |
| `Loopex.Model` (`complete/3`) | `Loopex.LLM.ReqLLM` through the companion bridge | An in-process ReqLLM adapter in `apps/loopex_llm_reqllm` that maps the committed request's `messages`, `tools` and `sampling` to ReqLLM, and the response to `%{text, tool_calls, usage, identity, delta_count, streamed, canonical_request_bytes, staged_request_digest}`, reporting deltas through the progress function |
| `Loopex.Executor` | `Loopex.Executor.Local` | `Loopex.Executor.Local`, with its ledger root under the profile's temporary directory |
| `Loopex.Policy` | A named host policy | A named host policy; the presets are `allow_all`, `refuse_all` and `ask` |

**The in-process adapter:**

- It lives beside the companion adapter, so ReqLLM stays inside the one edge application that already carries it.
- It does not replace the companion adapter. Composition selects exactly one of the two per runtime, by profile.
- It refuses to start under a durable composition.
- The companion adapter keeps refusing any in-VM fallback, as ADR 0034 fixed.

**Credential variables.** `ollama` reads none and uses `OLLAMA_BASE_URL`, defaulting to `http://localhost:11434`. `openai` reads `OPENAI_API_KEY`, `anthropic` reads `ANTHROPIC_API_KEY`, and `openrouter` reads `OPENROUTER_API_KEY`. A provider whose variable is missing or empty refuses at composition with `provider_credential_required` naming the variable, never the value. The value is read once, held only in the adapter process's state, and passed to ReqLLM per call. It is never logged, journaled, rendered or placed in an event, a progress item, a diagnostic or a job.

**The ephemeral composition** (`LoopexComposition.ephemeral/1`, or an equivalent single entry):

- **Temporary root.** It creates one temporary directory under the host's temporary location, owned only by the composition and removed when the runtime stops.
- **Workspace.** It takes the workspace from `:cwd`, defaulting to the current directory.
- **Required options.** It requires `:policy`, and accepts `:model`, `:tools`, `:skills`, `:system`, `:max_steps`, `:tool_timeout_ms` and `:req_llm`.
- **Mapping.** It maps these onto the existing runtime options: bounds, context budget, sampling, and resource admission of the named skill directories.

<a id="technical-adr-0039-proofs"></a>
### Adapters and Proofs

Concept: [Observable consequences](0039-ephemeral-embedded-profile.md#concept-adr-0039-consequences).

| Obligation | Witness |
| --- | --- |
| The memory store is a store | The existing store conformance suite runs against `Loopex.Store.Memory` unchanged, including transaction, ownership-head, fencing and record-order cases |
| The in-process adapter is a model | The model streaming conformance suite runs against it with a scripted ReqLLM stub; a real-provider lane calls a local Ollama model and at least one hosted provider |
| Credentials stay out of every plane | A canary credential value is set, a full run with tool calls and a failure is driven, and the value is searched for in every committed record, event, progress item, diagnostic and log line and must be absent |
| The profile is ephemeral and says so | After the VM stops, no file remains under the profile's temporary root, no durable listing names the session, and the effective options name the profile |
| No default authority | Composition without `:policy` refuses with `host_policy_required`; `policy: :allow_all` is accepted |
| Durable is unchanged | The M5 lanes run unchanged; the companion adapter still refuses in-VM operation |
| Core is unchanged | `mix loopex.deps_budget` passes with core's dependency list still `:telemetry` alone |

<a id="technical-adr-0039-compatibility"></a>
### Compatibility Mechanics

Concept: [Compatibility and rollback](0039-ephemeral-embedded-profile.md#concept-adr-0039-compatibility).

**New surfaces**, all experimental under the 0.x policy:

- **API:** `Loopex.run/2`, `start_session/1`, `ask/2`, `history/1` and `stop_session/1`, thin wrappers over `create_session`, `attach`, `command` and `next_event`.
- **Command:** the `loopex -p` form and its flags.
- **Model strings:** the ephemeral profile's `provider:model` grammar.

**Unchanged:** the store format, the public protocol generations 1 and 2, the executor protocol, the daemon and the durable composition's required options and refusals. Removing the profile deletes two edge modules, one composition entry and one command form, and touches no durable byte.
