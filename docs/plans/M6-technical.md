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
| [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept) | Before the in-process model adapter, the memory store, the ephemeral composition, named skill directories or the fixed policy revision is written. Outcome 6, the read-only tools and the durable composition's model, bounds, sampling and active-tool options do not wait on it | Outcomes 1 to 5: the two profiles, the memory store's truth statement, the model adapter chosen by credential, the in-process call's process-tree cleanup, the ReqLLM start step, the default model, the skill rule with its two ADR 0025 supersessions, the fixed durable policy revision and its two rollback exceptions, the authority rule, and `ask`'s machine contract |

**The closure prerequisite, satisfied.** M5 closed on 2026-09-26 at the tested
implementation `fe020e24b62504f6f2fbc6c81711f399803b6fa9` (administrative
closure `3f81b04828901a6fb05b29e8b6bed211eed2d376`, tag `v0.2.0`).

**Maintainer decision, 2026-09-26: earlier milestones may be reworked.** The
maintainer authorized M6 to rework code delivered by M1 to M5 where the minimal
profile needs it. Every rework M6 makes is listed in
[Compatibility](#technical-plan-compatibility), and each keeps the M5 suites
and release lanes green. The vision's non-negotiables are not covered by this
decision: dependency direction, one serial owner, durability truth, plain
boundary data, and credential isolation.

**Maintainer decisions, 2026-09-26, after the second external review:**
- a credential-bearing provider runs through the companion in both profiles;
  only a credential-free provider runs in the host VM;
- user skill directories are admitted in both profiles, with ADR 0039
  superseding ADR 0025's source and name-order clauses explicitly;
- the durable profile may activate the new read-only tools, and the rollback
  claim is narrowed to name what `0.2` does with them;
- the in-process call's cleanup walks the call's linked process tree.

**At acceptance of ADR 0039,** the acceptance change also updates the ADR index
(`docs/adr/README.md`): ADR 0019's row and prose gain "narrowed by 0039 for
credential-free providers in the ephemeral profile", and ADR 0025's gain
"source and name-order clauses superseded by 0039 for named skill
directories". All accepted records stay byte-for-byte unchanged.

**Deferrals.** No M6 outcome waits on these, and M6 runs no part of them:

- ADR 0035 stays Proposed and wholly deferred.
- ADRs 0036, 0037 and 0038 stay Proposed as prerequisites of the M7 and M8
  drafts.

<a id="technical-plan-ownership"></a>
### Ownership and Rejoin

Concept: [Scope](M6.md#concept-plan-scope).

| Workstream | Owns | Depends on | Rejoin order |
| --- | --- | --- | --- |
| A. Model and store | `Loopex.LLM.ReqLLM.InProcess` with its cleanup owner, and the pure mapping it shares with the companion, in `apps/loopex_llm_reqllm/lib/loopex/llm/`; ReqLLM's removal from automatic start in `apps/loopex_llm_reqllm/mix.exs`; `Loopex.Store.Memory` in `apps/loopex_store_local/lib/loopex/store/`; the conformance runs for both | ADR 0039 | First: every later lane composes them |
| B. Composition | `LoopexComposition.Ephemeral` (the embedded API and its composition), the ReqLLM start step and its holder, the durable `LoopexComposition.start/1` options `:model`, `:bounds`, `:sampling`, `:active_tools` and `:skill_directories` and its fixed policy revision, and `ResourcePacks.read_directories/2`, in `apps/loopex_composition` | A for the ephemeral profile; none for the durable options | Second |
| C. Command and tools | The `ask` subcommand and its `-p` alias, output modes and exit map in `apps/loopex_cli`; `loopex.grep`, `loopex.find`, `loopex.ls` in `apps/loopex_executor_local` | B | Third |
| D. Closure tooling and documentation | `mix loopex.closure.confine`, `mix loopex.closure.archive_compare` (in `apps/loopex/lib/mix/tasks/`, beside the existing checks), `scripts/stage-archive-manifest.sh`, `scripts/floor-lane.sh` and `scripts/attended-release.sh` with their fixture tests; P1 to P4; the getting-started paths and changed pages; the closure evidence scaffold | Outcome 6 is independent; documentation follows A to C | Last |

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
@spec stop_session(session()) :: :ok | {:error, {:cleanup_unproved, unproved()}}

@type result :: %{
        text: String.t(),            # the run's last assistant.message_appended content
        outcome: :completed,
        profile: :ephemeral,
        session_id: String.t(),
        run_id: String.t(),
        tools: [%{tool_id: String.t(), outcome: String.t()}],
        shadowed_skills: [String.t()]
      }
@type unproved :: %{
        root: String.t(),            # the kept temporary root
        pending: [:run_ending | :effect_cleanup | :process_groups],
        ending: {:ok, result()} | {:error, reason()} | :none   # run/2 only
      }
@type reason ::
        {:run, :failed | :bound_reached | :outcome_unknown | :cancelled, map()}
        | {:interaction_pending, map()}
        | {:cleanup_unproved, unproved()}   # from run/2 only, after its stop
        | :run_open
        | :timeout
        | {:composition, atom()}
        | {:invalid_option, atom()}
```

**Options.**

| Option | Meaning | Default |
| --- | --- | --- |
| `:policy` | Required: a module implementing `Loopex.Policy`. Composition ships no policy of its own, because host policy belongs to the host. The `ask` command maps its policy names to the reference CLI's policy modules | none; composition refuses `{:composition, :host_policy_required}` |
| `:model` | A `provider:model` string (ADR 0039). `ollama:` uses the in-process adapter; any other provider uses the companion | `LOOPEX_MODEL`, else `"ollama:llama3.2"` |
| `:provider_launch` | For a companion model only: the four managed launch options `mix loopex.provider.build` writes to its `.launch` file, exactly as the durable `LoopexComposition.start/1` takes them (`loopex_composition.ex:167-175`) | none; a companion model without it refuses `{:composition, :provider_launch_required}` |
| `:req_llm` | `:host_started` declares that the host started ReqLLM itself with `.env` loading off; read only when the in-process adapter is selected | absent |
| `:tools` | A preset, `:coding` (`read`, `write`, `edit`, `bash`) or `:read_only` (`read`, `grep`, `find`, `ls`). Only presets are accepted, because tool projections count against ADR 0017's system-class limit, and each preset carries a measured witness that it fits | `:coding` |
| `:skills` | At most four skill directory paths, ADR 0025's selection limit: each a project skill (`.agents/skills/<name>` in the `:cwd` workspace) or a user skill (outside it); admitted and activated under ADR 0039's rule | `[]` |
| `:cwd` | The workspace root for every tool, and the root against which `:skills` are classified | `File.cwd!()` |
| `:max_steps` | Mapped to the runtime bound `max_turns` | 16 |
| `:deadline_ms` | Mapped to the runtime bound `deadline_ms` | 600_000 |
| `:max_tokens` | Mapped to sampling `"max_tokens"` | 4_096 |
| `:context_token_budget` | The runtime's required budget | 8_192 |
| `:timeout` | How long `run/2` and `ask/3` wait for `run.finished` | `:deadline_ms` plus 30_000 |
| `:base_url` | Base URL override for the in-process adapter | the provider's default |

A companion model needs `LOOPEX_PROVIDER_API_KEY`, consumed exactly as the
durable composition consumes it (`LoopexComposition.CredentialPlane`), and the
model must name a provider that credential serves.

**Semantics:**

- **`run/2`** is `start_session/1`, `ask/3` and `stop_session/1`, with the stop
  always performed. When the stop returns `cleanup_unproved`, `run/2` returns
  `{:error, {:cleanup_unproved, unproved}}` whatever the run's ending, because
  the caller must learn of the kept root; the run's ending is in the unproved
  map as `ending`.
- **`start_session/1`** composes the ephemeral profile and starts one runtime,
  creates one session (`command_id` `"create"`), and attaches from sequence 0.
  The session value is a map with `session_id`, `profile: :ephemeral`, `model`,
  `adapter` (`:in_process` or `:companion`), `tools`, `req_llm_started_by` (nil
  for a companion model) and the owner process. The owner is linked to the
  caller and holds the runtime and the one attachment (`Runtime.attach` binds an
  attachment to its caller, `runtime.ex:346-348`). Every call below goes through
  the owner. `result` also carries `profile`.
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
    `details` is exactly the per-outcome projection the command's JSON
    `details` defines.
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
  process groups it owns. It removes the temporary root, and returns `:ok`,
  only when all three are proved:
  1. the open run's `run.finished` arrived;
  2. an aborted run ended `cancelled`, which the coordinator commits only when
     the provider and executor cleanup were both confirmed; an abort with
     unconfirmed cleanup ends `outcome_unknown`
     (`session_coordinator.ex:6000-6006`), which leaves this item unproved;
  3. every process group the local executor owned is proved empty by its
     existing process-table check (`executor.ex:6335-6377`) after the runtime
     has stopped. The owner learns the groups from the executor, never from a
     tool's output.

  Otherwise it keeps the root, returns
  `{:error, {:cleanup_unproved, %{root: path, pending: [...], ending: :none}}}`
  naming each unproved item (`:run_ending`, `:effect_cleanup`,
  `:process_groups` for items 1 to 3), and writes nothing else. A later
  `stop_session/1` on the same session repeats item 3's check for the groups
  still unproved and removes the root once it passes; items 1 and 2 stay
  unproved for the life of the VM, so the root then stays for the host to
  remove.
- **One session per `start_session/1`.** Each call composes its own runtime and
  root. Concurrent sessions are separate runtimes, and no session shares a
  root.

**Failure of the owning process.** If the caller exits, the linked owner
performs the same abort, stop and removal sequence, and keeps the root on the
same conditions; with no caller left to tell, it writes the kept root's path to
the host's logger as one warning. There is no recovery, and none is claimed.

<a id="technical-plan-adapter"></a>
### The In-Process Model Adapter Contract

Concept: [Scope](M6.md#concept-plan-scope).

`Loopex.LLM.ReqLLM.InProcess` implements `Loopex.Model.complete/3` inside the
host's VM for credential-free providers only: `ollama` in M6. It does not
replace the companion adapter `Loopex.LLM.ReqLLM`. Composition selects exactly
one adapter per runtime by the model's provider; a credential-bearing provider
always gets the companion, in either profile.

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
its caller process, described below, instead of over the bridge. If a function
in the list turns out to depend on companion-only state, it stays in the
companion and the in-process adapter gets its own copy, proved by the same
witness.

**Call options, fixed:** `max_retries: 0`; `receive_timeout` is the
milliseconds left before the request's `deadline`; `max_tokens` from the
request's sampling; `tools` from the shared mapping. No `api_key` is ever
passed, and the adapter refuses any provider outside its credential-free list
with `{:error, {:not_dispatched, "credential_required"}}` before ReqLLM is
called.

**Model specification.** The adapter builds an inline model:

```elixir
ReqLLM.model(%{provider: :ollama, id: id, base_url: base_url_or_default})
```

The runtime's `model` field stays the `provider:model` string, as
`runtime.ex:1170-1171` requires. The adapter rebuilds the inline model from it
on every call, and uses it for both the reply's `identity` (provider, model id,
base URL as endpoint) and dispatch. No catalog lookup or
`Using unverified model` warning occurs. That matters because Ollama models are
absent from the pinned catalog. The default base URL is ReqLLM 1.24.0's
`http://localhost:11434/v1`.

The model grammar is `<prefix><id>`. The id is everything after the first colon,
so `ollama:qwen3:14b` names id `qwen3:14b`. A prefix neither the in-process
adapter nor the companion serves refuses as `{:composition, :unknown_provider}`.

**Host hygiene** follows ADR 0039's technical companion, which states the start
table once:
- `loopex_llm_reqllm` keeps its dependency on `req_llm` but removes it from the
  applications started with it; `loopex_composition` depends on
  `loopex_llm_reqllm` (`mix.exs:30`), which depends on `req_llm` (`mix.exs:61`),
  so without this, starting either would start ReqLLM and load `.env`
  (`deps/req_llm/lib/req_llm/application.ex:25-31`) before any Loopex code ran;
- the escript and every build that carries the adapter still carry ReqLLM's
  code; a host building its own OTP release lists `req_llm: :load`, which the
  developer guide states and a witness checks against a fixture release;
- the companion worker already starts ReqLLM explicitly after its own settings
  (`provider_worker.ex:43`, `:78-79`) and is unchanged;
- the start step runs only when the in-process adapter is selected, through the
  VM-level holder started with `loopex_composition`, which records whether
  Loopex or the host started ReqLLM so a later composition proceeds.

**Errors.** The boundary is the call to `ReqLLM.stream_text/3` itself, exactly
where the companion places it (`req_llm.ex:416-453`, citing ADR 0018).
- **Before the call:** a refusal the adapter meets before calling
  `stream_text/3` is returned, never raised, as
  `{:error, {:not_dispatched, "model_call_failed"}}`. A raise is caught by the
  coordinator as `{:error, :provider_call_failed}`
  (`session_coordinator.ex:4149-4152`), which is `dispatched_or_unknown`. That
  covers model build, context, tools and options, and a deadline already
  elapsed. This is the only form the coordinator retries (`@attempt_limit 2`).
- **From the call on:** every return or raise from `stream_text/3`, including
  `{:error, _}`, is `{:error, {:dispatched_or_unknown, "model_call_failed"}}`,
  because ReqLLM may already have started the HTTP transport before it returns
  an error (`deps/req_llm/lib/req_llm/streaming.ex:116-128`, `:172-175`). A
  possibly delivered call is never retried.

A stream that ends without its terminal event is checked through the metadata
before success: `:error`, a status of 400 or more, or `finish_reason` in
`[:incomplete, :cancelled, :error]` is not success.

**In-flight cleanup.** Each call has two processes of its own:
1. **The cleanup owner.** `complete/3` starts it with
   `ProviderLifetime.start_child/2` and registers it with
   `ProviderLifetime.register/2`, the coordinator hook the companion bridge uses
   for its guardian (`provider_bridge.ex:207`, `:224`), before anything calls
   ReqLLM. It traps exits and never calls ReqLLM or blocks, so it answers a
   stop at any stage, stream start included.
2. **The caller.** A process the owner spawns linked. It sets
   `Logger.put_process_level(self(), :none)` (Elixir's API; OTP's `logger`
   exports no per-process level setter), calls `ReqLLM.stream_text/3`, drains
   the stream, reports deltas through the attempt's progress function, hands the
   assembled reply to the owner, and waits for the owner.

ReqLLM's own per-call processes, and the membership rule that finds them, are
in ADR 0039's
[per-call process tree](../adr/0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-tree):
the stream server and metadata handle linked to the caller, the HTTP task linked
to the stream server, and the metadata worker linked to the handle. On a stop,
on a deadline, and on the caller handing over its reply, the owner suspends and
walks that tree, kills every member with `:kill`, waits for every member's
`DOWN`, and only then acknowledges
`{:loopex_provider_resource_stopped, stop, self()}` (`session_coordinator.ex:4641`)
or returns the reply. A missing `DOWN` withholds the acknowledgement, and the
coordinator's existing forced stop and unproved-cleanup path applies
(`:4646-4652`). The facts hold for the locked ReqLLM 1.24.0, and the witness
fails if a ReqLLM update changes them.

**Diagnostics.** No credential is in the host VM on this path. What ReqLLM's
failure paths can log is request data: the stream-start line is silenced in the
caller; crash reports from the stream server, HTTP task and metadata worker,
and a crash dump, can hold the prompt, context, tool output or reply. The `ask`
command sets the primary logger level to `:none`, renders its own lines, and
sets `ERL_CRASH_DUMP=/dev/null` and `ERL_CRASH_DUMP_SECONDS=0` for its own VM,
matching the companion (`provider_worker.ex:71-82`); the launcher also exports
them when its first argument is `ask` or `-p`. A library host owns its logger
and crash dumps, and the developer guide says so.

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
1. `:loopex`, `:loopex_store_local` and `:loopex_executor_local`; then, for an
   in-process model, ReqLLM through the start step, or, for a companion model,
   `LoopexComposition.CredentialPlane` exactly as the durable composition
   opens it (`loopex_composition/edges.ex:40-52`).
2. A temporary root created with mode `0700` under `System.tmp_dir!()`.
3. `Loopex.Store.Memory`.
4. `WorkspaceLease` on `:cwd`.
5. `Executor.Local`, with its ledger root at `<tmp>/receipts` and no artifact
   store.
6. The runtime, with:
   - `store`;
   - `model`: for an in-process model
     `%{module: Loopex.LLM.ReqLLM.InProcess, model: "<provider:model>", options: [base_url: url]}`;
     for a companion model the durable composition's model term with
     `:provider_launch` and the credential plane's opaque model options
     (`loopex_composition.ex:224-229`);
   - `executor`;
   - `tools: CodingTools.definitions()`;
   - `active_tools` from `:tools`;
   - `policy` and `policy_identity` (`%{"id" => inspect(policy), "revision" => "0.2.0"}`, the durable composition's default, fixed below);
   - `bounds`, `sampling`, `context_token_budget`;
   - `resource_manifest` from `:skills`.

**Refusals** name the step: `{:composition, reason}`.

**The durable profile** (`LoopexComposition.start/1`) gains five optional
options:
- `:model` (a `provider:model` string the single credential serves, default the
  pinned `anthropic:claude-haiku-4-5`);
- `:bounds`;
- `:sampling`;
- `:active_tools`, a list of defined tool ids, which defaults to the four coding
  tools, so a durable composition's active set is unchanged when three new tools
  are defined; naming `loopex.grep`, `loopex.find` or `loopex.ls` is allowed,
  with the rollback exception below;
- `:skill_directories`, the same classification and admission as the ephemeral
  `:skills`, against the durable workspace.

The durable profile keeps the companion adapter and the single
`LOOPEX_PROVIDER_API_KEY` credential. A later decision on configuration (the M7
draft) may add per-provider credentials.

**The durable policy revision.** The default `policy_identity`
(`loopex_composition.ex:259-261`, the only place it is derived) changes its
revision from `Loopex.version()` to the fixed `"0.2.0"`. The revision is stored
with each interaction (`session_state.ex:1509`) and recovery compares it for
exact equality (`session_coordinator.ex:6593`), so a version-derived revision
would leave a pending interaction suspended after an upgrade to `0.3.0` or a
rollback to `0.2.0`. A host-supplied `:policy_identity` is unchanged.

**Skills by path.** `ResourcePacks.read_directories(paths, workspace: dir,
workspace_ref: ref)` builds a resource manifest from named skill directories.
`workspace` is the absolute workspace root the executor leases (`:cwd`), used
only to classify; `workspace_ref` is the executor's opaque reference
(`runtime.ex:921`), recorded in the manifest. Existing discovery already takes
both (`resource_packs.ex:76-78`). What it does:
- **Validation:** the same `read_pack/3` validation discovery uses: `SKILL.md`
  with frontmatter whose name matches its directory, at most 64 files, at most
  1 MiB.
- **Classification,** after resolving the realpaths of the directory and of
  `workspace`:
  - exactly `<workspace>/.agents/skills/<name>`: a project skill, `source_id`
    `"project:<name>"`, the identity discovery already gives
    (`resource_packs.ex:797-803`);
  - not under `<workspace>`: a user skill, `source_id` `"user:<name>"`;
  - anywhere else under `<workspace>`: refused as
    `{:composition, :unclassified_skill_directory}`.

  Both kinds carry `origin`, `commit` and `tree_digest` nil. Core's
  resource-pack validation accepts any bounded label as `source_id` and nil Git
  provenance (`resource_pack.ex:203-216`, `:343-348`), so it needs no change.
  A user skill's identity is bound to the content digest the manifest already
  records for its files; the admission decision binds the whole manifest's
  digest.
- **What is recorded:** the host path is never recorded. Only the identity,
  digests and admitted content enter the manifest.
- **Local wins.** A project skill and a user skill with the same name: the
  project skill is admitted, and the user skill is left out of the manifest and
  reported as shadowed (`shadowed_skills` in the API result, and in `ask`'s
  JSON). Because the shadowed pack never enters the manifest, core never sees
  an ambiguous name. Two directories of the same kind with the same name refuse
  as `{:composition, :duplicate_skill}`.
- **No project discovery:** the ephemeral profile and `ask` never walk a
  directory on their own. There is no `AGENTS.md` prompt and no
  `.agents/skills` walk, because a headless caller cannot answer a prompt.
- **Decision:** `decision_source` `host_supplied` with `trust_scope`
  `project_skills`, the one scope core admits (`resource_pack.ex:125`), read as
  the skills admitted for this workspace's session and bound to the executor's
  workspace, as ADR 0025's admission record requires. ADR 0039 decides that
  naming the path is the host's admission decision and that a user skill's
  `user:` identity is its truthful provenance.
- **Admission then activation.** After the session is created, the ephemeral
  API and `ask` send the same two commands the CLI sends for installed skills
  (`loopex_cli.ex:362` for `admit_resources`, `:445-469` for `activate_skill`):
  `admit_resources` with that decision, then one `activate_skill` per admitted
  skill. So ADR 0025's separation holds: only activated skills enter context,
  and the selection limit of four applies. A fifth directory refuses before
  composition as `{:invalid_option, :too_many_skills}`; a shadowed directory
  still counts toward the four.
- **Durable profile:** under `:skill_directories` and `ask --state-root`, the
  admitted content is journaled as any admitted project skill's content already
  is. Discovery under `.agents/skills` keeps its interactive prompt.

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

- The prompt is the remaining words, or standard input when none are given; an
  empty prompt refuses, and one over 1 MiB refuses.
- `--skill-dir` is repeatable up to four times; every other flag may appear
  once. Each names a project or user skill directory under the composition's
  skill rule, classified against `--cwd`. It is named apart from `run`'s
  `--skill`, which selects an installed skill by name.
- `--tools read-only` under `--state-root` activates `loopex.grep`,
  `loopex.find` and `loopex.ls` in the durable profile, with the rollback
  exception.
- **Models.** `ollama:` runs in-process. Any other provider runs through the
  companion the escript embeds (`LoopexCli.ProviderLaunch.options/0`) and needs
  `LOOPEX_PROVIDER_API_KEY`, in either profile. In `ask`'s own VM nothing
  starts ReqLLM before composition does, so `ask` always takes the start
  table's first row.
- **Credentials at dispatch.** `composes_offline?` (`loopex_cli.ex:108-111`)
  includes `ask`, so `CredentialHost.discard/0` does not run before `ask`
  chooses its adapter. A companion model then consumes `LOOPEX_PROVIDER_API_KEY`
  as `run` does; an in-process model discards it unread.
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
else on standard output. A refusal before the run (status 1) writes nothing to
standard output.

```json
{"schema": "loopex.ask/1", "session_id": "...", "run_id": "...",
 "outcome": "completed", "text": "...", "text_truncated": false,
 "profile": "ephemeral",
 "tools": [{"tool_id": "loopex.read", "outcome": "ok"}], "tools_truncated": false,
 "shadowed_skills": [],
 "cleanup": {"proved": true},
 "details": {"cleanup_grace_ms": 5000}}
```

**The member set is closed.** The top-level members are exactly those above,
as ADR 0039 lists them. `details` is a projection of the `run.finished` payload
(`session_state.ex:2880-2897`, `:4566-4576`, `:6061-6075`) with exactly these
members per outcome, `null` where the payload holds nil, and any other payload
member dropped:

| `outcome` | `details` members |
| --- | --- |
| `completed`, `cancelled` | `cleanup_grace_ms` |
| `failed` | `reason`, `failure` (`category`, `retryable`, `dimension`, `observed`, `limit`), `cleanup_grace_ms` |
| `bound_reached` | `bound`, `observed`, `declared_limit`, `accounting_source`, `cleanup_grace_ms` |
| `outcome_unknown` | `reconciliation_ref`, `bound`, `observed`, `declared_limit`, `accounting_source`, `cleanup_grace_ms` (the bound members non-null only when a deadline caused it) |
| `no_ending` (status 6) | `waited_ms`; `run_id` is then the run's id if known, else `null` |

**Bounds.** `text` is at most 1 MiB, cut at a UTF-8 boundary with
`text_truncated` true; `tools` at most 256 entries, with `tools_truncated`;
`shadowed_skills` at most four names; every other string at most 1 KiB, the
runtime's own identifiers already being shorter.

**Cleanup.** `cleanup` is `{"proved": true}`, or, when `stop_session/1` returned
`cleanup_unproved` in the ephemeral profile, `{"proved": false, "root": "...",
"pending": [...]}`. The exit status still reports the run's outcome, and
standard error names the kept root. A durable run's `cleanup` is always
`{"proved": true}`, because the durable profile keeps its session.

Usage and model identity are not public events, so the object does not claim
them. Adding a member is a new schema name.

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
| 6 | No `run.finished` within the wait: the follow window for the durable profile, or the `:timeout` for the ephemeral profile. The command then stops the session in the ephemeral profile, or leaves it running in the durable profile, says so on standard error, and writes the `no_ending` object under `--output json` |
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
| `scripts/attended-release.sh` | the terminal the M5 `loopex-release-driver.py` provided | Runs `scripts/check-release.sh` under the platform's `script(1)`, so the attended cases have a terminal: BSD `script -q -F /dev/null …` on macOS, and util-linux `script -q -f -e -c "…" /dev/null` on Linux. **A person answers the attended notices by default**, exactly as the release check has always required. The M5 driver-attendance disposition (`agent-context-map.md#disposition-m5-driver-attendance-2026-09-23`) applied to the M5 closure candidates only. The script's automatic mode (`--answer-attended`) is refused unless the caller names a recorded maintainer disposition (`--disposition ANCHOR`) that authorizes it for this run. The script checks, and prints each check: the anchor exists in `docs/developer/agent-context-map.md` at `HEAD`; its entry names the milestone `--milestone NAME` that the caller passes; its entry names the full 40-character SHA of `HEAD`, which must equal the clean checkout being tested; and its entry states automatic attended answers are authorized. Any failed check refuses before `check-release.sh` starts. In automatic mode it feeds a FIFO and writes `yes` only after the exact notice text is matched in the terminal output, ignoring carriage returns and its own echo. It redacts `LOOPEX_PROVIDER_API_KEY` from the retained log, and prints `RELEASE_EXIT=` and `ATTENDED_ANSWERS=` |

Each command has tests against a fixture repository:
- `apps/loopex/test/closure_tooling_test.exs` for the two Mix tasks;
- `scripts/test/stage-archive-manifest-test.sh`,
  `scripts/test/floor-lane-test.sh` and `scripts/test/attended-release-test.sh`
  for the three scripts, each run by `scripts/check.sh`.

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
| 1 | `apps/loopex_composition/test/ephemeral_api_test.exs` (new), with a scripted model adapter behind the same port | `run/2` answers; multi-turn `ask/3` keeps context; `{:error, {:run, :bound_reached, %{"bound" => "max_turns"}}}` at the step limit; a failed tool result reaches the next model call; `{:interaction_pending, _}` under a deferring policy, then `{:error, :run_open}` for the next `ask/3`, then `answer/3` resolving it and `last_result/1` returning the run's ending once the owner observes it; the command-to-run join choosing the right `run.finished`; `history/1` order and entry shapes; `stop_session/1` idempotent, aborting an open run, and removing the root only after all three cleanup items are proved; with each item made unprovable in turn (an abort that ends `outcome_unknown`, a run ending that never arrives, a process group that survives), `cleanup_unproved` naming that item, the root kept, and a later stop removing it once only item 3 was pending and now passes; `run/2` returning `cleanup_unproved` with the run's ending; the owner doing the same when the caller exits and logging the kept root | fast |
| 2 | `apps/loopex_llm_reqllm/test/in_process_adapter_test.exs` (new), against a scripted ReqLLM transport; `apps/loopex_llm_reqllm/test/in_process_cleanup_test.exs` (new); `apps/loopex_composition/test/req_llm_start_test.exs` (new); the existing streaming conformance suite run against the new adapter; the unchanged companion suites; `apps/loopex_llm_reqllm/test/in_process_real_test.exs` (new, `real_provider`) | Request and reply mapping, including tool calls, deltas, and identity from the inline model. `max_retries: 0` and `receive_timeout` always passed and `api_key` never. Every non-Ollama provider refused before ReqLLM is called. The `not_dispatched`/`dispatched_or_unknown` split. No catalog warning. `Logger.put_process_level/2` accepting `:none` on the floor pair. Cleanup, at each stage (stream server only; stream server and metadata handle; all four processes) and for a stop, a deadline and a normal completion: the owner answers while the caller is blocked, every member's `DOWN` precedes the acknowledgement, none of the four processes remains, and `ReqLLM.TaskSupervisor` and the Finch pool are alive and serve the next call; a member whose exit a test seam withholds takes the unproved path. Hygiene: `:req_llm` absent from every Loopex application's start list while the escript embeds its modules and a fixture release built with `req_llm: :load` starts; each row of ADR 0039's start table, including two concurrent first compositions starting ReqLLM once and a later composition proceeding; a `.env` in the working directory not loaded. With `LOOPEX_PROVIDER_API_KEY` set to a canary, an in-process run leaves it in no plane, no process state and no captured log event. Real calls to a local Ollama model | fast; release |
| 2 | `apps/loopex_composition/test/ephemeral_companion_test.exs` (new), against the companion's existing scripted provider | An ephemeral runtime with a companion model composes `CredentialPlane` exactly as the durable one does, refuses without `:provider_launch`, answers through the companion, and leaves `LOOPEX_PROVIDER_API_KEY` absent from the VM environment after composition | fast |
| 3 | The store conformance suite with `:memory` bound to `Loopex.Store.Memory`; `apps/loopex_composition/test/ephemeral_profile_test.exs` (new) | The memory store passes every conformance case. The ephemeral profile refuses without a policy, creates its root `0700`, removes it after a proved stop and on owner exit, keeps it after an unproved one, composes no artifact store, and names its profile | fast |
| 4 | `apps/loopex_cli/test/ask_command_test.exs` (new), `apps/loopex_cli/test/ask_exit_test.exs` (new), `apps/loopex_cli/test/ask_delegation_test.exs` (new), `apps/loopex_executor_local/test/read_only_tools_test.exs` (new), `apps/loopex_composition/test/skill_directories_test.exs` (new), `apps/loopex_composition/test/tool_preset_budget_test.exs` (new) | The grammar and refusals; `-p` identical to `ask`; a prompt from stdin; stdout carrying only the answer or only one JSON object; every exit status in the map, driven with a scripted model; the ephemeral profile with no `LOOPEX_HOME`; `--state-root` selecting the durable profile; the credential-discard order at dispatch for both adapters; the JSON member set and `details` per outcome exactly as tabled, every bound and truncation flag, the `no_ending` object, the `cleanup` member for both results, and nothing on standard output for a refusal; skill directories classified against the workspace, a workspace `.agents/skills/<name>` as `project:<name>`, an outside directory as `user:<name>`, another workspace directory refused, a shared name admitting the project skill and reporting the user skill as shadowed, refusals when malformed, duplicated within a kind or more than four, and the same under `--state-root`; `grep`/`find`/`ls` bounds, confinement and refusals; each tool preset's system-class projection measured under ADR 0017's limit; a separate OS process running `loopex -p` with a scripted model and reading its JSON, and driving the app server | fast |
| 5 | The M5 suites and release lanes, unchanged except the version literal; `mix loopex.deps_budget`; `git diff v0.2.0 -- apps/loopex/lib ':(exclude)apps/loopex/lib/mix'` empty at the tested candidate, and the only paths added under `apps/loopex/lib/mix/tasks/` being the two closure tasks | The durable profile, the companion, the daemon and both protocol generations unchanged; the durable composition's default active tools still the four; core's runtime library and dependency list unchanged. `VERSION` moving to `0.3.0` changes `Loopex.version()`, read from `VERSION` at compile time (`loopex.ex:28-42`), and with it the `daemon_ready` version; the durable `policy_identity` revision stays `"0.2.0"`. The tests that assert the literal `"0.2.0"` against the running build read `Loopex.version()` instead: `service_lifecycle_test.exs:139`, `daemon_command_test.exs:163,221` and `multi_client_workflow_test.exs:72`. `readiness_test.exs:11-42` passes the version as an argument to the pure encoder and stays unchanged. `scripts/check-release.sh:30`'s `release_version` moves to `0.3.0` as an explicit literal, and `DEVELOPMENT.md` states `0.3.0`. These are the only changes M6 makes to an M5 check's expectation | fast; release |
| 5 | `apps/loopex_cli/test/rollback_test.exs` (new, release lane `rollback`), against a `v0.2.0` build made from a fresh `git archive v0.2.0` and a scripted model | A durable root holding a pending interaction written by the candidate recovers, and the interaction is answered, under `v0.2.0`, and the reverse; a pending call to `loopex.grep` written by the candidate, resumed under `v0.2.0`, is committed as a failed `unknown_tool` call and the run continues; a root with an admitted user skill, written by the candidate, replays under `v0.2.0` with the skill's recorded content. The default `policy_identity` revision is `"0.2.0"` under both | release |
| 6 | `apps/loopex/test/closure_tooling_test.exs` (new); `scripts/test/stage-archive-manifest-test.sh`, `scripts/test/floor-lane-test.sh`, `scripts/test/attended-release-test.sh` (new); `bash scripts/check.sh --docs` | Each closure command reproduces the M5 closure's checks on a fixture, with a failing case for each; the attended runner refuses automatic mode for a missing anchor, another milestone, another SHA and an entry without the authorization, and accepts only the exact one; M6's own closure uses only them; P1 to P4 are in place and the documentation check passes | fast; closure |
| 1–4 | `scripts/m6-demonstration.sh`, the single acceptance demonstration, run from a clean checkout with no `LOOPEX_HOME` on macOS and on Linux | Its four steps in order, each printing its own `PASS` or `FAIL` line and the elapsed time; the complete output of each platform's run retained with its reference and SHA-256 digest in `docs/evidence/M6-closure-runs.md` | closure |
| — | An independent read-only security review of the in-process path and the ephemeral companion path, naming the tested SHA, retained as `docs/evidence/M6-security-review.md` with the reviewer's retained output reference and SHA-256 digest | No credential reaches the in-process path; the ephemeral companion path composes the credential plane exactly as the durable one; the process-tree walk kills only the call's own processes; hygiene holds | closure |

**Evidence rules.**
- **Executed witnesses.** Every derived number has an executed witness before
  closure: the exit statuses, the tool bounds, the defaults, and the release
  manifest's row count.
- **Retained outputs.** Every release lane retains its complete output with a
  stable reference and a SHA-256 digest, recorded in
  `docs/evidence/M6-closure-runs.md`, which the tested candidate creates and
  indexes as a scaffold.
- **Release rows.** The manifest (`check-release.sh:135-157`) grows from nine
  real-provider rows to eleven, and its header comment changes with it. The
  `rollback` lane is a separate `--only rollback` lane beside them, credential
  free, because it drives a scripted model:
  - row 10, `loopex_cli|test/ask_real_test.exs|ephemeral ask answers from a
    local Ollama model through a separate process`. The ephemeral profile runs
    against a local Ollama model, driven through `loopex -p --output json` from
    a separate OS process, which is also the real-provider agent-delegation
    case. It runs under `without_credential`: the manifest loop gains a
    per-row credential mode, since today it runs every row under
    `with_credential` (`check-release.sh:155`);
  - row 11, `loopex_composition|test/ephemeral_real_test.exs|the embedded API
    answers through the companion with the release credential`. The ephemeral
    profile's embedded API runs an Anthropic model through the companion, under
    `with_credential` as every existing row does.
- **Release credentials.** The release credential stays
  `LOOPEX_PROVIDER_API_KEY`, an Anthropic key, handled exactly as today.
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
| Host process ↔ ephemeral owner | `LoopexComposition.Ephemeral` owner, linked to the caller and trapping exits | The caller exits: the owner aborts an open run, stops the runtime (the executor terminating its owned process groups) and removes the root only when cleanup is proved, otherwise keeping it and logging its path. The owner crashes: the linked caller receives the exit, and the runtime and executor, linked under the owner, stop with it; the root may remain, as with a hard VM kill, named in the limitations |
| Coordinator ↔ either adapter | The session coordinator, as for any model | A raise or exit inside the adapter is `dispatched_or_unknown` by the existing rule, and the run ends `failed`. A pre-dispatch refusal is retried once by the existing attempt limit |
| Cleanup owner ↔ the call's process tree | The in-process adapter's cleanup owner, registered with the coordinator before the call | A stop, a deadline or completion walks and kills the whole tree and answers only after every `DOWN`; a missing `DOWN` withholds the answer, and the coordinator's unproved-cleanup path applies |
| Adapter ↔ ReqLLM | The in-process adapter | Stream start failure is `dispatched_or_unknown`. An incomplete stream is not success. A timeout bounded by the request deadline ends the run `failed` |
| Composition ↔ ReqLLM's start | The start step, serialized in the VM-level holder | An undeclared ReqLLM started by the host, or a declared one with `.env` loading on, refuses before any root exists |
| Composition ↔ companion | `CredentialPlane` and the companion bridge, unchanged | Exactly their M5 behaviour; a missing `:provider_launch` or credential refuses before any root exists |
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
| `LoopexComposition.start/1` (M4/M5 rework) | Optional `:model`, `:bounds`, `:sampling`, `:active_tools`, `:skill_directories`; defaults reproduce M5 exactly; the default policy revision fixed at `"0.2.0"` | Experimental, additive; the revision keeps `0.2` recovery exact |
| `ResourcePacks.read_directories/2` | New; project and user skill directories, `user:<name>` identity | Experimental |
| The companion adapter (M1/M5 rework) | Pure mapping moved to `Loopex.LLM.ReqLLM.Mapping`; behaviour unchanged | Private refactor |
| `loopex_llm_reqllm` application (M1 rework) | ReqLLM removed from the applications it starts; the dependency and embedded code unchanged; the companion already starts it explicitly | Hardening; a host building its own OTP release lists `req_llm: :load` |
| Command line | `ask` and `-p` added; `refuse-all` selectable for `ask`, mapped to `LoopexCli.Policy.RefuseAll`; the launcher exports `ERL_CRASH_DUMP=/dev/null` for `ask` and `-p` only; every existing subcommand unchanged | Experimental |
| Release check (M5 rework) | Two real-provider rows and the `rollback` lane added; a per-row credential mode; `release_version` moved to `0.3.0`; the Ollama precondition | Development tooling |
| Model strings | New `provider:model` grammar | Experimental |
| Coding tools (M2 rework) | Three read-only tools defined; the durable default active set unchanged | Additive; activating them in a durable root narrows rollback as stated |
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
| Backup and restore or downgrade policy | Unchanged from `0.2`; the `0.2` binary opens and resumes every root `0.3` writes, with the two exceptions below |
| Pending interactions across versions | The default policy revision is `"0.2.0"` in both releases, so a pending interaction recovers and can be answered after an upgrade or a rollback |
| Exception: a pending call to an M6-only tool | Recovery re-resolves a pending call against the active tool set (`session_coordinator.ex:6602`); `0.2` answers `{:error, {:unknown_tool, name}}` (`:6844`) and commits it as a failed tool call (`:6625-6626`), and the run continues. The call's effect never ran, so no effect is lost; the model sees the failure |
| Exception: an admitted user skill | Its content is already journaled and replays as recorded, because `0.2`'s core accepts its `user:<name>` identity (`resource_pack.ex:203-216`, `:343-348`); `0.2` cannot admit a new one |
| Proof | The `rollback` lane proves both directions and both exceptions |

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

- **No new application** and no new dependency in any application:
  - the memory store is a module in `loopex_store_local`;
  - the in-process adapter and the shared mapping are in `loopex_llm_reqllm`,
    which already declares `{:req_llm, "~> 1.24.0"}`;
  - the ephemeral API and the start holder are in `loopex_composition`;
  - the command is in `loopex_cli`.
- **Dependency budget:** `mix loopex.deps_budget` changes nowhere. The CLI
  reaches the ephemeral profile only through composition, as the client rules
  require.
- **Escript:** the escript build is unchanged. It still builds and embeds the
  companion, which `ask` uses for a credential-bearing model. `ask` with an
  Ollama model does not need it.
- **Host releases:** a host building its own OTP release with the in-process
  adapter lists `req_llm: :load`, because ReqLLM is no longer started with
  Loopex's applications; the developer guide states it.
- **Version:** `VERSION` moves to `0.3.0`.

**Minimalism budget:**
- The ephemeral API is one module that polls the existing facade and composes
  the companion path exactly as the durable composition does.
- The adapter is one module over the shared mapping, with its cleanup owner,
  caller and tree walk as functions of it.
- The start step is one small holder process with one function.
- The memory store is the promoted 125-line wrapper.
- The command is one parser branch and one renderer mode.
- The three tools are three definitions and three effect clauses.
- The closure tooling is two Mix tasks and three shell scripts.
- Nothing is added beyond that: no configuration framework, no second loop, no
  credential mechanism, no new process type in core.

<a id="technical-plan-limitations"></a>
### Named Limitations

Concept: [Non-goals](M6.md#concept-plan-non-goals).

| # | Limitation | Why it is accepted |
| --- | --- | --- |
| 1 | A credential-free in-process call has no process isolation for request data: ReqLLM's failure paths can put the prompt, context, tool output or reply into a library host's logger or crash dump | The host supplied that data or its own session produced it, and owns its VM's logging; the `ask` command closes these paths itself; the developer guide names the host's obligation |
| 2 | ReqLLM's start settings stay for the VM's life, and a host that wants ReqLLM started earlier must start it itself with `.env` loading off and declare it | ReqLLM reads them only at start; composition refuses rather than inherit an unknown start |
| 3 | A hard VM kill leaves the ephemeral temporary root behind | The root is under the host's temporary directory, mode `0700`, and holds no committed truth (the store is in memory) |
| 4 | A credential-bearing model, in either profile, must name a provider the single `LOOPEX_PROVIDER_API_KEY` serves, and needs the built companion | Per-provider credentials belong to the M7 draft's configuration decision |
| 5 | `ask` offers no deferring policy; a deferred interaction is an API matter | Answering needs a client that holds the question; the app server and an embedding host are those clients |
| 6 | The JSON result carries no usage or model identity | They are not public events; adding them is a protocol decision |
| 7 | An ephemeral session's memory grows with its history, bounded per run but not across runs | Ephemeral sessions are meant to be short; stopping the session releases it |
| 8 | A stop whose cleanup cannot be proved keeps the temporary root for the host to remove | Deleting it while an effect may still use it would be worse; the root is named in the error, and a later stop removes it when only process groups were pending |
| 9 | Rolling a durable root back to `0.2` fails a pending call to an M6-only tool as `unknown_tool`, and `0.2` cannot admit a new user skill | Stated and proved by the `rollback` lane; the call's effect never ran |
| 10 | The in-process cleanup depends on ReqLLM 1.24.0's process structure | The lock pins it, and the cleanup witness fails if an update changes it |
