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
  editing source; and
- recover a durable session after its process died, including one whose last
  effect has an unknown outcome.

`LoopexComposition.Ephemeral` is the small host entrypoint: a memory Store, an
in-process ReqLLM adapter, the local executor and a temporary root. Its
`run/2` answers one prompt; its session API supports follow-up turns and policy
questions while the creating process and VM remain live. It has no artifact
store, durable listing, or recovery path. `LoopexComposition` remains the
durable reference stack: local Store and artifact store, the separate provider
companion, and the local executor. Both define seven tools; the durable default
keeps the original four coding tools active. An embedder that wants different
edges composes the ports and calls `Loopex.start_link/1` directly.

The durable embedded API is a direct facade, not a transport or a sixth
boundary behaviour. The ephemeral composition wraps that same facade rather
than creating another loop. The command, the reference client, the app server,
and the daemon are peers over it: none needs coordinator access, Store access,
an alternate reducer, a policy engine, or event truth of its own. An embedder
may also drive a server from another language over
[the session protocol](app-server-protocol.md#concept).

Seven constraints shape every embedding:

- **The host names authority.** A runtime with any tool active refuses to start
  without a policy module, and a policy needs a stable identity so a question it
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
| `:active_tools` | Which declared tools a session offers, by `tool_id` or `{tool_id, tool_version}`; all of them when omitted. |
| `:policy` | The `Loopex.Policy` module. Required whenever a tool is active: its absence returns `{:error, :host_policy_required}`. |
| `:policy_identity` | `%{"id" => binary, "revision" => binary}`, each 1 to 256 bytes. Required whenever `:policy` is named. |

Optional options:

| Option | Default and meaning |
| --- | --- |
| `:bounds` | `%{max_turns: 16, token_budget: 1_000_000, deadline_ms: 600_000}`; supplied keys override. |
| `:sampling` | `%{"max_tokens" => 4_096}`. |
| `:cleanup_grace_ms` | `Loopex.Executor.default_cleanup_grace_ms/0`, `5_000`; the committed cleanup period every job and terminal carries. |
| `:progress_to` | A pid receiving `{:loopex_progress, item}`, or `{:session, pid}` receiving `{:loopex_progress, session_id, item}` so a host serving many sessions can route each item. |
| `:diagnostics_to` | A pid receiving `{:loopex_diagnostic, item}`. |
| `:attachment_capacity` | `64` queued events per attachment, at most `65_536`. |
| `:artifact_store` | `%{module:, handle:}` for bounded transfers; absent means the transfer family is refused. |
| `:resource_manifest` | A verified skill snapshot; see [resource snapshots](#technical-embedding-resources). |
| `:project_manifest`, `:project_decision` | The root `AGENTS.md` resource and its trust decision; see [project resources](agent-loop-and-tools.md#technical-loop-project-resources). |
| `:diagnostics_ceiling` | A narrower diagnostics admission ceiling than the default. |

The error for a missing policy identity, an invalid policy identity, and every
other malformed option is `{:error, :invalid_runtime_options}`; only a missing
policy and an invalid context budget are reported by their own names. A host
that explicitly supplies a malformed bound is refused at start rather than given
the default. The inherited single-tool form (`:tool` with `:grant_decision`
`{:host_policy, :allow}`) is folded into the same tool set, so there is exactly
one way a tool reaches a model.

The root supervisor is unnamed; the runtime reference holds its pid and an
unforgeable runtime-local token, so two runtimes in one VM hold independent tool
sets, sessions, and trace sessions. `start_link/1` returns only once the event
dispatcher can serve, so a resume issued at once is not refused as unavailable.

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

| Group | Functions |
| --- | --- |
| Runtime | `start_link/1`, `stop/1`, `version/0` |
| Sessions | `create_session/3`, `resume_session/3`, `session_status/2` |
| Session directory | `state_root/0` (reads `LOOPEX_HOME`), `runtime_placement_id/1`, `track_session/3`, `list_sessions/1`, `resume_known_session/4` |
| Attachment | `attach/2`, `attach/3`, `command/2`, `next_event/1`, `snapshot/1`, `attachment_status/1`, `progress/2`, `diagnostic/2` |
| Project skills | `resource_catalog/2`, `read_resource/3` |
| Artifacts | `open_artifact_transfer/2`, `read_artifact_chunk/3`, `close_artifact_transfer/2` |
| Diagnostics | `trace/1`, `trace/2`, `trace_status/1`, `trace_stop/1` |
| Recovery | `reconciliation_query/1`, `reconcile/2`, `prepare_resume_session/3`, `prepare_resume_known_session/4`, `activate_resume/1`, `abandon_resume/1`, `transfer_resume/2`, `transfer_resume/3` |

`create_session/3` and `resume_session/3` require a `:command_id`; an exact
re-presentation returns the retained result, and changed content under the same
identity conflicts. `command/2` accepts maps with `:type` and `:command_id`:
`:prompt`, `:steer`, and `:follow_up` carry binary `:content`; `:abort` carries
nothing else; `:interaction_answer`, `:admit_resources`, and `:activate_skill`
are described below. `{:accepted, command_id}` means the command committed
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

<a id="technical-embedding-ephemeral"></a>
### Ephemeral Composition

`LoopexComposition.Ephemeral.run/2` composes, runs one prompt and cleans up in
one call. `start_session/1` returns an opaque handle for successive `ask/3`
calls; `answer/3` submits an offered choice for a pending policy interaction,
`last_result/1` and `history/1` read bounded observations, and
`stop_session/1` ends the owned session. Pass the handle back; do not inspect
its internals. The process that created it owns its lifetime even if another
process borrows the handle. This API uses the same kernel and policy port as the
durable facade, but stores session truth only in memory. VM loss ends it, with
no resume or migration to the durable profile.

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
Every model admits every preset. `:skills` accepts at most four named project
or user skill directories. `:cwd` defaults to the current working directory;
`:max_steps`, `:deadline_ms`, `:max_tokens`, `:context_token_budget`, `:timeout`
and `:base_url` set the remaining per-session choices. Only `:timeout` may be
overridden on an individual `ask/3`.

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
| `:sampling` | Optional exact `%{"max_tokens" => n}` with `n` from 1 to 1,000,000. |
| `:active_tools` | Optional unique list of declared tool IDs, from the four coding tools and `loopex.grep`, `loopex.find`, `loopex.ls`. Omission keeps the coding four active. |
| `:context_token_budget` | Defaults to `8_192` estimated tokens; an explicit valid value is forwarded unchanged. |
| `:cleanup_grace_ms`, `:process_probe` | Forwarded to the session and executor together, so a run's ending reports the period its cleanup ran under. |
| `:artifact_transfers` | `false` by default. `true` starts a transfer owner and hands the same artifact store to the runtime; absent, the runtime refuses the transfer family. |
| `:recover_stale_writer` | `false` by default; see [recovery](#technical-embedding-recovery). |
| `:resource_manifest`, `:project_manifest`, `:project_decision`, `:progress_to`, `:diagnostics_to` | Passed to the runtime unchanged. |
| `:credential_plane` | A shared credential plane; see below. |

**The provider credential is consumed once.** A composition started without a
`:credential_plane` reads `LOOPEX_PROVIDER_API_KEY`, deletes it from the VM
environment, and places it in a custody process beside a routing registry; the
model edge receives only an opaque `:credential_token` and the
`:credential_registry` handle. A second composition in the same VM finds no
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
stage through `model_request_committed_resources_v1`. The reducer reconstructs
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
   an ordinary durable command keyed by `(session_id, command_id)`. Admission
   means the answer committed, never that the effect is allowed. An answer for a
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
   the journal, and the first committed one wins.

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
and the witnesses are in `apps/loopex/test/interaction_lifecycle_test.exs`.

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
identity and calls `Loopex.resume_session/3` (or `resume_known_session/4`, which
also enforces that the runtime carries the placement identity that created the
session). The new coordinator resolves the exact prior transaction, reads the
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
`prepare_resume_session/3` and `prepare_resume_known_session/4` return either a
replayed result or an opaque one-use activation capability while recovered work
stays paused. The coordinator monitors the preparer, and preparer loss abandons
unspent authority. Only the current holder may activate, abandon, or transfer
the capability; `activate_resume/1` and `abandon_resume/1` wait for the
coordinator's answer, because a caller that stopped waiting cannot withdraw a
request the owner already received.

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
