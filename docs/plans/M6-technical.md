<a id="technical-depth"></a>
## Technical depth

Concept: [M6 minimal runnable Loopex](M6.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](M6.md#concept-plan-purpose).

Concept: [Design decisions](M6.md#concept-plan-decisions).

M6 waits on one decision. It is accepted before the implementation that depends
on it, not before unrelated work, and it may not be outstanding at closure. The
repository status check reads the links in this section, so a decision named
only in prose declares nothing.

| Decision | Acceptance point | What its acceptance settles |
| --- | --- | --- |
| [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept) | Before the in-process model adapter, the memory store or the ephemeral composition is written. Outcome 6, the read-only tools and the composition's model option do not wait on it | Outcomes 1 to 4: the two profiles, the memory store's truth statement, the adapter and its credential and host-hygiene rules, the default model, the authority rule |

**The closure prerequisite, satisfied.** M5 closed on 2026-09-26 at the tested
implementation `fe020e24b62504f6f2fbc6c81711f399803b6fa9` (administrative
closure `3f81b04828901a6fb05b29e8b6bed211eed2d376`, tag `v0.2.0`).

**Maintainer decision, 2026-09-26: earlier milestones may be reworked.** The
maintainer authorized M6 to rework code delivered by M1 to M5 where the minimal
profile needs it. Every rework M6 makes is listed in
[Compatibility](#technical-plan-compatibility), and each keeps the M5 suites
and release lanes green. The vision's non-negotiables are not covered by this
decision: dependency direction, one serial owner, durability truth, plain
boundary data, and credential isolation for the durable profile.

**At acceptance of ADR 0039,** the acceptance change also updates the ADR index (`docs/adr/README.md`). The rows and prose for ADRs 0019 and 0034 gain "scoped to the durable profile by 0039", while both accepted records stay byte-for-byte unchanged.

**Deferrals.** No M6 outcome waits on these, and M6 runs no part of them:

- ADR 0035 stays Proposed and wholly deferred.
- ADRs 0036, 0037 and 0038 stay Proposed as prerequisites of the M7 and M8
  drafts.

<a id="technical-plan-ownership"></a>
### Ownership and Rejoin

Concept: [Scope](M6.md#concept-plan-scope).

| Workstream | Owns | Depends on | Rejoin order |
| --- | --- | --- | --- |
| A. Model and store | `Loopex.LLM.ReqLLM.InProcess` and the pure mapping it shares with the companion, in `apps/loopex_llm_reqllm/lib/loopex/llm/`; `Loopex.Store.Memory` in `apps/loopex_store_local/lib/loopex/store/`; the conformance runs for both | ADR 0039 | First: every later lane composes them |
| B. Composition | `LoopexComposition.Ephemeral` (the embedded API and its composition), the `:model`, `:bounds`, `:sampling` and `:active_tools` options on the durable `LoopexComposition.start/1`, and `ResourcePacks.read_directories/2` in `apps/loopex_composition` | A for the ephemeral profile; none for the durable options | Second |
| C. Command and tools | The `ask` subcommand and its `-p` alias, output modes and exit map in `apps/loopex_cli`; `loopex.grep`, `loopex.find`, `loopex.ls` in `apps/loopex_executor_local` | B | Third |
| D. Closure tooling and documentation | `mix loopex.closure.confine`, `mix loopex.closure.archive_compare` (in `apps/loopex/lib/mix/tasks/`, beside the existing checks), `scripts/stage-archive-manifest.sh`, `scripts/floor-lane.sh` and `scripts/attended-release.sh`; the getting-started paths and changed pages; the closure evidence scaffold | Outcome 6 is independent; documentation follows A to C | Last |

One integrator owns rejoin, conflicts and post-rejoin verification. Parallel
writers use one worktree each with non-overlapping paths. The integrator writes
the acceptance demonstration script (`scripts/m6-demonstration.sh`) first, and it
is the rejoin check for every workstream.

<a id="technical-plan-api"></a>
### The Embedded API Contract

Concept: [Scope](M6.md#concept-plan-scope).

**Where it lives.** The module is `LoopexComposition.Ephemeral` in
`apps/loopex_composition`. It is not in core, because composing edges (the
memory store, the model adapter, the executor) is what the dependency direction
forbids core to do. A host depends on `loopex_composition` alone. Core's
runtime library (`apps/loopex/lib` outside `mix/`) is unchanged by M6.

```elixir
@spec run(String.t(), keyword()) :: {:ok, result()} | {:error, reason()}
@spec start_session(keyword()) :: {:ok, session()} | {:error, reason()}
@spec ask(session(), String.t(), keyword()) :: {:ok, result()} | {:error, reason()}
@spec history(session()) :: {:ok, [message()]} | {:error, reason()}
@spec answer(session(), String.t(), map()) :: :ok | {:error, reason()}
@spec last_result(session()) :: {:ok, result()} | {:error, reason()} | :none
@spec stop_session(session()) :: :ok

@type result :: %{
        text: String.t(),            # the run's last assistant.message_appended content
        outcome: :completed,
        profile: :ephemeral,
        session_id: String.t(),
        run_id: String.t(),
        tools: [%{tool_id: String.t(), outcome: String.t()}]
      }
@type reason ::
        {:run, :failed | :bound_reached | :outcome_unknown | :cancelled, map()}
        | {:interaction_pending, map()}
        | :run_open
        | :timeout
        | {:composition, atom()}
        | {:invalid_option, atom()}
```

**Options.**

| Option | Meaning | Default |
| --- | --- | --- |
| `:policy` | Required: a module implementing `Loopex.Policy`. Composition ships no policy of its own, because host policy belongs to the host. The `ask` command maps its policy names to the reference CLI's policy modules | none; composition refuses `{:composition, :host_policy_required}` |
| `:model` | A `provider:model` string (ADR 0039) | `LOOPEX_MODEL`, else `"ollama:llama3.2"` |
| `:tools` | A preset, `:coding` (`read`, `write`, `edit`, `bash`) or `:read_only` (`read`, `grep`, `find`, `ls`). Only presets are accepted, because tool projections count against ADR 0017's system-class limit, and each preset carries a measured witness that it fits | `:coding` |
| `:skills` | At most four skill directory paths, ADR 0025's selection limit; admitted and activated under ADR 0039's rule | `[]` |
| `:cwd` | The workspace root for every tool | `File.cwd!()` |
| `:max_steps` | Mapped to the runtime bound `max_turns` | 16 |
| `:deadline_ms` | Mapped to the runtime bound `deadline_ms` | 600_000 |
| `:max_tokens` | Mapped to sampling `"max_tokens"` | 4_096 |
| `:context_token_budget` | The runtime's required budget | 8_192 |
| `:timeout` | How long `run/2` and `ask/3` wait for `run.finished` | `:deadline_ms` plus 30_000 |
| `:base_url` | Provider base URL override for the in-process adapter | the provider's default |

**Semantics:**

- **`run/2`** is `start_session/1`, `ask/3` and `stop_session/1`, with the stop
  always performed.
- **`start_session/1`** composes the ephemeral profile and starts one runtime,
  creates one session (`command_id` `"create"`), and attaches from sequence 0.
  The session value is a map with `session_id`, `profile: :ephemeral`, `model`,
  `tools`, `req_llm_started_by` and the owner process. The owner is linked to
  the caller and holds the runtime and the one attachment (`Runtime.attach`
  binds an attachment to its caller, `runtime.ex:346-348`). Every call below
  goes through the owner. `result` also carries `profile`.
- **`ask/3`** refuses with `{:error, :run_open}` while an earlier run of the
  session has no `run.finished`, for example after `interaction_pending`.
  Otherwise it:
  1. sends a prompt with `command_id` `"prompt-<n>"`;
  2. joins that command to its run through the `user.message_appended` event,
     which carries both `command_id` and `run_id` (`session_state.ex:4387-4396`);
  3. follows the attachment the way `LoopexCli.Render.follow` does, polling
     `next_event/1` at a 10 ms interval while it answers `{:error, :empty}`,
     until the `run.finished` with that `run_id`, or `:timeout`.

  Its results:
  - `completed` returns `{:ok, result}`, where `text` is the last
    `assistant.message_appended` content for that `run_id`.
  - Every other outcome returns `{:error, {:run, outcome, details}}`, where
    `details` is the `run.finished` payload without `run_id`, `outcome` and
    `command_id`, exactly as the command's JSON `details` defines it.
  - When the step limit is reached this is
    `{:error, {:run, :bound_reached, %{"bound" => "max_turns", ...}}}`.
  - An `interaction.requested` event for that run (a policy that defers)
    returns `{:error, {:interaction_pending, payload}}` and leaves the run open.
    `ask/3` does not answer on its own. The host answers with
    `answer(session, interaction_id, answer)`, which the owner sends as the
    existing `:interaction_answer` command. While a run is open, the owner keeps
    following the attachment, so `:run_open` clears as soon as that run's
    `run.finished` arrives. That ending is held for the host to read with
    `last_result(session)`.
- **`history/1`** returns the committed conversation projected from the public
  events, in `event_sequence` order:
  - `%{role: :user, text:}` from `user.message_appended`;
  - `%{role: :assistant, text:}` from `assistant.message_appended`;
  - `%{role: :tool, tool_id:, outcome:}` from `tool.finished`.
- **`stop_session/1`** is idempotent. If a run is open, it sends an abort
  command and waits for that run's `run.finished`, whatever its outcome (an abort
  can end `cancelled` or `outcome_unknown`), for at most the
  session's `cleanup_grace_ms` plus 5_000 ms. It then calls `Loopex.stop/1`,
  whose runtime shutdown runs the local executor's existing termination of the
  process groups it owns, and removes the temporary root only after the
  runtime has stopped.
- **One session per `start_session/1`.** Each call composes its own runtime and
  root. Concurrent sessions are separate runtimes, and no session shares a
  root.

**Failure of the owning process.** If the caller exits, the linked owner
performs the same abort, stop and removal sequence. There is no recovery, and
none is claimed.

<a id="technical-plan-adapter"></a>
### The In-Process Model Adapter Contract

Concept: [Scope](M6.md#concept-plan-scope).

`Loopex.LLM.ReqLLM.InProcess` implements `Loopex.Model.complete/3` inside the
host's VM. It does not replace the companion adapter `Loopex.LLM.ReqLLM`.
Composition selects exactly one per runtime: the durable profile always uses the
companion, and the ephemeral profile always uses the in-process adapter.

**Shared mapping.** The companion's pure mapping functions move into one module
both adapters use, `Loopex.LLM.ReqLLM.Mapping`, with no change in behaviour:

- the request context, `context_of` and `render_message`
  (`req_llm.ex:1031-1082`), including tool id to provider name by last dot
  segment (`:1091`);
- `provider_tools` (`:1117`);
- the delta translation, `emit` (`:815-883`);
- draining and finishing the stream, `drain` (`:502`) and its `finish_drain`
  and `failure_stage` steps;
- the stream completion check, `completed/1` (`:709`);
- response assembly, `ResponseBuilder` (`:746`);
- bounded tool calls, `bounded_calls` (`:770`);
- the reply, `reply/6` (`:676`);
- error classification, `raised_class` (`:590-672`).

`identity/1` (`:181`) is not shared, because it resolves a model string through
the catalog. The existing companion suites prove the unchanged behaviour. Only
the transport differs: the in-process adapter calls `ReqLLM.stream_text/3` in
its provider child, described below, instead of over the bridge. If a function in the list turns out to depend on companion-only state,
it stays in the companion and the in-process adapter gets its own copy, proved
by the same witness.

**Call options, fixed:**
- `api_key:` is always passed. It is the per-provider credential read at
  composition, or no key for Ollama.
- `max_retries: 0`.
- `receive_timeout` is the milliseconds left before the request's `deadline`.
- `max_tokens` comes from the request's sampling.
- `tools` come from the shared mapping.

ReqLLM's key lookup (`keys.ex:56-72`) is therefore never reached for a provider
that needs a key.

**Model specification.** The adapter builds an inline model:

```elixir
ReqLLM.model(%{provider: p, id: id, base_url: base_url_or_default})
```

The runtime's `model` field stays the `provider:model` string, as
`runtime.ex:1170-1171` requires. The adapter rebuilds the inline model from it
on every call, and uses it for both the reply's `identity` (provider, model id,
base URL as endpoint) and dispatch. No catalog lookup or
`Using unverified model` warning occurs for any provider. That matters because
Ollama models are absent from the pinned catalog.

| Prefix | Provider | Credential variable | Default base URL (ReqLLM 1.24.0) |
| --- | --- | --- | --- |
| `ollama:` | `:ollama` | none | `http://localhost:11434/v1` |
| `openai:` | `:openai` | `OPENAI_API_KEY` | `https://api.openai.com/v1` |
| `anthropic:` | `:anthropic` | `ANTHROPIC_API_KEY` | `https://api.anthropic.com` |
| `openrouter:` | `:openrouter` | `OPENROUTER_API_KEY` | `https://openrouter.ai/api/v1` |

The model grammar is `<prefix><id>`. The id is everything after the first colon,
so `ollama:qwen3:14b` names id `qwen3:14b`. Any other prefix refuses as
`{:composition, :unknown_provider}`.

**Host hygiene** (ReqLLM 1.24.0 facts, applied before `ReqLLM` starts):
- `Application.put_env(:req_llm, :load_dotenv, false, persistent: true)` and
  the same for `:llm_db`, as the companion does (`provider_worker.ex:78-79`), so starting ReqLLM never loads a `.env` from the working directory.
- `warn_unverified_models: false`.
- Then `Application.ensure_all_started(:req_llm)`.

If `:req_llm` is already running in the host VM, the adapter uses it as it is,
and the session value carries `req_llm_started_by: :host` (otherwise
`:loopex`). This is a named limitation:
a host that started ReqLLM with dotenv enabled has already loaded its `.env`.

**Errors.** The boundary is the call to `ReqLLM.stream_text/3` itself, exactly
where the companion places it (`req_llm.ex:416-453`, citing ADR 0018).
- **Before the call:** a refusal the adapter meets before calling
  `stream_text/3` is returned, never raised, as
  `{:error, {:not_dispatched, "model_call_failed"}}`. A raise is caught by the
  coordinator as `{:error, :provider_call_failed}` (`session_coordinator.ex:4149-4152`),
  which is `dispatched_or_unknown`.
  That covers model build, credential, context, tools and options, and a
  deadline already elapsed. This is the only form the coordinator retries
  (`@attempt_limit 2`).
- **From the call on:** every return or raise from `stream_text/3`, including
  `{:error, _}`, is `{:error, {:dispatched_or_unknown, "model_call_failed"}}`,
  because ReqLLM may already have started the HTTP transport before it returns
  an error (`deps/req_llm/lib/req_llm/streaming.ex:116-128`, `:172-175`). A
  possibly delivered call is never retried.

A stream that ends without its terminal event is checked through the metadata
before success: `:error`, a status of 400 or more, or `finish_reason` in
`[:incomplete, :cancelled, :error]` is not success.

**In-flight cleanup.** `complete/3` starts one provider child with
`ProviderLifetime.start_child/2` and registers it with
`ProviderLifetime.register/2`, the same coordinator hook the companion bridge
uses for its guardian (`provider_bridge.ex:207`, `:224`). It does both before
anything calls ReqLLM, so the coordinator's existing abort and deadline cleanup
owns the call from its start, and no stream server exists outside it. The child
itself:
1. sets `:logger.set_process_level(:none)` for itself;
2. calls `ReqLLM.stream_text/3`, so ReqLLM's stream server is started linked to
   the child (`deps/req_llm/lib/req_llm/streaming.ex:211`);
3. hands the drain to one linked drainer process it spawns. The drain blocks
   in `GenServer.call(server, {:next, timeout}, :infinity)`
   (`stream_server.ex:224`), so it cannot run in the child. The drainer reports
   deltas through the attempt's progress function and sends the assembled
   reply to the child;
4. stays responsive, and returns the reply to `complete/3` when the drainer
   delivers it.

On a stop, the child receives the coordinator's resource stop message,
`{:loopex_provider_resource_stop, stop_reference, stop, requester, cooperative_deadline, observation_deadline}`
(`session_coordinator.ex:4627-4634`). It then:
- calls `StreamResponse.close/1`, which cancels the stream and stops its
  metadata handle;
- kills the drainer;
- waits for the `DOWN` of both the stream server and the drainer, up to the
  cooperative deadline;
- answers `{:loopex_provider_resource_stopped, stop, self()}` (`:4641`), as the
  companion bridge does (`provider_bridge.ex:514-517`).

If the `DOWN`s do not arrive by the cooperative deadline, it does not answer,
and the coordinator's existing forced stop and unproved-cleanup path applies
(`:4646-4652`). Because the stream server and the drainer are linked to the
child, a forced kill of the child ends them too.

Aborting mid-stream, reaching the deadline mid-stream, and `stop_session/1`
therefore leave no ReqLLM stream server or Finch request task for that call.

**Credential rule.**
- The credential is read by `LoopexComposition.Ephemeral` once, from the
  provider's own variable, and held only in the adapter's configuration term
  inside the runtime.
- It is never written to a record, an event, a progress item, a diagnostic, a
  trace entry, a log line or an executor job.
- **Tool processes.** The executor's `bash` environment is constructed as
  `PATH=/usr/bin:/bin`. Today it explicitly removes only
  `LOOPEX_PROVIDER_API_KEY` after its snapshot of the environment
  (`executor.ex:5241-5258`), and that snapshot is not atomic against concurrent
  mutation. Core's receipt validation rejects only `LOOPEX_PROVIDER_API_KEY` as
  a child environment name (`session_state.ex:139`, `:3941`), and core is
  unchanged, so the broader clearing is the executor's alone. M6 reworks
  `spawn_environment` to remove `OPENAI_API_KEY`,
  `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY` explicitly as well, so no tool
  process inherits any provider credential.
- **The host's variable.** The library does not delete it. The `ask` command
  does, after reading it, as the durable path already does.
- **Logging and crash output in the host VM.** In the companion, ReqLLM runs
  with the primary logger level `:none`, an IO sink as group leader, and
  `ERL_CRASH_DUMP=/dev/null` (`provider_worker.ex:71-82`). None of that exists
  in the host VM, so three paths can carry request data:
  - ReqLLM's `Logger.error("Failed to start streaming: …")`
    (`deps/req_llm/lib/req_llm/streaming.ex:174`);
  - crash reports from ReqLLM's stream server and Finch tasks;
  - an `erl_crash.dump`.

  The profile answers them as follows:
  - **The stream-start log line** is written in the process that calls
    `ReqLLM.stream_text/3`, which is the adapter's provider child. The child
    calls `:logger.set_process_level(:none)` for itself (Erlang's API, which
    accepts `:none`). That is a process-scoped level, not a
    logger filter or handler and not a change to the host's configuration. That
    line is therefore never emitted, in either profile.
  - **The `ask` command** closes the other two paths for its own process:
    - before composing, it sets the primary logger level to `:none` and renders
      its own lines to standard error;
    - it sets `ERL_CRASH_DUMP=/dev/null` and `ERL_CRASH_DUMP_SECONDS=0` in its
      own environment at start, matching the companion (`provider_worker.ex:72`);
    - the launcher also exports it when its first argument is `ask` or `-p`.
    The witness proves on both platforms that a crash dump is not written when
    the escript is run directly as well as through the launcher. If one
    platform's emulator ignores a variable set after start, direct escript use
    on that platform is named as a limitation.
  - **A library host** owns its own logger, crash reports and crash dumps.
    Crash reports from ReqLLM's own stream and Finch processes are an accepted
    gap for a library host. The developer guide states the host's obligation,
    and ADR 0039 records the gap.
  - **The canary witness** drives three paths with a canary credential: the
    stream-start failure, a crash of the stream task, and a provider error
    reply.
    - The value must be absent from every committed plane in both profiles.
    - It must be absent from the stream-start log path in both profiles.
    - It must be absent from all captured log and crash output under `ask`.
    - Under a library host's default logger configuration, the crash-report
      path is recorded, not required: the witness retains what it observes, and
      the security review judges it against the accepted gap.

<a id="technical-plan-store"></a>
### The Memory Store Contract

Concept: [Scope](M6.md#concept-plan-scope).

**What the memory store is.** `Loopex.Store.Memory` is a supervised GenServer
over the shipped pure state module `Loopex.Store.Local.State`
(`apps/loopex_store_local/lib/loopex/store/local/state.ex`, 713 lines, no IO).
It is the same logic the local store replays from its log. It is the conformance
test wrapper `LoopexStoreLocalTest.Memory`
(`store_conformance_helper.exs:76-199`) promoted to library code:
- linked with `start_link`;
- it keeps the wrapper's GenServer state shape, so the conformance helper's
  `store_snapshot` (`store_conformance_helper.exs:1625`) reads it unchanged;
- it keeps an optional `:fault_probe` option. The option is active only when
  supplied, and follows the same checkpoint protocol as
  `Loopex.Store.Local.start_link(path:, fault_probe:)` (`local.ex:183`,
  `:242-257`), so the fault-injected cases (`each_store_with_unknown`,
  `:1017-1030`) exercise the shipped module. No composition passes a probe.

The core test fixture `Loopex.M1RuntimeTestStore` is not used: it is unlinked,
fault-instrumented, and grows without bound.

**Conformance.** The conformance helper's `:memory` kind switches from the test
wrapper to `Loopex.Store.Memory` itself (`start_store(:memory)`,
`store_conformance_helper.exs:1034-1038`). Every case, the fault-injected ones
included, then proves the shipped module.

**Truth statement.** Every committed record lives in the GenServer's state for
the life of the runtime and nowhere else. Stopping the runtime, or losing the VM,
loses the session, and no recovery is claimed. Memory grows with the session's
records, bounded by the runtime's existing turn, token and deadline bounds per
run but not across runs. That is a named limitation: an ephemeral session is
meant to be short, and a host that holds one open indefinitely pays for its
history.

**Artifacts.** The ephemeral profile composes no artifact store. Tool output over
a tool's byte bound is truncated with the executor's truncation notice and not
spilled (`executor.ex:4896-4920`), and the transfer family answers
`artifact_transfer_unsupported`. This is the same behaviour the runtime has always
had with `artifact_store: nil`.

<a id="technical-plan-composition"></a>
### The Composition Contract

Concept: [Scope](M6.md#concept-plan-scope).

**The ephemeral profile** (`LoopexComposition.Ephemeral`) starts, in order:
1. `:loopex`, `:loopex_store_local`, `:loopex_executor_local`, and `:req_llm`
   under the host-hygiene rule above.
2. A temporary root created with mode `0700` under `System.tmp_dir!()`.
3. `Loopex.Store.Memory`.
4. `WorkspaceLease` on `:cwd`.
5. `Executor.Local`, with its ledger root at `<tmp>/receipts` and no artifact
   store.
6. The runtime, with:
   - `store`, `model: %{module: Loopex.LLM.ReqLLM.InProcess, model: "<provider:model string>", options: adapter_options}`, where `adapter_options` carry the credential and the base URL only;
   - `executor`;
   - `tools: CodingTools.definitions()`;
   - `active_tools` from `:tools`;
   - `policy` and `policy_identity` (`%{"id" => inspect(policy), "revision" => Loopex.version()}`, the durable composition's existing default);
   - `bounds`, `sampling`, `context_token_budget`;
   - `resource_manifest` from `:skills`.

**Refusals** name the step: `{:composition, reason}`.

**The durable profile** (`LoopexComposition.start/1`) gains four optional
options:
- `:model` (a `provider:model` string, default the pinned
  `anthropic:claude-haiku-4-5`);
- `:bounds`;
- `:sampling`;
- `:active_tools`, which defaults to the four coding tools, so a durable
  composition's active set is unchanged when three new tools are defined.

The durable profile keeps the companion adapter and the single
`LOOPEX_PROVIDER_API_KEY` credential. A non-default `:model` must name a provider
that credential serves. A later decision on configuration (the M7 draft) may add
per-provider credentials.

**Skills by path.** `ResourcePacks.read_directories(paths, workspace_ref: ref)`
builds a resource manifest from named skill directories. What it does:
- **Validation:** the same `read_pack/3` validation discovery uses: `SKILL.md`
  with frontmatter whose name matches its directory, at most 64 files, at most
  1 MiB.
- **Identity:** each pack gets the local identity discovery already gives
  project skills, `source_id` `"project:<name>"` with `origin`, `commit` and
  `tree_digest` all nil (`resource_packs.ex:797-803`). Core's resource-pack
  validation needs no change.
- **What is recorded:** the host path is never recorded. Only the name,
  digests and admitted content enter the manifest, exactly as for a discovered
  project skill. A directory may lie outside the workspace.
- **Refusals:** two directories with the same skill name refuse as
  `{:composition, :duplicate_skill}`.
- **No project discovery:** the ephemeral profile and `ask` never discover or
  admit project resources. There is no `AGENTS.md` prompt and no
  `.agents/skills` walk, because a headless caller cannot answer a prompt. Only
  the directories named are admitted, so a named skill can never clash with a
  discovered one.
- **Provenance label:** the `project:` prefix is the only local identity core
  admits. It is a naming, not a claim that the directory is in the project. The
  decision's `decision_source` `host_supplied` records that the host supplied
  it.
- **Decision:** `decision_source` `host_supplied` with `trust_scope`
  `project_skills`, bound to the executor's workspace, as ADR 0025's admission
  record requires. ADR 0039 decides that naming the path is the host's
  admission decision.
- **Admission then activation.** After the session is created, the ephemeral
  API and `ask` send the same two commands the CLI sends for installed skills
  (`loopex_cli.ex:362` for `admit_resources`, `:445-469` for `activate_skill`): `admit_resources` with that decision, then one
  `activate_skill` per named skill. So ADR 0025's separation holds: only
  activated skills enter context, and the selection limit of four applies. A
  fifth directory refuses before composition as
  `{:invalid_option, :too_many_skills}`.
- **Workspace:** the manifest's `workspace_ref` is the executor's
  (`runtime.ex:921`).
- **Durable profile:** under `ask --state-root`, the admitted content is
  journaled as any admitted project skill's content already is.
- **Discovery** under `.agents/skills` keeps its interactive prompt.

<a id="technical-plan-command"></a>
### The Command Contract

Concept: [Scope](M6.md#concept-plan-scope).

**Grammar:**

```text
loopex ask [--model SPEC] [--output text|json] [--skill-dir DIR]... [--tools coding|read-only]
           --policy allow-all|shell-allowlist|refuse-all
           [--cwd DIR] [--max-steps N] [--deadline-ms N]
           [--state-root DIR] [--] [PROMPT...]
loopex -p ...        # the same as `loopex ask ...`
```

- The prompt is the remaining words, or standard input when none are given.
- An empty prompt refuses.
- `--skill-dir` is repeatable up to four times; every other flag may appear
  once. It is named apart from `run`'s `--skill`, which selects an installed
  skill by name.
- **Credentials at dispatch.** `composes_offline?` (`loopex_cli.ex:108-111`)
  includes `ask`, so `CredentialHost.discard/0` does not run before `ask`
  chooses its profile.
  - The durable profile then consumes `LOOPEX_PROVIDER_API_KEY` as `run` does.
  - The ephemeral profile reads only the chosen provider's own variable, and
    discards `LOOPEX_PROVIDER_API_KEY` from its environment unread.
- `refuse-all` joins the existing policy names. It becomes selectable for `ask`
  only.
- `ask` composes the ephemeral profile unless `--state-root` names a root.
  `LOOPEX_HOME` never switches profiles.
- With `--state-root`, it composes the durable profile and needs everything
  `run` needs: the built companion, `LOOPEX_PROVIDER_API_KEY` and a workspace.
  `--model` must then name a provider that credential serves.
- **Dispatch:** `main/1` treats a first argument of `ask` or `-p` as the `ask`
  subcommand. It is an offline form, and `--daemon` is not accepted.

**Text output.**
- Standard output carries only the final assistant text followed by a newline.
- Standard error carries the tool lines and the ending line, exactly as `run`
  renders them.

**JSON output.** One JSON object on standard output at the end, and nothing
else on standard output:

```json
{"schema": "loopex.ask/1", "session_id": "...", "run_id": "...",
 "outcome": "completed", "text": "...",
 "profile": "ephemeral",
 "tools": [{"tool_id": "loopex.read", "outcome": "ok"}],
 "details": {"reconciliation_ref": null, "cleanup_grace_ms": 5000}}
```

Every key of the `run.finished` payload other than `run_id`, `outcome` and
`command_id` is emitted in `details`, with `null` where the payload holds nil.
`profile` is `"ephemeral"` or `"durable"`.

`details` is the `run.finished` payload without `run_id`, `outcome` and
`command_id` (`session_state.ex:2880-2897`, `:4566-4576`, `:6061-6075`):
- `reason` and the `failure` map (category, retryable, and dimension, observed
  and limit where declared) for `failed`;
- `bound`, `observed`, `declared_limit` and `accounting_source` for
  `bound_reached`;
- `reconciliation_ref` for `outcome_unknown`;
- `cleanup_grace_ms` always.

Usage and model identity are not public events, so the object does not claim
them.

**Exit map for `ask`.** It uses values below the daemon's 65–111 and distinct
from 127 and 130:

| Status | Meaning |
| --- | --- |
| 0 | `completed` |
| 1 | Refusal or command error before the run (flags, policy, model, composition); the reason on standard error as `loopex: <reason>` |
| 2 | `failed` |
| 3 | `bound_reached` |
| 4 | `outcome_unknown` |
| 5 | `cancelled` |
| 6 | No `run.finished` within the wait: the follow window for the durable profile, or the `:timeout` for the ephemeral profile. The command then stops the session in the ephemeral profile, or leaves it running in the durable profile, and says so on standard error |
| 130 | The interrupt backstop, unchanged |

No `ask` policy defers: `allow-all` allows, and `shell-allowlist` and
`refuse-all` only deny. So `ask` has no deferred-interaction status. A deferring
policy is an API matter, surfaced there as `{:interaction_pending, _}`.

`run` keeps its documented statuses. The existing CLI and daemon maps are not
renumbered.

<a id="technical-plan-tools"></a>
### The Read-Only Tools Contract

Concept: [Scope](M6.md#concept-plan-scope).

Three tools join `CodingTools.definitions()`. Each has effect class `read_only`,
idempotency `safe_retry`, a wall-time budget of 30_000 ms, an output budget of
16_384 bytes, and artifact bytes of 0. Workspace confinement is by the existing
`CodingTools.resolve/2`: realpath containment and at most 32 symlink hops.
Output over the budget is byte-truncated with the existing truncation notice.

| Tool | Arguments (required) | Result |
| --- | --- | --- |
| `loopex.grep` 1.0.0 | `pattern` (an Elixir `Regex` source), optional `path` (default the workspace root), optional `glob` | Lines `path:line:text`, with paths relative to the workspace, at most 1_000 matches, files over 1 MiB skipped and named |
| `loopex.find` 1.0.0 | `pattern` (a `Path.wildcard/2` glob relative to `path`), optional `path` | Matching paths relative to the workspace, sorted, at most 2_000 |
| `loopex.ls` 1.0.0 | optional `path`, optional `recursive` (boolean, depth at most 8) | Entries with a trailing `/` for directories, sorted, at most 2_000 |

- None of them follows a symlink out of the workspace or runs a process.
- A bad pattern is `:invalid_tool_arguments`.
- They are active only where a composition's active set names them. The durable
  default stays the four coding tools, so `coding_task_test.exs:125` and every M5
  expectation hold unchanged.

<a id="technical-plan-closure-tooling"></a>
### The Closure Tooling Contract

Concept: [Scope](M6.md#concept-plan-scope).

| Command | Replaces | Contract |
| --- | --- | --- |
| `mix loopex.closure.confine TESTED ADMIN --name NAME` | the M5 `confinement.py` | Enforces the milestone guide's [confinement](../developer/milestones-technical.md#technical-milestones-confinement) exactly: direct parent; exactly the five paths; ordinary blobs with unchanged modes; byte reconstruction of `docs/plans/README.md` and root `README.md`; the Closure row only; the context map append only; the scaffold `Pending` cells only. It prints one `PASS`/`FAIL` line per check and writes the zero-context patch to a path the caller names |
| `scripts/stage-archive-manifest.sh SHA OUT` | the M5 inline staging | Stages `git archive SHA` under the [canonical rule](../developer/milestones-technical.md#technical-milestones-archive-extraction): a fresh directory, a subshell with `umask 022`, called from a caller that sets `umask 0777` and records both. It runs `scripts/source-archive-manifest.sh` with `OUT` outside the extraction, and copies `SOURCE_IDENTITY` beside `OUT` |
| `mix loopex.closure.archive_compare TESTED_MANIFEST ADMIN_MANIFEST TESTED ADMIN` | the M5 `archive_compare.py` | NUL framing, no duplicates, sorted; each projection against its commit's `git ls-tree -r -t --full-tree`; tested and administrative projections identical; tuples identical after removing `docs/**`, `README.md` and `SOURCE_IDENTITY`; each `SOURCE_IDENTITY` names its own commit and committer date |
| `scripts/floor-lane.sh SHA [--long-bound]` | the M5 `closure-lane.sh` | Makes a fresh clone at `SHA` on the floor pair. It raises the soft open-file limit to 65_536 (or the hard limit) and refuses below 4_096. It refuses to run when `SIGHUP` is ignored in its own disposition, read portably with `ps -o ignored= -p $$` (supported by both BSD and procps `ps`), and prints the mask. It runs `LOOPEX_CHECK_ALONE=loopex_llm_reqllm bash scripts/check.sh`, then the `long_bound` run in `apps/loopex_daemon` when asked, and writes each log with `EXIT=` and `DURATION_S=` |
| `scripts/attended-release.sh` | the terminal the M5 `loopex-release-driver.py` provided | Runs `scripts/check-release.sh` under the platform's `script(1)`, so the attended cases have a terminal: BSD `script -q -F /dev/null …` on macOS, and util-linux `script -q -f -e -c "…" /dev/null` on Linux. **A person answers the attended notices by default**, exactly as the release check has always required. The M5 driver-attendance disposition (`agent-context-map.md#disposition-m5-driver-attendance-2026-09-23`) applied to the M5 closure candidates only. The script's automatic mode (`--answer-attended`) is refused unless the caller names a recorded maintainer disposition for the current milestone's closure (`--disposition ANCHOR`), and that anchor must exist in the context map. In automatic mode it feeds a FIFO and writes `yes` only after the exact notice text is matched in the terminal output, ignoring carriage returns and its own echo. It redacts every provider credential name from the retained log, and prints `RELEASE_EXIT=` and `ATTENDED_ANSWERS=` |

Each command has a test against a fixture repository:
- `apps/loopex/test/closure_tooling_test.exs`;
- shell fixture tests run by `scripts/check.sh`.

The fixture reproduces a passing and a failing case for every check. The fast
check runs on both platforms at closure (hosted CI on Linux, and the Darwin floor
run), so the macOS and Linux branches of `script(1)` and `ps` are both executed.
Nothing uses Python or any tool outside the toolchain baseline.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M6.md#concept-plan-outcomes).

Concept: [How each outcome is verified](M6.md#concept-plan-verification).

| # | Witness files | What they prove | Lane |
| --- | --- | --- | --- |
| 1 | `apps/loopex_composition/test/ephemeral_api_test.exs` (new), with a scripted model adapter behind the same port | `run/2` answers; multi-turn `ask/3` keeps context; `{:error, {:run, :bound_reached, %{"bound" => "max_turns"}}}` at the step limit; a failed tool result reaches the next model call; `{:interaction_pending, _}` under a deferring policy, then `{:error, :run_open}` for the next `ask/3`, then `answer/3` resolving it and `last_result/1` returning the run's ending once the owner observes it; the command-to-run join choosing the right `run.finished`; `history/1` order and entry shapes; `stop_session/1` idempotent, aborting an open run, and confirming the executor's process groups are gone before removing its root; the owner doing the same when the caller exits | fast |
| 2 | `apps/loopex_llm_reqllm/test/in_process_adapter_test.exs` (new), covering mapping, options, errors and deltas against a scripted ReqLLM transport. Also: the existing streaming conformance suite run against the new adapter; `apps/loopex_llm_reqllm/test/in_process_real_test.exs` (new, `real_provider`); the unchanged companion suites; `apps/loopex_executor_local/test/provider_environment_test.exs` (new) | Request and reply mapping, including tool calls, deltas, and identity from the inline model. `api_key`, `max_retries: 0` and `receive_timeout` are always passed. The `not_dispatched`/`dispatched_or_unknown` split. No catalog warning for any provider. `load_dotenv` is off, so a `.env` in the working directory is not loaded. A canary credential is driven through three paths: the stream-start failure, a stream-task crash and a provider error reply. It is required to be absent from every committed record, event, progress item, diagnostic and trace entry, from the stream-start log path, and from all captured log and crash output under `ask`. What a library host's default logger captures from the stream-task crash is recorded for the security review, not required. The `ask` command's logger level and crash-dump setting. In-flight cleanup: an abort and a deadline mid-stream against a scripted transport that stalls. Deltas the drainer reports through the attempt's progress function, from its own process, reach the attachment's progress. The child answers `{:loopex_provider_resource_stop, …}` with `{:loopex_provider_resource_stopped, stop, self()}` while its drainer is blocked, the `DOWN`s of the stream server and drainer are observed, no stream server or Finch request task for the call remains, and a stream server that will not end takes the existing unproved-cleanup path. No provider variable reaches a `bash` child. Real calls to a local Ollama model and one hosted provider. The companion's behaviour is unchanged after the shared-mapping extraction | fast; release |
| 3 | The store conformance suite with `:memory` bound to `Loopex.Store.Memory`; `apps/loopex_composition/test/ephemeral_profile_test.exs` (new) | The memory store passes every conformance case. The ephemeral profile refuses without a policy, creates its root `0700`, removes it on stop and on owner exit, composes no artifact store, and names its profile | fast |
| 4 | `apps/loopex_cli/test/ask_command_test.exs` (new), `apps/loopex_cli/test/ask_exit_test.exs` (new), `apps/loopex_cli/test/ask_delegation_test.exs` (new), `apps/loopex_executor_local/test/read_only_tools_test.exs` (new), `apps/loopex_composition/test/skill_directories_test.exs` (new), `apps/loopex_composition/test/tool_preset_budget_test.exs` (new) | The grammar and refusals; `-p` identical to `ask`; a prompt from stdin; stdout carrying only the answer or only one JSON object; every exit status in the map, driven with a scripted model; the ephemeral profile with no `LOOPEX_HOME`; `--state-root` selecting the durable profile; the credential-discard order at dispatch; skill directories admitted and activated by path, refused when malformed, duplicated or more than four; `grep`/`find`/`ls` bounds, confinement and refusals; each tool preset's system-class projection measured under ADR 0017's limit; a separate OS process running `loopex -p` with a scripted model and reading its JSON, and driving the app server | fast |
| 5 | The M5 suites and release lanes, unchanged except the version literal; `mix loopex.deps_budget`; `git diff v0.2.0 -- apps/loopex/lib ':(exclude)apps/loopex/lib/mix'` empty at the tested candidate, and the only paths added under `apps/loopex/lib/mix/tasks/` being the two closure tasks | The durable profile, the companion, the daemon and both protocol generations unchanged; the durable composition's active tools still the four; core's runtime library and dependency list unchanged. `VERSION` moving to `0.3.0` changes `Loopex.version()`, read from `VERSION` at compile time (`loopex.ex:28-42`), and with it the `daemon_ready` version and the durable `policy_identity` revision. The tests that assert the literal `"0.2.0"` against the running build read `Loopex.version()` instead: `service_lifecycle_test.exs:139`, `daemon_command_test.exs:163,221` and `multi_client_workflow_test.exs:72`. `readiness_test.exs:11-42` passes the version as an argument to the pure encoder and stays unchanged. `scripts/check-release.sh:30`'s `release_version` moves to `0.3.0` as an explicit literal, so the release check still pins the intended release, and `DEVELOPMENT.md` states `0.3.0`. These are the only changes M6 makes to an M5 check's expectation | fast; release |
| 6 | `apps/loopex/test/closure_tooling_test.exs` (new) and the shell fixture tests | Each closure command reproduces the M5 closure's checks on a fixture, with a failing case for each; M6's own closure uses only them | fast; closure |
| — | An independent read-only security review of the ephemeral profile's credential path, naming the tested SHA | The credential rule and host hygiene hold, including in the logging paths. The credential sits in the runtime's `model.options` (`runtime.ex:1170`), so the review also covers every process that carries it: the provider-guard start message, callback closures, the runtime's and control plane's status and the crash paths of the guard and callback | closure |

**Evidence rules.**
- **Executed witnesses.** Every derived number has an executed witness before
  closure: the exit statuses, the tool bounds, the defaults, and the release
  manifest's row count.
- **Retained outputs.** Every release lane retains its complete output with a
  stable reference and a SHA-256 digest, recorded in
  `docs/evidence/M6-closure-runs.md`, which the tested candidate creates and
  indexes as a scaffold.
- **Release rows.** The manifest (`check-release.sh:135-157`) grows from nine
  real-provider rows to eleven, and its header comment changes with it:
  - row 10, `loopex_cli|test/ask_real_test.exs|ephemeral ask answers from a
    local Ollama model through a separate process`. The ephemeral profile runs
    against a local Ollama model, driven through `loopex -p --output json` from
    a separate OS process, which is also the real-provider agent-delegation
    case. It runs under `without_credential`: the manifest loop gains a
    per-row credential mode, since today it runs every row under
    `with_credential` (`check-release.sh:155`);
  - row 11, `loopex_composition|test/ephemeral_real_test.exs|the embedded API
    answers from Anthropic with the release credential`. The ephemeral
    profile's embedded API runs against Anthropic, the provider the release
    credential serves.
- **Release credentials.** The release credential stays
  `LOOPEX_PROVIDER_API_KEY`, an Anthropic key.
  - `with_credential` passes it to row 11 as `ANTHROPIC_API_KEY` for that row's
    process only.
  - `without_credential` unsets `LOOPEX_PROVIDER_API_KEY`, `OPENAI_API_KEY`,
    `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY`, so no credential-free lane or
    fast check can see one.
  - The wrapper's self-check and its log redaction cover all four names.
- **Release host precondition.** The release check requires
  `LOOPEX_RELEASE_OLLAMA_MODEL`, naming a model already pulled on a reachable
  local Ollama server. If it is missing or unreachable, the check fails as
  evidence unavailable. It never skips the row, and closure cannot proceed
  without it.

<a id="technical-plan-failures"></a>
### Ownership and Failure at Every Boundary

Concept: [Scope](M6.md#concept-plan-scope).

| Boundary | Owner | Failure and its answer |
| --- | --- | --- |
| Host process ↔ ephemeral owner | `LoopexComposition.Ephemeral` owner, linked to the caller and trapping exits | The caller exits: the owner aborts an open run, stops the runtime (the executor terminating its owned process groups) and then removes the root. The owner crashes: the linked caller receives the exit, and the runtime and executor, linked under the owner, stop with it; the root may remain, as with a hard VM kill, named in the limitations |
| Coordinator ↔ in-process adapter | The session coordinator, as for any model | A raise or exit inside the adapter is `dispatched_or_unknown` by the existing rule, and the run ends `failed`. A pre-dispatch refusal is retried once by the existing attempt limit |
| Adapter ↔ ReqLLM | The adapter | Stream start failure is `dispatched_or_unknown`. An incomplete stream is not success. A timeout bounded by the request deadline ends the run `failed` |
| Runtime ↔ memory store | The store GenServer, supervised under the ephemeral owner | Store loss is loss of the session. The runtime reports it by its existing classes, and nothing is recovered |
| Executor ↔ tools | The local executor, unchanged | Exactly its M5 behaviour; the three new tools are read-only in-VM file operations with byte bounds |
| `ask` ↔ caller | The CLI | Every outcome has one exit status; standard output carries only the result |

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

| Surface | M6 change | Label |
| --- | --- | --- |
| Core runtime library (`apps/loopex/lib` outside `mix/`) | None | Unchanged |
| Core Mix tasks (`apps/loopex/lib/mix/tasks/`) | Two closure tasks added beside the existing checks | Development tooling |
| `LoopexComposition.Ephemeral` | New | Experimental |
| `LoopexComposition.start/1` (M4/M5 rework) | Optional `:model`, `:bounds`, `:sampling`, `:active_tools`; defaults reproduce M5 exactly | Experimental, additive |
| `ResourcePacks.read_directories/2` | New | Experimental |
| The companion adapter (M1/M5 rework) | Pure mapping moved to `Loopex.LLM.ReqLLM.Mapping`; behaviour unchanged | Private refactor |
| Command line | `ask` and `-p` added; `refuse-all` selectable for `ask`, mapped to `LoopexCli.Policy.RefuseAll`; the launcher exports `ERL_CRASH_DUMP=/dev/null` for `ask` and `-p` only; every existing subcommand unchanged | Experimental |
| Local executor (M2 rework) | `spawn_environment` removes the three per-provider credential variables as well as `LOOPEX_PROVIDER_API_KEY` | Hardening; no contract change |
| Release check (M5 rework) | Two real-provider rows added; `release_version` moved to `0.3.0`; credential clearing and redaction cover the per-provider names; the Ollama precondition | Development tooling |
| Model strings | New `provider:model` grammar | Experimental |
| Coding tools (M2 rework) | Three read-only tools defined; the durable default active set unchanged | Additive |
| Store (M1 rework) | `Loopex.Store.Memory` promoted from the conformance test wrapper; the local store unchanged | Private; additive |
| Journal, store format, protocol generations 1 and 2, executor protocol, daemon | None | Unchanged |
| Toolchain | Both pairs; the floor pair still passes the fast check | Unchanged |

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

| Item | M6 answer |
| --- | --- |
| Supported source and target versions | `0.2` roots open unchanged under `0.3`; there is no new root format |
| Forward migration | None |
| Migration between profiles | None; an ephemeral session is never promoted to a durable one |
| Backup and restore or downgrade policy | Unchanged from `0.2`; the `0.2` binary opens every root `0.3` writes |
| Exact rollback | Return to `v0.2.0`; no durable byte depends on the ephemeral profile |

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

- **No new application** and no new dependency in any application:
  - the memory store is a module in `loopex_store_local`;
  - the in-process adapter and the shared mapping are in `loopex_llm_reqllm`,
    which already declares `{:req_llm, "~> 1.24.0"}`;
  - the ephemeral API is in `loopex_composition`;
  - the command is in `loopex_cli`.
- **Dependency budget:** `mix loopex.deps_budget` changes nowhere. The CLI
  reaches the ephemeral profile only through composition, as the client rules
  require.
- **Escript:** the escript build is unchanged. It still builds and embeds the
  companion for the durable profile. `ask` without `--state-root` does not need
  the companion.
- **Version:** `VERSION` moves to `0.3.0`.

**Minimalism budget:**
- The ephemeral API is one module that polls the existing facade.
- The adapter is one module over the shared mapping.
- The memory store is the promoted 125-line wrapper.
- The command is one parser branch and one renderer mode.
- The three tools are three definitions and three effect clauses.
- The closure tooling is two Mix tasks and three shell scripts.
- Nothing is added beyond that: no configuration framework, no second loop, no
  new process type in core.

<a id="technical-plan-limitations"></a>
### Named Limitations

Concept: [Non-goals](M6.md#concept-plan-non-goals).

| # | Limitation | Why it is accepted |
| --- | --- | --- |
| 1 | The ephemeral profile has no process isolation for the credential; it lives in the host VM | ADR 0039's stated trade; the durable profile keeps the companion |
| 2 | A host that already started ReqLLM with dotenv enabled has already loaded its `.env` | The adapter cannot undo another component's start; it records the state |
| 3 | A hard VM kill leaves the ephemeral temporary root behind | The root is under the host's temporary directory, mode `0700`, and holds no committed truth (the store is in memory) |
| 4 | The durable profile's `--model` must name a provider its single credential serves | Per-provider durable credentials belong to the M7 draft's configuration decision |
| 5 | `ask` offers no deferring policy; a deferred interaction is an API matter | Answering needs a client that holds the question; the app server and an embedding host are those clients |
| 6 | The JSON result carries no usage or model identity | They are not public events; adding them is a protocol decision |
| 7 | A library host's own logger, crash reports and crash-dump setting may capture request data from ReqLLM's failure paths | The host owns its VM's logging; the `ask` command closes these paths itself, and the developer guide names the host's obligation |
| 8 | An ephemeral session's memory grows with its history, bounded per run but not across runs | Ephemeral sessions are meant to be short; stopping the session releases it |
