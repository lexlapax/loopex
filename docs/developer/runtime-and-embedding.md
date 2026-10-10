# Runtime and Embedding

<a id="concept"></a>
## Concept

An embedding host runs Loopex inside its own Elixir application. It can use an
ephemeral session for an answer or conversation held only in its VM, or a
durable session that survives process loss and can be resumed. Both profiles
run the same kernel: the host supplies authority and concrete edges, and the
runtime owns loop ordering and session truth for the profile's declared
lifetime. This page is the reference for that embedding contract. The turn
machine itself is in [Agent loop and tools](agent-loop-and-tools.md#concept),
and the applications and ports behind it are in the
[architecture pair](architecture.md#concept).

What an embedder can do through the facade or a profile entrypoint:

- start and stop any number of independent runtimes in one VM, each named only
  by the opaque reference it returns;
- use an opaque ephemeral handle for a multi-turn session, with no state root
  or recovery claim;
- create, resume, and find durable sessions under a state root, and attach any
  number of callers at an exact durable cursor;
- admit prompts, steers, follow-ups, and aborts, and consume committed events
  and transient progress;
- let its host policy ask the operator a question instead of deciding, retaining
  it across restarts in the durable profile or while the ephemeral session lives;
- admit project or user skills from an immutable snapshot and select what a run
  sees;
- read a durable artifact back in bounded, verified chunks;
- observe the runtime with a trace session and telemetry spans, without
  editing source, including opt-in startup tracing for an ephemeral session; and
- recover a durable session after its process died, including one whose last
  effect has an unknown outcome.

`LoopexComposition.Ephemeral` is the small host entrypoint: a memory Store, an
in-process ReqLLM adapter, the local executor and a temporary root. Its
`run/2` answers one prompt; its session API supports follow-up turns and policy
questions while the creating process and VM remain live. It has no artifact
store, durable listing, or recovery path. `LoopexComposition` remains the
durable reference stack: local Store and artifact store, the separate provider
companion, and the local executor. The durable stack defines seven tools and
keeps the original four coding tools active. Ephemeral creation retains and
registers exactly its selected profile, plus the question tool when enabled.
An embedder that wants different
edges composes the ports and calls `Loopex.start_link/1` directly.

An ephemeral host can supply exact instructions, reasoning and a system ceiling
at startup. Preparation validates the complete settings before creating owned
resources; later prompts use that captured configuration. Omission captures the
reference host's default instructions and workspace facts. Instruction content
never changes tool or policy authority. A selection whose instructions and tools
exceed its ceiling refuses; the host may explicitly select shorter instructions
or a larger permitted ceiling.

A direct runtime may also receive a policy with explicit private callback state.
The host controls that state and its lifetime; it does not become a durable
policy answer, an authority grant or session data. Existing policy modules keep
their original callback.

A host may prepare and capture a session's complete initial settings before
creation, then submit that exact genesis through the public creation facade.
Creation retains those settings even if files or defaults change afterward;
repeating the same command cannot create another session with changed settings.

The durable embedded API is a direct facade, not a transport or a sixth
boundary behaviour. The ephemeral composition wraps that same facade rather
than creating another loop. The command, the reference client, the app server,
and the daemon are peers over it: none needs coordinator access, Store access,
an alternate reducer, a policy engine, or event truth of its own. An embedder
may also drive a server from another language over
[the session protocol](app-server-protocol.md#concept).

Seven constraints shape every embedding:

- **The host names authority.** A runtime with any tool active refuses to start
  without a host policy, and a policy needs a stable identity so a question it
  asked can be resumed only by the same policy.
- **The host chooses context.** A direct runtime requires an explicit context
  token budget; nothing in core defaults it.
- **The durable policy identity is explicit across releases.** The reference
  composition keeps its default policy revision at `"0.2.0"` for rollback;
  a host whose policy behavior changes supplies its own revision.
- **The profiles have different trust and lifetime bounds.** Ephemeral hosted
  calls resolve their selected provider key in the host VM, where trusted code,
  tools and host-installed handlers may observe or copy it. Cleanup uncertainty
  seals only that session. The durable profile retains its separate-process
  credential and persistent-state contracts.
- **The library host owns its release and observers.** Its OTP release loads
  `:req_llm`, `:req`, and `:finch` for the ephemeral path; `start_session/1`
  starts ReqLLM during preflight, before session creation. The host owns
  logger configuration, crash dumps, and telemetry handlers that can see
  request data or the selected key.
- **Catalog loading remains host-owned.** A host-selected cold model catalog can
  use ordinary Req transport and ambient GitHub credentials, and retain shared
  cache and metadata outside the call-owned model pool. Its load lock spends the
  model deadline. The default compiled catalog needs no fetch.
- **Nothing is stable.** Every surface on this page may change without notice;
  pin an exact revision and read
  [Compatibility surfaces](compatibility-surfaces.md#concept).

Technical depth: [Start options](#technical-embedding-options),
[the embedded API](#technical-embedding-api),
[the ephemeral composition](#technical-embedding-ephemeral),
[the reference composition](#technical-embedding-composition),
[resource snapshots](#technical-embedding-resources),
[durable interactions](#technical-embedding-interactions),
[bounded artifact transfers](#technical-embedding-transfers), and
[recovery](#technical-embedding-recovery).

Diagnostics are covered by the [observability pair](observability.md#concept),
and the levels and events an operator turns on are in the
[operator observability runbook](../operator/observability.md#concept).
Operator workflow and failure handling: [Runtime operations](../operator/runtime.md#concept).
Running a coding session: [Coding sessions](../operator/coding-sessions.md#concept).

<a id="technical-depth"></a>
## Technical depth

The public facade is `Loopex` in `apps/loopex/lib/loopex.ex`; every operation
delegates to `Loopex.Runtime` or to the runtime embedded in an opaque
`Loopex.Attachment`. No application callback creates a default instance, and no
application environment, registered name, or persistent term identifies one.

<a id="technical-embedding-options"></a>
### Start Options

`Loopex.start_link/1` validates every option before any child starts and returns
`{:ok, runtime}` or an error. Three options are always required:

| Option | Shape |
| --- | --- |
| `:runtime_id` | Placement identity, a binary of 1 to 256 bytes. `Loopex.runtime_placement_id/1` generates and persists one per state root. |
| `:store` | A `Loopex.Store` handle from `Loopex.Store.new(module, reference)`. |
| `:context_token_budget` | Required; a positive integer up to `2^64 - 1`. Omission and an invalid value both return `{:error, :invalid_context_token_budget}`. |

A working loop supplies the model, the executor, the tools, and the authority
together; omitting all four leaves a runtime that can create, attach, and
recover sessions but runs no turns, and supplying only some is invalid:

| Option | Shape |
| --- | --- |
| `:model` | `%{module: module, model: binary, options: keyword}` naming a `Loopex.Model` implementation. |
| `:executor` | `%{module:, reference:, identity:, epoch:, fencing_token:, workspace_ref:, workspace_lease:}` naming a `Loopex.Executor` implementation and its placement. |
| `:tools` | A list of tool definitions (`LoopexProtocol.ToolDefinition`), the only path by which a reserved `loopex.` identifier reaches the registry. |
| `:active_tools` | Runtime startup selection among declared tools, by `tool_id` or `{tool_id, tool_version}`; all declared tools when omitted. Each session offers the immutable tool selection in its captured defaults or explicit genesis. |
| `:policy` | A `Loopex.Policy` module, or exactly `%{module: adapter, context: private_context}` selecting its optional `decide/2`. Required whenever a tool is active: its absence returns `{:error, :host_policy_required}`. |
| `:policy_identity` | `%{"id" => binary, "revision" => binary}`, each 1 to 256 bytes. Required whenever `:policy` is named. |

Bare policies always use `decide/1`. Explicit contextual references require an
available `decide/2` before runtime startup; missing callbacks and malformed
contextual references return `host_policy_required`. They never fall back to
`decide/1`. The callback context is opaque private host implementation data,
distinct from the bounded decision context a policy returns. Core forwards it
unchanged, retains none in journals/events and names only the module in policy
telemetry. The same allow/deny/defer validation, callback timeout, owner
cancellation and explicit durable policy identity apply to both forms. Hosts
must change their policy revision when a context change changes policy behavior.
This additive Policy-port extension was selected by the maintainer on 2026-10-02.

Optional options:

| Option | Default and meaning |
| --- | --- |
| `:bounds` | `%{max_turns: 16, token_budget: 1_000_000, deadline_ms: 600_000}`; supplied keys override. |
| `:maintenance_model` | `nil`, or the closed resolved `model`, `reasoning`, `model_capabilities`, `provider_mapping` map under ADR 0043. It is independent of the ordinary model. |
| `:maintenance_instructions` | `nil`, or exactly `%{"version" => version, "body" => body}` with version up to 64 bytes and nonempty UTF-8 body up to 2,048 bytes. Startup captures its exact rendering and digest. |
| `:cleanup_grace_ms` | `Loopex.Executor.default_cleanup_grace_ms/0`, `5_000`; the committed cleanup period every job and terminal carries. |
| `:session_creation_defaults` | `nil`, or the host's closed captured v3 template with exactly the string keys `initial_configuration`, `tool_selection`, `policy_defer_mode` and `runtime_configuration`. Startup validates the complete settings, selected model and exact registered tool generations before children start. |
| `:progress_to` | A pid receiving `{:loopex_progress, item}`, or `{:session, pid}` receiving `{:loopex_progress, session_id, item}` so a host serving many sessions can route each item. |
| `:diagnostics_to` | A pid receiving `{:loopex_diagnostic, item}`. |
| `:attachment_capacity` | `64` queued events per attachment, at most `65_536`. |
| `:artifact_store` | `%{module:, handle:}` for bounded transfers; absent means the transfer family is refused. |
| `:resource_manifest` | A verified skill snapshot; see [resource snapshots](#technical-embedding-resources). |
| `:project_manifest`, `:project_decision` | The root `AGENTS.md` resource and its trust decision; see [project resources](agent-loop-and-tools.md#technical-loop-project-resources). |
| `:diagnostics_ceiling` | A narrower diagnostics admission ceiling than the default. |

Missing or invalid policy identity and other malformed options return
`{:error, :invalid_runtime_options}`. Missing policy, invalid context budget,
invalid maintenance model and invalid maintenance instructions instead return
`host_policy_required`, `invalid_context_token_budget`, `maintenance_model_invalid`
and `maintenance_instructions_invalid`, respectively, inside the error tuple.
A host that explicitly supplies a malformed bound is refused at start rather
than given the default. The inherited single-tool form (`:tool` with `:grant_decision`
`{:host_policy, :allow}`) is folded into the same tool set, so there is exactly
one way a tool reaches a model.

The root supervisor is unnamed; the runtime reference holds its pid and an
unforgeable runtime-local token, so two runtimes in one VM hold independent tool
sets, sessions, and trace sessions. `start_link/1` returns only once the event
dispatcher can serve, so a resume issued at once is not refused as unavailable.

Captured creation defaults belong to one runtime and survive its Control child
restart. They contain no credential references, handles or callbacks and stay
out of `Runtime.configuration/1`. The host resolves model facts and captures
instructions before supplying them; Core performs no catalog or file discovery.
Admission of this template does not write a session or change retained history.

Prompt admission records the run's deadline as a duration, and a queued
follow-up inherits it at promotion. The first staged model request turns that
duration into the absolute instant committed in its canonical bytes; later
turns, executor jobs, timers, and recovery reuse that exact instant. A run lost
before first staging keeps its full duration, while every outage after staging
consumes the committed deadline. The context budget and cleanup period are
likewise committed with the session and run, and a restart never substitutes its
current defaults for the retained values.

<a id="technical-embedding-api"></a>
### Embedded API

The host-facing sequence uses the public facade only:

```elixir
defmodule MyHost.RunEvents do
  def until_finished(attachment, backoff \\ 10) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} -> {:ok, event}
      {:ok, _event} -> until_finished(attachment, 10)
      {:error, :empty} ->
        Process.sleep(backoff)
        until_finished(attachment, min(backoff * 2, 500))
      other -> other
    end
  end
end

{:ok, runtime} = Loopex.start_link(runtime_options)
{:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create-1")
{:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

{:accepted, "prompt-1"} =
  Loopex.command(attachment, %{type: :prompt, command_id: "prompt-1", content: "Do it"})

{:ok, %{kind: "run.finished"} = event} = MyHost.RunEvents.until_finished(attachment)
:ok = Loopex.stop(runtime)
```

`command/2` acceptance records the prompt, not its completion. The reader
retries an empty queue and returns disconnection or another error instead of
claiming that the run finished.

`command_with_configuration/3` submits an authored configure command and a
separate host-prepared candidate. The host resolves capability metadata and
provider mapping before submission; the facade performs no catalog or credential
effects. The serial session owner validates and atomically admits the candidate.
A duplicate returns its original disposition even if the candidate has changed.

`command_disposition/2` observes an earlier command's admission without submitting
it again or dispatching work. It distinguishes committed admission or refusal,
conclusively not committed, and pending `commit_unknown`. Missing facts or owner
replacement cannot prove absence. Admission does not prove that the command's
work has completed.

| Group | Functions |
| --- | --- |
| Runtime | `start_link/1`, `stop/1`, `version/0` |
| Sessions | `create_session/3`, `resume_session/3`, `session_status/2` |
| Creation evidence | `lookup_create_result/4`, `creation_provenance/2` |
| State root and placement | `state_root/0` (reads `LOOPEX_HOME`), `runtime_placement_id/1`; the session catalogue is the daemon index, which hosts write (ADR 0070) |
| Attachment | `attach/2`, `attach/3`, `command/2`, `command_with_configuration/3`, `command_disposition/2`, `next_event/1`, `snapshot/1`, `attachment_status/1`, `progress/2`, `diagnostic/2` |
| Project skills | `resource_catalog/2`, `read_resource/3` |
| Artifacts | `open_artifact_transfer/2`, `read_artifact_chunk/3`, `close_artifact_transfer/2` |
| Diagnostics | `trace/1`, `trace/2`, `trace_status/1`, `trace_stop/1` |
| Recovery | `reconciliation_query/1`, `reconcile/2`, `prepare_resume_session/3`, `prepared_session_configuration/1`, `prepared_session_startup/1`, `activate_resume/1`, `abandon_resume/1`, `transfer_resume/2`, `transfer_resume/3` |

`lookup_create_result/4` takes the runtime, command ID, original session
options and complete retained genesis. It compares the exact canonical Store
binding without activating a coordinator or resolving current defaults,
catalogs, tools or credentials. Its observations are `{:historical, session_id}`,
`absent`, `conflict`, `store_unavailable` or `unexpected`, wrapped in `{:ok, ...}`;
runtime loss returns `{:error, :runtime_unavailable}`.

`creation_provenance/2` reads a closed command, session or runtime-page selector.
A page contains at most sixteen creating-command projections and retains its
first high-water ordinal; only a nil next cursor proves complete coverage.
These public reads grant no mutation authority and add no Store callback.
They were explicitly approved by the maintainer on 2026-10-02.

`create_session/3` and `resume_session/3` require a `:command_id`; an exact
re-presentation returns the retained result, and changed content under the same
identity conflicts. `create_session/3` optionally accepts `genesis: payload`,
where payload is a complete normalized current v3 genesis prepared by
`Loopex.Runtime.SessionGenesis.resolve/2` or validated by `normalize/1`.
Its normalized `options` must equal the submitted session options. The exact
payload supplies the captured settings without re-expanding runtime defaults;
its digest joins the original options in the command identity. A present nil
or malformed or superseded genesis refuses before a create mutation. Omitting
the option combines submitted options with the runtime's captured
`session_creation_defaults`. An unconfigured runtime refuses implicit creation;
Core manufactures no instructions or model facts. Explicit exact genesis
remains available without runtime defaults. This follows the
[centralized configuration decision](agent-context-map.md#disposition-m7-runtime-creation-defaults-2026-10-04).
`command/2` accepts maps with `:type` and `:command_id`:
`:prompt`, `:steer`, and `:follow_up` carry binary `:content`; `:abort` carries
nothing else; `:interaction_answer`, `:admit_resources`, and `:activate_skill`
are described below. `:configure` carries the closed `:changes` map;
`:compact` carries the exact `:bounds` map described below.
`{:accepted, command_id}` means the command committed
durably, not that the run has done anything; an abort's acceptance is an
admission, and the run's ending arrives later as `run.finished`.

`next_event/1` returns `{:ok, event}`, `{:error, :empty}` when nothing is
queued, or `{:disconnected, last_sequence}` when the attachment's queue
overflowed. Empty is transient, so a consumer polls with a backoff, as the
daemon's attachment pump does; a disconnected consumer reattaches with
`after_event_sequence: last_sequence` and misses nothing. An event is a map with
`kind` (for example `"run.finished"`), `event_id`, and the Store-stamped
`event_sequence`; the kinds are listed in
[the architecture technical depth](architecture-technical.md#technical-arch-session-owner).

`attach/3` without `:after_event_sequence` anchors at the current outbox tail.
`snapshot/1` returns the attachment's exact durable anchor, taken by a scan that
stops at the acknowledged position rather than the durable tail, so the anchor
never derives run state from a row delivery is still withholding. Delivery is
fenced the same way: a row whose owner still holds an unresolved transaction is
withheld until re-presentation settles it; the fence delays a read and never
reorders or drops one. `attachment_status/1`, `progress/2`, and `diagnostic/2`
are transient observations. None of those grants authority or substitutes for
Store history.

<a id="technical-embedding-configure-compaction"></a>
### Configure settled sessions and compact context

Concept: [Settled settings and compaction](../operator/coding-sessions.md#operator-sessions-chat-settings).

Submit a nonempty closed update through the same serial command boundary:

```elixir
result = Loopex.command(attachment, %{
  type: :configure,
  command_id: "configure-1",
  changes: %{"reasoning" => "none", "max_tokens" => 1_024}
})
```

`changes` admits exactly the six optional mutable members `model`, `reasoning`,
`instructions`, `max_tokens`, `context_token_budget`, `system_class_tokens`.
At least one is required. Version, metadata, provider mapping, credentials,
maintenance settings, tools and cleanup grace cannot be authored here. The
owner admits a complete validated candidate atomically only while settled;
refusal leaves the committed configuration unchanged.

With a model selected, `command/2` uses its optional
`Loopex.Model.prepare_configuration/5` callback under the owned 60-second
preparation deadline and retained cleanup grace. A missing callback returns
`configuration_not_prepared`. `command_with_configuration/3` supplies the
separate host-prepared candidate instead; that facade performs no catalog or
credential effects. Neither path gives its worker journal or publication
authority.

The command identity retains normalized authored input, including the original
model alias. Captured configuration and its public projection use the resolved
canonical model. Reusing an ID with changed spelling conflicts even if the
alias resolves to the same model. Identical replay uses the retained disposition
without repeating preparation. Observe `command_disposition/2` and resolve an
unknown transaction through the existing retained identity before submitting
new mutations. The complete rules are
[ADR 0050](../adr/0050-host-configuration-preparation-technical.md#technical-alias-identity).

An explicit compact command has exactly these three required bounds:

```elixir
result = Loopex.command(attachment, %{
  type: :compact,
  command_id: "compact-1",
  bounds: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}
})
```

Allowed ranges are 1..4 attempts, 1..60,000 milliseconds and 1..32,768 tokens.
The host must supply both maintenance startup options above; missing settings
refuse compaction, and the ordinary model is never inherited. Episode admission
requires the verified thinking-off mapping. Use the closed resolved model and
instruction forms from
[ADR 0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-depth).

A settled compact command owns its command identity and creates no run.
Automatic preparation belongs to its actual run and spends that run's bounds.
Public checkpoint owners distinguish `%{"kind" => "run", "id" => run_id}`
from `%{"kind" => "compact", "id" => command_id}`. Later failure preserves
already committed useful checkpoints and original effect receipts.

To wait, read native `session_status/2` and consume committed events.
`compact_pending` remains true throughout standalone admission, preparation and
cleanup; an unresolved commitment refuses the status read rather than proving
idle. `active_maintenance` describes an admitted episode and may be nil before
preparation reaches it. The anchored snapshot's `last_compact` and
`context.compaction_finished` event carry durable completion; reference chat
projects that event into its `maintenance.last_compact`. An accepted command,
empty attachment queue or absent activity notice is insufficient evidence.

ADR 0054's native `context.compaction_progress` item is one transient notice
at the positive provider-attempt permit. It has no closing record or percentage,
and no durable outcome authority. The app server and daemon deliver it as
transient progress on the `/3` and `/4` generations; this native API example
activates neither. Remote `session.create` options with a `version` take the
authored creation route under the same creation custody and central
preparation as native authored creation.

<a id="technical-embedding-ephemeral"></a>
### Ephemeral Composition

`LoopexComposition.Ephemeral.run/2` composes, runs one prompt and cleans up in
one call. `start_session/1` returns an opaque handle for successive `ask/3`
calls; `answer/3` submits an offered choice for a pending policy interaction or
a tagged choice, tagged text or decline for a model question,
`last_result/1` and `history/1` read bounded observations, and
`stop_session/1` ends the owned session. Pass the handle back; do not inspect
its internals. The process that created it owns its lifetime even if another
process borrows the handle. This API uses the same kernel and policy port as the
durable facade, but stores session truth only in memory. VM loss ends it, with
no resume or migration to the durable profile.

Model questions require explicit `questions: true` at startup. A reusable
session returns the pending question for its host to answer. A one-shot call
without a responder denies model questions before opening an interaction and
continues with that tool's denial result. Ordinary tools retain the supplied
host's policy decisions.

An ephemeral host may request a trace at session startup. Its private owner
starts diagnostic delivery to stderr and keeps the trace across successive
prompts, until the session stops. The opaque session handle grants no runtime
trace controls. An explicitly requested trace that cannot start refuses and
unwinds startup; cleanup uncertainty is reported through the existing session
cleanup result. [ADR 0049](../adr/0049-explicit-host-configuration.md#concept)
adds this optional startup control to the existing embedding contract.

These snippets assume that `MyHost.ReadOnly` is loaded. The
[runnable embedded example](getting-started-technical.md#technical-getting-started-embedding)
defines the policy module.

```elixir
{:ok, result} =
  LoopexComposition.Ephemeral.run("List the files here.",
    policy: MyHost.ReadOnly,
    model: "ollama:llama3.2",
    tools: :read_only,
    cwd: File.cwd!()
  )

IO.puts(result.text)
```

For a conversation, keep the opaque handle and stop it when finished:

```elixir
{:ok, session} =
  LoopexComposition.Ephemeral.start_session(
    policy: MyHost.ReadOnly,
    model: "ollama:llama3.2",
    tools: :read_only,
    cwd: File.cwd!()
  )

try do
  first = LoopexComposition.Ephemeral.ask(session, "List the files here.")
  second = LoopexComposition.Ephemeral.ask(session, "Which one has the entrypoint?")
  {first, second, LoopexComposition.Ephemeral.history(session)}
after
  :ok = LoopexComposition.Ephemeral.stop_session(session)
end
```

The second `ask/3` is admitted only after the first run ends. If a policy
defers, `ask/3` returns `{:error, {:interaction_pending, question}}`; pass the
question's exact interaction ID and one offered choice ID to `answer/3`.
`answer/3` returns the next pending question or that run's terminal result.
Until the open run ends, a new `ask/3` returns `{:error, :run_open}`. A refused
or stale answer returns `{:error, :invalid_interaction_answer}` and leaves the
question pending.

| Observation | Return shape |
| --- | --- |
| `last_result/1` | Starts at `:none`. A pending question, admitted wait timeout, or ending stores the corresponding `{:error, {:interaction_pending, question}}`, `{:error, {:timeout, partial}}`, or terminal `{:ok, observation}` / `{:error, {:run, outcome, observation}}`. A newly accepted ask or answer clears the prior observation unless its waiter has already timed out; a command cancelled before a facade grant leaves the prior value unchanged. |
| `history/1` | `{:ok, %{entries: entries, truncated: boolean}}`; entries are committed user and assistant messages or tool outcomes in order, keeping at most the newest 256. Message text is capped at 64 KiB with its own `text_truncated` flag. |

Always check `stop_session/1`: `:ok` proves cleanup; an
`{:error, {:cleanup_unproved, details}}` result names the retained root and
pending obligations. The example's match makes an unproved stop visible rather
than treating it as a successful release.

The host must supply `:policy`; neither composition supplies one. `:model`
defaults to `LOOPEX_MODEL` or `"ollama:llama3.2"`. Accepted model prefixes are
`ollama:`, `openai:`, `anthropic:` and `openrouter:`. The selected hosted key is
read from that provider's environment variable immediately before each model
call; local Ollama needs no key. A hosted `:base_url` must be HTTPS. If the host
started ReqLLM itself with `.env` loading disabled, it declares
`req_llm: :host_started`; an undeclared or `.env`-enabled existing instance is
refused. Otherwise composition performs the guarded start. That start refuses
`TIDEWAVE_REPL=true`; composition and model calls refuse `SSLKEYLOGFILE` or
nonempty global Req defaults, and calls refuse a replaced provider module.
Malformed or origin-ambiguous base URLs are refused before dispatch, with a
fixed diagnostic rather than the dependency's raw error. `:tools` is
`:none`, `:coding` (the original four), or `:read_only` (`read`, `grep`, `find`,
`ls`), defaulting to `:coding`.
`:questions` is Boolean and defaults false, preserving the selected ordinary
tool definitions. True appends the exact `loopex.ask` generation; enabling it
with `tools: :none` refuses during option validation. `ask/3` cannot override
this startup selection. The one-shot absence-of-responder path uses a
host-composition adapter through the optional contextual Policy callback,
with the original policy identity and no private context in durable data.
Reusable `start_session/1` does not install that one-shot policy.
Each preset selects its listed tools; model capacity and complete configuration
admission still apply. `:skills` accepts at most four named project
or user skill directories. `:cwd` defaults to the current working directory;
`:max_steps`, `:deadline_ms`, `:max_tokens`, `:context_token_budget`, `:timeout`
and `:base_url` set the remaining per-session choices. Only `:timeout` may be
overridden on an individual `ask/3`.

The current startup grammar also admits `:instructions`, `:reasoning` and
`:system_class_tokens`. Instructions are the closed binary-keyed
`version`/`base`/`environment`/`appendix` map in
[ADR 0042](../adr/0042-host-composed-instructions-technical.md#technical-depth).
Omission captures `loopex.reference.v1` with the selected physical workspace,
platform and tool profile. Reasoning is one of the binaries `"default"`,
`"none"`, `"low"`, `"medium"` or `"high"`; omission selects default. Admission
requires the exact captured model mapping to support that selection. The system
ceiling is a positive uint64 and defaults to 1,000; instruction and model-facing
tool costs must stay strictly below it. It cannot exceed the context ceiling.
A long workspace capture or enabled question tool can exceed the default;
preparation refuses without raising it. These values cannot be changed by
`ask/3` or supplied as arbitrary provider capability/mapping envelopes.

Omitted context capacity derives from the captured model window minus the
selected reply allowance. Unknown windows use 8,192. An explicit positive
`:context_token_budget` remains explicit and must fit the captured window.
Preparation resolves the canonical model identity and retains complete current
v3 genesis, including exact configuration, cleanup grace and immutable tool/name
bindings. The complete genesis obeys the existing 65,536-byte record limit.
Provider route references remain private host startup data. The default capture
is shared with the chat host in `LoopexComposition.SessionInstructions`.

Optional `:trace` is a closed map with binary keys. `"enabled"` defaults to
false; `"level"` is `"calls"`, `"returns"` or `"arguments"`, defaulting to
`"calls"`. `"modules"` accepts compiled trusted module names or the
`"Loopex.*"` and `"LoopexProtocol.*"` selectors. The optional positive
`"max_entry_bytes"`, `"max_entries_per_second"` and `"max_queue_entries"`
limits can lower the existing ceilings of 4,096, 2,000 and 8,192 respectively.
Validation applies even when disabled. Unknown keys, explicit nil, arbitrary
sinks, callbacks and runtime references return `{:error, {:invalid_option,
:trace}}` before startup effects. For example:

```elixir
{:ok, session} =
  LoopexComposition.Ephemeral.start_session(
    policy: MyHost.ReadOnly,
    model: "ollama:llama3.2",
    tools: :read_only,
    cwd: File.cwd!(),
    trace: %{
      "enabled" => true,
      "level" => "calls",
      "modules" => ["Loopex.Runtime.Control"],
      "max_entry_bytes" => 1_024
    }
  )

:ok = LoopexComposition.Ephemeral.stop_session(session)
```

The owner registers the diagnostic drain and its private writer supervisor
before connecting the runtime sink, then activates tracing after capability
binding and before dispatch. Diagnostic output is independent of returned
model results. Its pending output queue holds at most 256 entries plus one
active writer; observed mailbox growth remains a separate best-effort measure.
Stop seals delivery, accounts discarded and unconfirmed writes, joins the
captured writer and supervisor, and requires every registered process to end
before acknowledging cleanup. A lost diagnostic certificate remains unproved
on a later stop attempt. The session's existing cleanup deadline governs this
work. [ADR 0049's trace mechanics](../adr/0049-explicit-host-configuration-technical.md#technical-depth)
state the selection, delivery and cleanup rules.

A completed run returns `{:ok, observation}` with bounded text, tool history,
profile and skill-shadow information. Failed, bounded, unknown and cancelled
runs return `{:error, {:run, outcome, observation}}`. A deferring policy returns
a pending interaction from `ask/3`; `answer/3` takes its exact interaction and
choice IDs. `run/2` cannot answer one and returns
`{:error, :interaction_requires_session}` after cleanup. A timed-out wait has
a bounded partial observation; the owner continues draining the admitted run.
`stop_session/1` returns `:ok` only after its cleanup proof. If proof is
unavailable, `{:error, {:cleanup_unproved, details}}` names the retained root
and pending obligations. The session is not silently reported as closed.
Before startup knows any root path, an unproved pre-claim child instead returns
`root: nil`, unknown ownership, only `[:session_subtree]` pending, and no
ending. That session is sealed; the child cannot claim a directory without
the owner's grant, and the missing path grants no cleanup or deletion authority.

This profile is not a credential sandbox. Hosted keys, HTTP/TLS state, crash
reports and host-installed telemetry or logger handlers can be observed by
trusted code in the VM; authorized tools can read ambient variables and return
their values through ordinary tool-result planes. Loopex does not inject a
selected key into its own records or diagnostics and rejects its exact value
from provider-controlled reply fields. A call-owned HTTP/1 pool and caller are
proved gone before a result or successful cleanup acknowledgement; a checked-
out socket and TLS controller may drain afterward without a result route. A
host's OTP release must list `:req_llm`, `:req`, and `:finch` as `:load` because
the library dependencies use `runtime: false`. The guarded `start_session/1`
preflight starts ReqLLM before session creation. The host controls its logger,
crash dumps, and telemetry handlers, including any copies of request data and
credentials they retain. A
host-selected cold catalog source is a separate dependency path: it may use
ordinary Req and `GH_TOKEN` or `GITHUB_TOKEN`, retain shared cache and metadata
after call cleanup, and spend the model deadline waiting on its shared load
lock. The default compiled catalog needs no network fetch. A
host that needs separate-process credential custody or recovery uses the
durable profile. [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept)
states the boundary in full.

<a id="technical-embedding-question-responder"></a>
### Respond to questions in a one-shot call

Concept: [Ephemeral operation](../operator/runtime.md#operator-runtime-available).

Only `Ephemeral.run/2` accepts `question_responder`. Enable questions and supply
a host callback for the bounded pending DTO. This example uses the read-only
policy defined in the runnable embedded example above:

```elixir
responder = fn
  %{"kind" => "text"} -> {:text, "Limit the review to the parser."}
  %{"kind" => "choice", "choices" => [%{"id" => id} | _]} -> {:choice, id}
  _question -> :decline
end

result = LoopexComposition.Ephemeral.run("Ask which review scope to use.",
  policy: MyHost.ReadOnly,
  model: "ollama:llama3.2",
  tools: :read_only,
  questions: true,
  question_responder: responder,
  max_steps: 4,
  deadline_ms: 60_000,
  max_tokens: 1_024,
  context_token_budget: 8_192,
  system_class_tokens: 8_000,
  timeout: 65_000,
  cwd: File.cwd!()
)
```

Return exactly `{:text, text}`, `{:choice, offered_id}` or `:decline`.
The callback receives the interaction ID, prompt, kind, choices and absolute
expiry, with no provider credential. It stays host-local and grants no later
tool authority. One supervised responder worker at a time answers through the
same serial `answer/3` admission. The caller captures one wait deadline across
successive questions.

Invalid replies or callback exceptions initiate abort and yield
`responder_failed` only after worker and session cleanup are proved. Cleanup
uncertainty takes precedence. Expiry and run bounds keep their committed
outcome. A callback can be terminated mid-effect; its host effects have no
rollback. Do not recursively create another call or session in it.

`start_session/1` rejects the responder option; reusable sessions use
`answer/3` themselves. `ask/3` cannot enable it per call. Supplying a responder
with questions disabled refuses. Without a responder, the existing one-shot
question denial described above still applies. See
[ADR 0045](../adr/0045-model-originated-questions-technical.md#technical-depth).

<a id="technical-embedding-composition"></a>
### Durable Reference Composition

`LoopexComposition.start/1` starts the applications an escript does not start
for it, opens the durable Store and the artifact store under the caller's state
root, opens a workspace lease and the local executor, and returns a runtime
with seven defined tools (the original four active by default) and the
companion ReqLLM model adapter:

```elixir
{:ok, runtime} =
  LoopexComposition.start(
    runtime_id: runtime_id,
    state_root: state_root,
    workspace: workspace_path,
    policy: MyHost.Policy,
    provider_launch: provider_launch,
    progress_to: self()
  )
```

| Option | Meaning |
| --- | --- |
| `:runtime_id`, `:state_root`, `:workspace` | Required non-empty binaries, resolved by the caller and never discovered here. |
| `:policy` | Required; absence returns `{:error, :host_policy_required}`. The composition ships no policy of its own, so a permissive default can never be inherited by an embedder. |
| `:policy_identity` | Defaults to `%{"id" => inspect(policy), "revision" => "0.2.0"}`; an embedder whose policy behavior changes names its own revision. |
| `:provider_launch` | The provider companion's launch configuration, a keyword list read from the non-secret `.launch` file that `mix loopex.provider.build` writes. No companion is discovered. |
| `:model` | Optional hosted `provider:model`; default `anthropic:claude-haiku-4-5`. The durable profile refuses `ollama:`. |
| `:bounds` | Optional map of positive unsigned-64-bit `:max_turns`, `:token_budget` and `:deadline_ms`; omitted members keep runtime defaults. |
| `:sampling` | Optional exact `%{"max_tokens" => n}` with `n` from 1 to 1,000,000; it sets the captured initial configuration's `max_tokens`. |
| `:active_tools` | Optional unique list of declared tool IDs, from the four coding tools and `loopex.grep`, `loopex.find`, `loopex.ls`. Omission keeps the coding four active. |
| `:context_token_budget` | Defaults to `8_192` estimated tokens; an explicit valid value is forwarded unchanged. |
| `:cleanup_grace_ms`, `:process_probe` | Forwarded to the session and executor together, so a run's ending reports the period its cleanup ran under. |
| `:artifact_transfers` | `false` by default. `true` hands the artifact store to the runtime for public attachment transfers. The composition always owns one transfer process for executor job ranges; both uses share its capacity. |
| `:recover_stale_writer` | `false` by default; see [recovery](#technical-embedding-recovery). |
| `:resource_manifest`, `:project_manifest`, `:project_decision`, `:progress_to`, `:diagnostics_to` | Passed to the runtime unchanged. |
| `:credential_plane` | A shared credential plane; see below. |

Nonempty durable selections register only the current shipped coding tools:
read, grep, find and ls at 1.1.0, and write, edit and bash at 1.0.0. Each ID
selects that one exact definition. Configured chat retains its selection and
artifact-read capability in v3 genesis. The maintainer's pre-1.0 rule retires
the superseded read/search definitions and the old default-selection shim.
An empty active selection still starts
the job transfer owner, because resumed sessions use their retained tools.

**The provider credential is consumed once.** A composition started without a
`:credential_plane` reads `LOOPEX_PROVIDER_API_KEY`, deletes it from the VM
environment, and places it in a custody process beside a routing registry. The
result is the version-2 single-credential plane of ADR 0070: every hosted
provider that needs a credential routes to that one custody, and the model edge
receives only opaque `:provider_routes` and the `:credential_registry` handle.
Explicit `:provider_bindings` replace those routes. A second composition in the same VM finds no
variable and returns `{:error, :provider_credential_required}` without starting
anything. A host that composes more than one runtime in one lifetime — the
command inspects and then resumes under separate runtimes, and the daemon holds
one for its whole life — calls `LoopexComposition.CredentialHost.open/0` once,
passes `plane/1`'s result as `:credential_plane` to each composition, and
releases it with `release_plane/1` after that runtime stops. No composition
function returns or logs credential bytes, and custody answers any request it
does not recognize with `{:error, :unavailable}`. The standalone
`Loopex.LLM.ReqLLM.complete_prompt/3` takes the same `:credential_token` and
`:credential_registry` and refuses before launch without them.

`LoopexComposition.with_runtime/2` runs one callback with a temporary reference
stack:

```elixir
LoopexComposition.with_runtime(options, fn runtime ->
  Loopex.create_session(runtime, %{}, command_id: "create-1")
end)
```

It returns the callback's result only after `Loopex.stop/1` succeeds and the
directly owned executor, workspace lease, and Store report orderly shutdown. A
normally returning callback receives
`{:error, {:composition_cleanup_unconfirmed, details}}` if cleanup needed force
or could not be confirmed; unexpected runtime death returns
`composition_runtime_stopped` and owner failure `composition_owner_failed`.
Exceptions, throws, and exits are re-raised after cleanup, and caller loss also
starts cleanup. If shutdown stays unconfirmed after the error is returned, the
private owner keeps monitoring the remaining processes until they stop. The
shipped app-server host, `Loopex.AppServer.Host.serve/0`, is a complete
example: it reads its launch inputs, then serves one connection inside
`with_runtime/2`.

`LoopexComposition.start_edges/2` starts the same edges in the caller's own
process for a long-lived host that owns their links and stop order; the daemon
uses it. `LoopexComposition.artifacts/1` returns the artifact-store handle on its
own, because an artifact outlives the run that produced it and an operator
retrieving one later needs no runtime.

The durable composition names `Loopex.Store.Local`, `Loopex.LLM.ReqLLM`,
`Loopex.Executor.Local`, and `Loopex.Store.Local.Artifacts` in this one place,
which is what makes the dependency direction checkable, and it reads nothing
from application environment.

<a id="technical-embedding-resources"></a>
### Resource Snapshot and Commands

Concept: [Runtime and embedding](#concept).

The reference host's `LoopexComposition.ResourcePacks` owns discovery, pinned
Git acquisition, containment, and retained provenance. `discover/2` walks only
`.agents/skills/<name>/SKILL.md` and bounded files inside each pack. `add/3`
requires an exact commit, a selected directory, and explicit acquisition
authority; installation does not admit content to a session. `retain/2` and
`load/2` keep the exact snapshot under its manifest digest in the state root.

For caller-named directories, use
`LoopexComposition.ResourcePacks.read_directories(paths, workspace: dir)`.
It accepts up to four paths and returns
`{:ok, %{manifest: manifest, shadowed_skills: names}}`. A workspace-local
`.agents/skills/<name>` directory is `project:<name>`; a directory outside
the workspace is `user:<name>`. A project skill wins a shared name, and
`shadowed_skills` names the omitted user source IDs. Other workspace paths
refuse. The helper constructs a manifest; it does not itself admit content to
a session. The durable host passes `manifest` as `:resource_manifest` and
uses the session commands below. The ephemeral composition performs this
admission from its `:skills` option.

Pass the verified manifest as `resource_manifest:` to the composition or to
`Loopex.start_link/1`. Core validates it once and stores one copy in a protected
unnamed ETS table owned by the runtime supervisor; child options keep the table
reference, not the manifest. One snapshot binds one workspace for that
runtime's lifetime, and a session for another workspace withholds this resource
class instead of borrowing another session's admission.

The host sends two commands while the session is settled:

```elixir
Loopex.command(attachment, %{
  type: :admit_resources, command_id: id, manifest_digest: digest, decision: decision
})

Loopex.command(attachment, %{
  type: :activate_skill, command_id: id, manifest_digest: digest,
  source_id: source_id, name: name, pack_digest: pack_digest,
  supporting_labels: labels
})
```

Admission binds the manifest digest and the full decision; selection binds the
digest, the skill's identity, and its ordered supporting labels. A run freezes
the resulting selection. Repeated command identities replay the retained
outcome, stateful refusals are retained too, and a fresh admission clears
earlier selections. There is no model-callable selection and no arbitrary-path
resource query.

`Loopex.resource_catalog/2` returns entries only for a matching active
admission. `Loopex.read_resource/3` takes the exact manifest digest, source,
name, and manifested label and returns verified bytes up to 64 KiB. Both are
queries and grant no effect authority. A manifest holds at most 64 packs, 64
files per pack, 1 MiB of content per pack, 64 MiB of content overall, and 8 MiB
of metadata; a run selects at most four skills with eight supporting files each.
These ceilings do not raise the context or Store budgets.

Resource commands are retained as `resource_command_v1`; admitted sessions
stage through configuration-bound `model_request_committed_resources_v2`. The reducer reconstructs
exact staged request bytes without any snapshot. When a fresh process recovers
a session, the command prepares it under a temporary composition without
activating work, reads its admitted manifest digest, abandons the preparation,
and only after confirmed cleanup loads that exact retained snapshot and starts
the final composition with the same trusted provider and executor
configuration. A missing or invalid retained snapshot withholds the resource
class while ordinary recovery continues; current workspace bytes never
substitute for the admitted snapshot. How the model sees skills is in
[progressive skill context](agent-loop-and-tools.md#technical-loop-skills); the
accepted format is
[ADR 0025](../adr/0025-resource-packs-and-skill-admission.md#concept).

<a id="technical-embedding-interactions"></a>
### Durable Interactions

Concept: [Runtime and embedding](#concept).

A host policy may answer a tool decision with `{:defer, request}` — a bounded
question for the operator — instead of a verdict. The runtime commits the
question as durable session state, suspends the tool call, and asks the same
policy again once an answer commits. An embedder that never defers sees nothing
of this.

The question family is exact, and `Loopex.Interaction.bounds/0` returns its
ceilings as data so a host can check a question before offering it:
`kind: :choice`; a non-empty UTF-8 `prompt` of at most 2,048 bytes; one to eight
`choices`, each `%{id:, label:}` with a unique identifier of 1 to 64 bytes and a
non-empty label of at most 256 bytes; `expires_in_ms` between 1 and 600,000; and
an optional `decision_ref` of at most 256 bytes, retained privately and never
projected. A defer outside the family resolves as `policy_unavailable`.

The lifecycle is four transitions, each journaled before anything observable
follows from it:

1. **Request.** A defer commits `interaction_requested_v1` and publishes
   `interaction.requested` in the same transaction. No grant is minted, no
   effect intent commits, and no executor process starts. The record binds the
   original policy request and its digest, the validated question and its
   digest, the policy identity and revision, the creation instant, the
   effective expiry, and the round.
2. **Answer.** `Loopex.command/2` admits
   `%{type: :interaction_answer, command_id:, interaction_id:, choice_id:}` as
   an ordinary durable command keyed by `(session_id, command_id)`, and publishes
   `interaction.answer_admitted`. The question remains visible as answered
   while policy reevaluation is owed. Admission means the answer committed,
   never that the effect is allowed. An answer for a
   question that is not open, a different question, or a choice never offered is
   refused with `interaction_absent`, `interaction_resolved`, or
   `invalid_interaction_answer`, and none of them reopens anything.
3. **Resolution.** The coordinator calls the same host policy again with the
   original request plus one core-created `interaction_response` member carrying
   the interaction identity, the question, and the admitted answer (`%{answer:
   %{choice_id: ...}}`) with its digest. Only an `allow` can lead to a grant, and
   grant binding and effect intent still commit before dispatch. The resolution
   commits `interaction_resolved_v1` and publishes `interaction.resolved` with a
   resolution of `allowed` or `denied`. A denial, malformed output, timeout, or
   failure dispatches nothing.
4. **Expiry, abort, and deadline.** The effective expiry is the earlier of the
   requested duration from the committed creation instant and the run's
   absolute deadline, chosen once before the creating transaction. Expiry
   publishes `interaction.expired` and resolves the call as a denial; an abort
   publishes `interaction.cancelled`. These are competing transitions ordered at
   the journal, and the first committed one wins. A terminal policy event binds
   the original run, numbered turn and tool call, plus the actual admitted
   answer command and selected choice when one exists. Denial, expiry or
   cancellation after answer admission preserves that pair; an unanswered
   terminal has no selected choice and a null answer-command identity.

Another defer after an answer resolves the current question and opens a fresh
one with the next round number. At most one interaction is open per session, and
a tool decision admits at most two answer-then-defer rounds after the first
question — three questions in all — before the next defer fails closed as a
denial.

Restart is the point. A recovered coordinator re-arms the expiry timer only for
a question still pending; an answered question is owed a resumed evaluation
instead. A crash between answer and resolution leaves the run suspended, and
re-running the evaluation is safe because it authorizes nothing until its result
commits. If the runtime's `:policy_identity` differs from the one retained with
the question, the session stays suspended and dispatches nothing rather than let
a different policy, or a different revision of it, decide what a committed
answer meant.

A caller reads the open question from `Loopex.attach/2` and `attach/3`, which
return an `open_interaction` view beside the snapshot, captured at the same
cursor, and from `Loopex.session_status/2`. The view carries the identity,
prompt, choices, expiry, and status, the selected choice only after an answer
was admitted, and never the `decision_ref`. Transport loss changes no
interaction state, which is what lets a new server process present the same
question. The contract is
[ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept),
and its native public correlation amendment is
[ADR 0052](../adr/0052-policy-interaction-public-events-technical.md#technical-depth).
The witnesses are in `apps/loopex/test/interaction_lifecycle_test.exs`.

Model questions have producer `model_tool` and a separate lifecycle. Enabling
`loopex.ask` lets the model offer a bounded text or choice question only after
host policy allows that tool call. Text answers are nonempty UTF-8 up to 8,192
bytes; choice IDs are stable offered values `choice-1` through `choice-8`.
Decline is an explicit response branch. Policy-defer questions remain
choice-only. For the exact pending text interaction read at a committed cursor:

```elixir
result = Loopex.command(attachment, %{
  type: :interaction_answer,
  command_id: "answer-1",
  interaction_id: question["interaction_id"],
  answer: %{"text" => "Keep the existing filename."}
})
```

The other tagged native response maps are `%{"choice_id" => offered_id}` and
`%{"disposition" => "declined"}`. Supply only one response branch, for the
pending producer and kind. Identical replay returns the retained disposition;
conflicting identity reuse, a second independent answer and a late answer
refuse without reopening a question.

A model response commits its terminal interaction, original tool result and
next run action together, releasing the open slot at that same event cursor.
It requires no policy reevaluation, executor intent or executor receipt.
Terminal history preserves the original turn/call and admitted response-command
provenance. The answer never authorizes a later effect. Read
[ADR 0045](../adr/0045-model-originated-questions-technical.md#technical-depth)
for expiry, restart and terminal precedence, and use
[chat answers](../operator/coding-sessions.md#operator-sessions-chat-input)
or the [one-shot responder](#technical-embedding-question-responder) at the
host boundary. These native events do not activate new foreground or daemon
wire generations; their serving remains separate work.

<a id="technical-embedding-transfers"></a>
### Bounded Artifact Transfers

Concept: [Runtime and embedding](#concept).

A caller holding an artifact reference reads the object back through its
attachment in three calls:

```elixir
request = %{object: object, use_locator: reference.use_locator, start: 0}
{:ok, transfer} = Loopex.open_artifact_transfer(attachment, request)
{:ok, chunk} = Loopex.read_artifact_chunk(attachment, transfer.transfer_ref, 8_192)
:ok = Loopex.close_artifact_transfer(attachment, transfer.transfer_ref)
```

The request names an artifact the caller already holds, a non-negative `start`,
and an optional `length`. The store verifies the complete immutable object once
at open, before any chunk exists, and the response carries `total_size`,
`window_start`, `window_length`, the `object_digest`, and an opaque
`transfer_ref` — and no placement. Each chunk carries its `offset`, `bytes`, and
a `chunk_digest` over exactly those bytes, deliberately a different digest from
the object's. Chunks are contiguous from the window's start, never cross it, and
are bounded by the chunk ceiling however much a caller asks for.
`{:ok, :complete}` means the window is exhausted; the transfer stays open until
it is closed or its lifetime ends. Saving an N-byte object reads at most 2N
bytes: one verification and one emission.

`Loopex.ArtifactStore.transfer_limits/0` returns the ceilings as data. They are
safety ceilings, not throughput promises:

| Ceiling | Value |
| --- | --- |
| `object_bytes` | 67,108,864 |
| `open_deadline_ms` | 60,000 |
| `open_work_bytes` | 134,217,728 |
| `chunk_bytes` | 32,768 |
| `read_deadline_ms` | 5,000 |
| `lifetime_ms` | 600,000 |
| `per_attachment` | 2 |
| `per_runtime` | 4 |

A transfer belongs to the attachment that opened it: another attachment gets
`unknown_transfer`, a superseded attachment gets `stale_attachment`, and
replacement, detach, or caller loss releases every transfer the attachment held.
Refusals are distinct and stable — `invalid_window`, `artifact_use_mismatch`,
`unknown_artifact_use`, `artifact_digest_mismatch` for corruption anywhere in
the object, `open_deadline_exhausted` and `open_work_budget_exhausted` for an
open that exceeds its budget before retaining any bytes, `transfer_limit_reached`
for the per-attachment and per-runtime ceilings, and `unknown_transfer` for one
that expired or was closed.

The capability is optional on the port. `Loopex.ArtifactStore.supports_transfer?/1`
asks the composed module, and a runtime composed without an artifact store, or
with an adapter that lacks the three callbacks, answers
`artifact_transfer_unsupported` rather than falling back to an unbounded
`fetch/2`. The contract is
[ADR 0028](../adr/0028-bounded-artifact-retrieval.md#concept), with one known
divergence: the implementation counts concurrent transfers per attachment rather
than per connection and enforces no cumulative per-connection work allowance, as
the [operator transfer page](../operator/app-server.md#operator-app-server-artifacts)
discloses; its remediation is deferred beyond M5. The witnesses
are in `apps/loopex_store_local/test/artifact_transfer_test.exs`.

<a id="technical-embedding-recovery"></a>
### Recovery

These procedures apply only to the durable profile. An ephemeral handle has no
retained Store or resume path after its owner or VM ends.

**Reopening the Store.** The host reopens the local Store with
`recover_stale_writer: true`, which the Store honours only after asking the
operating system whether the writer marker's recorded holder is still alive. The
marker (`loopex_store_writer_v2`) carries the holder's operating-system pid, its
start identity as `/bin/ps` reports it, its BEAM pid, and a nonce. A live holder
is refused as `store_writer_active` whoever asks; a holder that is gone, or whose
start identity no longer matches its pid, is recovered; and a marker the Store
cannot verify — unreadable bytes, a record from an earlier version, or a probe
that failed, printed a diagnostic, or did not answer within five seconds — is
refused as `store_writer_unverifiable`, naming the path and the reason, which is
a human decision. Only the exact "no such process" answer counts as absence. A
Store that cannot record its own identity refuses to open
(`store_writer_identity_unavailable`), because a marker without one could never
be recovered afterwards.

The local Store records the log file's device and inode at start and re-checks
the path while its append handle is held; a log removed or replaced underneath
it answers `{:log_unavailable, :enoent}` or `{:log_unavailable, :replaced}`,
which is commit-ambiguous like any other append failure, terminates the Store,
and leaves the caller to re-present the exact transaction. Recovery accepts
only a complete checksummed prefix: a strictly torn final frame is truncated
away under a digest taken at read time, while a complete-but-invalid frame
refuses to start rather than repairing itself.

**Resuming.** The host starts a replacement runtime with the same placement
identity and calls `Loopex.resume_session/3`; the reference CLI first checks the
session's row in the daemon index against the runtime's placement identity. The
new coordinator resolves the exact prior transaction, reads the
non-authorizing ownership head, and commits a fresh owner succession before
routing commands. A model attempt found open is settled `owner_loss` — charged
the run's remaining allowance and ended `failed` — because a provider call is not
a Loopex-controlled effect that reconciliation can complete safely.

**Reconciling an unknown effect.** An effect whose committed intent lacks a
committed fact remains `effect_dispatched`; recovery never restarts executor
work from that state. The host requests `Loopex.reconciliation_query/1`,
retrieves the retained receipt from its executor authority, builds either
`Loopex.ReferenceClient.Recovery.receipt/2` or `outcome_unknown/1`, and submits
it with `Loopex.reconcile/2`. The query carries eleven members — the query
identity, the current session epoch, the expected executor identity, the current
recovery contract, and the journaled operation, attempt, canonical request
digest, original session and executor epochs, origin executor identity, and
fencing token — and every one must be echoed back unchanged; a difference names
the field. Receipt evidence is then matched field for field against the
journaled job, and a field the answer omits is a mismatch, never a match against
an expected value that happens to be absent. A query opens only where exactly
one item sits at `effect_dispatched`; otherwise the answer is
`:no_effect_recovery_pending`, or `:effect_in_flight` for an effect still
running. Unsolicited evidence is refused.

**Prepared resume.** Recovery that may race an operator interrupt is two-phase.
`prepare_resume_session/3` returns either a
replayed result or an opaque one-use activation capability while recovered work
stays paused. The coordinator monitors the preparer, and preparer loss abandons
unspent authority. Only the current holder may activate, abandon, or transfer
the capability; `activate_resume/1` and `abandon_resume/1` wait for the
coordinator's answer, because a caller that stopped waiting cannot withdraw a
request the owner already received.

Before activation, `prepared_session_configuration/1` lets the current unspent
capability holder read the exact retained configuration, immutable tool selection,
policy-defer mode and cleanup grace. Captured instruction bytes are available to
this trusted host caller; ordinary status still exposes only their version and
digest. Current genesis always retains complete captures. The read changes no
session fact and schedules no work. Transferring the capability revokes the former
holder's access; abandonment, activation, abort and supersession refuse later
reads through the same holder and current-owner checks.

The separate `prepared_session_startup/1` read returns exactly four facts:
`session_options`, `pending_policy_identity`, `admitted_models` and
`admitted_workspace_refs`. Options are the exact normalized genesis options;
Core does not interpret a host workspace binding as authority. Pending policy
identity survives an admitted answer until policy reevaluation resolves the
question. Model-tool questions have no policy binding. The sorted unique model
identities come from admitted pending runs and staged provider work. Workspace
identities come from pending effect intents; completed historical effects add
neither a workspace nor a routing requirement. Current launch defaults supply
none of these facts. Unknown or corrupt required capture returns
`prepared_startup_unavailable`. The whole capture fits the same plain-data
65,536-byte ceiling; an unrepresentable capture returns
`prepared_startup_too_large`, without truncation. The read shares the existing
holder/owner fences and neither spends activation nor mutates or dispatches
work. It exposes no private continuation, credentials or routing handles and
leaves the prepared configuration result unchanged. This separate public read
was approved by the maintainer on 2026-10-02.

Reference chat retains `%{"surface" => "chat", "workspace_binding" =>
%{"revision" => 1, "workspace_ref" => reference}}` in exact genesis options.
`ChatConfiguration.load/3` captures and rechecks the existing canonical-root,
device and inode digest without creating directories. Capability-held resume
compares the selected physical identity against that binding and all retained
pending effect references, abandoning on refusal. An explicit workspace flag
does not adopt an unbound session. Execution/resource placement still requires
the outer host's recheck immediately before activation. Configuration inspection
uses only an equal-width cost marker and never returns or publishes it as an
identity. These current-format checks implement the approved binding and the
maintainer's pre-1.0 compatibility retirement.

Activating a prepared owner is the host's statement that the process which
dispatched the last effect is gone, so the coordinator settles that effect
itself where its executor can say what it retained. It solicits its own query
and asks the optional `Loopex.Executor.retained_receipt/2` callback once, in a
bounded worker: a retained receipt commits the receipt fact and the run
continues; `:absent`, `{:error, :effect_unresolved}`, and
`{:error, :effect_settling}` commit `outcome_unknown`, and the executor root's
quarantine stands until an operator clears it; a missing callback,
`{:error, :effect_in_flight}`, any other error, or a receipt that does not bind
to the journaled job leaves the work pending for the host to reconcile.

`transfer_resume/2` hands the capability to another local holder.
`transfer_resume(activation, holder, {participant, correlation})` also names a
local lifetime participant under
[ADR 0020](../adr/0020-explicit-prepared-handoff.md#concept): the calling holder,
receiving holder, participant, and coordinator must be distinct local processes
and the correlation a fresh local reference. Malformed or aliased roles return
`invalid_resume_handoff`, and a non-local role `non_local_resume_participant`,
before any mutation. The participant's acceptance of the forwarded authorization
is the lifetime linearization; the coordinator records the acknowledged holder
before returning `:ok`, and initial preparer death cannot revoke a handoff whose
participant already accepted it. The full message protocol is documented on
`Loopex.ResumeActivation.transfer/3` and in
[the technical decision](../adr/0020-explicit-prepared-handoff-technical.md#technical-adr-0020-decision).

The command's interrupt handler is the shipped participant.
`LoopexCli.Interrupt.install_prepared(attachment, cleanup_ms, activation)` arms
a guard against the exact signal manager, creates a linked, monitored holder,
and returns `:ok`, a definitive `{:error, reason}`, or `{:unresolved, reason}`.
Installation claims one handler identity atomically; a duplicate returns
`interrupt_already_installed` and leaves the incumbent in place. An unresolved
result keeps recovery fenced and cleanup active, and the command neither
activates nor retries speculatively. Holder or coordinator loss during a
presentation is unresolved rather than proof of failure, and no capability, pid,
reference, or participant value enters durable or printable data.

## Related

- [Agent loop and tools](agent-loop-and-tools.md#concept) — the turn order,
  tools, bounds, streaming, and artifacts behind these calls.
- [Getting started](getting-started.md#concept) — a first embedded host and a
  first protocol client.
- [Developer documentation](README.md).
