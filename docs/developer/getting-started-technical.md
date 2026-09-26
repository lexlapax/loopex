# Getting Started — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Getting started](getting-started.md#concept).

This companion carries the commands and code for both tracks. Every command runs
from the repository root unless it says otherwise, and every example uses a
temporary state root: never point development or test commands at a real
`~/.loopex`.

<a id="technical-getting-started-source"></a>
## Building From Source

Concept: [What you are working with](getting-started.md#concept-getting-started-model).

```bash
git clone https://github.com/lexlapax/loopex.git
cd loopex
mix deps.get
mix compile
```

The supported toolchain pairs are recorded in `.tool-versions`; the floor is
Elixir 1.18.5 on OTP 27.3.4 and the current pair Elixir 1.20.3 on OTP 29.0.5.
[DEVELOPMENT.md](../../DEVELOPMENT.md) shows how to run the floor pair through a
version manager and what to clear when switching. On Linux, export
`LANG=C.UTF-8` and `LC_ALL=C.UTF-8`. The shipped local executor needs
executable `/bin/bash` at run time.

Two further build steps are needed only when a real model provider or the
command is involved:

```bash
# The private provider companion; from a clean Git checkout, once.
(cd apps/loopex_llm_reqllm && MIX_ENV=prod mix loopex.provider.build)

# The `loopex` command, which also builds its companion.
MIX_ENV=prod mix cmd --app loopex_cli mix escript.build
```

The first writes the companion and a non-secret launch file,
`_build/prod/loopex_provider.launch`, that a host passes to the reference
composition. The second writes `apps/loopex_cli/loopex` and its launcher
`apps/loopex_cli/bin/loopex`; run the launcher, as
[Coding sessions](../operator/coding-sessions.md#operator-sessions-running)
explains.

No application is published as a package. The examples below run inside this
umbrella — from `mix run` or `iex -S mix` at the repository root — which is how
the shipped hosts are built.

<a id="technical-getting-started-embedding"></a>
## A First Embedded Host

Concept: [Building on: embed a runtime in an Elixir host](getting-started.md#concept-getting-started-embedding).

**Without a model.** A runtime needs only a placement identity, a Store, and a
context budget. With no model, executor, or tools it creates, attaches to, and
recovers sessions, and records commands, but runs no turns. Save this as
`first.exs` and run `LOOPEX_HOME="$(mktemp -d)" mix run first.exs`:

```elixir
root = System.fetch_env!("LOOPEX_HOME")
{:ok, runtime_id} = Loopex.runtime_placement_id(root)
{:ok, adapter} = Loopex.Store.Local.start_link(path: Path.join(root, "store.log"))
{:ok, store} = Loopex.Store.new(Loopex.Store.Local, adapter)

{:ok, runtime} =
  Loopex.start_link(runtime_id: runtime_id, store: store, context_token_budget: 8_192)

{:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create-1")
{:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
IO.inspect(Loopex.snapshot(attachment))
IO.inspect(Loopex.session_status(runtime, session_id))
:ok = Loopex.stop(runtime)
```

The snapshot is anchored at event sequence `0`; `Loopex.next_event/1` answers
`{:error, :empty}` until something commits.

**With the reference stack.** `LoopexComposition` adds the ReqLLM model adapter,
the local executor, and its four coding tools. It needs a policy (below), the
launch file from the companion build, and `LOOPEX_PROVIDER_API_KEY` in the
environment, which it reads once and removes:

```elixir
{:ok, state_root} = Loopex.state_root()
File.mkdir_p!(state_root)
{:ok, runtime_id} = Loopex.runtime_placement_id(state_root)
{:ok, [provider_launch]} = :file.consult(~c"_build/prod/loopex_provider.launch")

LoopexComposition.with_runtime(
  [
    runtime_id: runtime_id,
    state_root: state_root,
    workspace: File.cwd!(),
    policy: MyHost.Policy,
    policy_identity: %{"id" => "my-host-policy", "revision" => "1"},
    provider_launch: provider_launch,
    progress_to: self()
  ],
  fn runtime ->
    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create-1")
    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    {:accepted, "prompt-1"} =
      Loopex.command(attachment, %{
        type: :prompt,
        command_id: "prompt-1",
        content: "List the files in this directory."
      })

    MyHost.Events.until_finished(attachment)
  end
)
```

`Loopex.state_root/0` reads `LOOPEX_HOME`. Without a credential,
`with_runtime/2` returns `{:error, :provider_credential_required}` and starts
nothing. Committed events are read by polling; `{:error, :empty}` is transient,
so back off and ask again:

```elixir
defmodule MyHost.Events do
  def until_finished(attachment, backoff \\ 10) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        {:ok, event}

      {:ok, event} ->
        IO.inspect(event.kind)
        until_finished(attachment, 10)

      {:error, :empty} ->
        Process.sleep(backoff)
        until_finished(attachment, min(backoff * 2, 500))

      other ->
        other
    end
  end
end
```

The model's streamed text arrives separately, as `{:loopex_progress, item}`
messages to the `:progress_to` process, and is never the durable answer: the
committed `assistant.message_appended` event is. A queue overflow returns
`{:disconnected, last_sequence}`; reattach with
`after_event_sequence: last_sequence`. Every start option, the complete facade,
and recovery are in [Runtime and embedding](runtime-and-embedding.md#technical-depth).
`Loopex.AppServer.Host` in `apps/loopex_app_server/lib/loopex_app_server/host.ex`
is a complete host built this way.

<a id="technical-getting-started-policy"></a>
## A First Policy

Concept: [Building on: write the host policy](getting-started.md#concept-getting-started-policy).

A policy implements one callback, `decide/1`, over a map carrying
`:session_id`, `:run_id`, `:tool_call_id`, `:generation`
(`{tool_id, tool_version, definition_digest}`), `:arguments`, `:effect_class`,
`:idempotency_class`, and `:workspace_lease`:

```elixir
defmodule MyHost.Policy do
  @behaviour Loopex.Policy

  @impl Loopex.Policy
  def decide(%{effect_class: "read_only"}), do: {:allow, nil}
  def decide(_request), do: {:deny, :effect_class_not_permitted}
end
```

An allow carries `nil` or a small context map; a deny carries one of
`Loopex.Policy.reason_categories/0`. To ask the operator instead, return a
defer the first time and decide on the committed answer when the runtime asks
again with an `:interaction_response` member:

```elixir
def decide(%{interaction_response: %{answer: %{choice_id: "allow"}}}), do: {:allow, nil}
def decide(%{interaction_response: _answered}), do: {:deny, :policy_denied}

def decide(_request) do
  {:defer,
   %{
     kind: :choice,
     prompt: "Allow this tool call?",
     choices: [%{id: "allow", label: "Allow"}, %{id: "deny", label: "Deny"}],
     expires_in_ms: 300_000
   }}
end
```

The runtime calls `decide/1` in a supervised task with a 5,000 ms timeout.
Change the `"revision"` of the policy identity whenever what the policy decides
changes, because a pending question is resumed only by the identity that asked
it. The shipped examples are `LoopexCli.Policy.AllowAll`,
`LoopexCli.Policy.ShellAllowlist`, and the app server's `ask` and `allow-all`
policies under `apps/loopex_app_server/lib/loopex_app_server/policy/`. The
complete resolution table is in
[the host policy port](agent-loop-and-tools.md#technical-depth), and the
interaction lifecycle in
[durable interactions](runtime-and-embedding.md#technical-embedding-interactions).

<a id="technical-getting-started-protocol"></a>
## A First Protocol Client

Concept: [Building on: drive sessions over the wire](getting-started.md#concept-getting-started-protocol).

The shipped app server reads its launch inputs from the environment —
`LOOPEX_HOME`, `LOOPEX_WORKSPACE`, `LOOPEX_PROVIDER_LAUNCH`, `LOOPEX_POLICY`
(`ask` or `allow-all`), and `LOOPEX_PROVIDER_API_KEY` — and must run with
`-noinput`:

```bash
MIX_ENV=prod mix compile
ELIXIR_ERL_OPTIONS=-noinput ERL_LIBS=_build/prod/lib elixir -e "Loopex.AppServer.Host.serve()"
```

[App server operations](../operator/app-server.md#operator-app-server-launching)
describes each input. A client then writes one JSON object per line and reads
one per line. Identities are unpadded base64url (`Y3JlYXRlLTE` is `create-1`),
quantities are decimal strings, and the connection's attachment receives the
commands that follow it:

```json
{"method":"initialize","request_id":"c1","generations":["loopex.experimental/1"],"capabilities":[]}
{"method":"session.create","request_id":"c2","command_id":"Y3JlYXRlLTE","session_options":{}}
{"method":"session.attach","request_id":"c3","session_id":"<session_id from the admission>","after_event_sequence":"0"}
{"method":"session.prompt","request_id":"c4","command_id":"cHJvbXB0LTE","content_b64":"ZG8gdGhlIHRhc2s"}
```

The server answers `initialized` with the selected generation, the schema
digest, the methods, and the limits; an `admission` with `status` `accepted`
and the new `session_id`; a `snapshot`; and another `admission`. From then on
`event` records arrive unasked until `run.finished`, with `progress` records
between them. The complete method, record, and error inventories are in
[the protocol technical reference](app-server-protocol-technical.md#technical-depth).

The independent Node client does all of this and more:

```bash
export LOOPEX_WORKFLOW_ENTRY="Loopex.AppServer.Host.serve()"
node clients/node/workflow.mjs "$(command -v elixir)" _build/prod/lib/*/ebin
```

It launches its own server, so run it with `LOOPEX_POLICY=allow-all`, since it
never answers a question; `clients/node/interaction-workflow.mjs` is the one
that answers. [The client's README](../../clients/node/README.md) describes
both, and `clients/node/loopex-client.mjs` is a compact reference for the wire
encodings.

<a id="technical-getting-started-daemon"></a>
## Against a Daemon

Concept: [Building on: drive sessions over the wire](getting-started.md#concept-getting-started-protocol).

The daemon is started by the command and listens on `ROOT/daemon/daemon.sock`
by default:

```bash
LOOPEX_PROVIDER_API_KEY=... apps/loopex_cli/bin/loopex daemon \
  --state-root "$LOOPEX_HOME" --workspace "$PWD" \
  --provider-launch _build/prod/loopex_provider.launch --policy allow-all
```

A client offers `loopex.experimental/2` and must hold the session's controller
lease to change it. Controlled mutations carry the `writer_epoch` the lease
returned:

```json
{"method":"initialize","request_id":"c1","generations":["loopex.experimental/2"],"capabilities":[]}
{"method":"session.attach","request_id":"c2","session_id":"<session>","after_event_sequence":"0"}
{"method":"session.acquire_control","request_id":"c3","session_id":"<session>"}
{"method":"session.prompt","request_id":"c4","command_id":"<identity>","content_b64":"<bytes>","writer_epoch":"<writer_epoch from the result>"}
```

The holder renews by sending `session.acquire_control` again within the 30 s
term, and releases with `session.release_control`. The command's live forms —
`loopex run --daemon SOCKET`, `loopex attach SESSION --daemon SOCKET`, and
`loopex sessions --daemon SOCKET` — are clients of the same socket, and
`clients/node/daemon-takeover.mjs` is an independent one. Running, importing an
older root, and exit statuses are in
[the operator daemon page](../operator/daemon.md#concept); the processes and
bounds behind them are in [the daemon pair](daemon-technical.md#technical-depth).

<a id="technical-getting-started-adapter"></a>
## Adding an Adapter

Concept: [Building on: replace a port](getting-started.md#concept-getting-started-adapter).

1. Create an application under `apps/` whose `mix.exs` declares
   `loopex_role: :edge` and depends in production on `{:loopex, in_umbrella: true}`
   (and `loopex_protocol` if it needs the canonical encoding).
2. Implement the behaviour — `Loopex.Store`, `Loopex.Model`,
   `Loopex.Executor`, or `Loopex.ArtifactStore` — returning only bounded plain
   data: no pids, functions, references, arbitrary terms, atoms from untrusted
   input, or implementation structs.
3. Run the port's conformance suite against it.
4. Wire it in a composition; core never names it.
5. Run `mix loopex.deps_budget`. The dependency inventory is fixed, so a new
   application or external package is also a change to that check's planned
   set and, for a new external dependency, an architecture decision.

The callbacks, the conformance suite for each port, and the dependency rules
per role are in
[the architecture technical depth](architecture-technical.md#technical-arch-ports).

<a id="technical-getting-started-checks"></a>
## Everyday Commands

Concept: [Contributing: toolchain and checks](getting-started.md#concept-getting-started-contributing).

| Purpose | Command |
| --- | --- |
| One test file while editing | `(cd apps/loopex && mix test test/bounds_test.exs)` |
| One application's credential-free suite | `(cd apps/loopex_daemon && mix test)` |
| Formatting | `mix format` |
| Paired documents, indexes, links, and the status register | `mix loopex.status` |
| Concept-before-Technical-depth in compiled documentation | `mix loopex.docs_check` |
| Dependency direction and budget | `mix loopex.deps_budget` |
| The fast check, once per integration candidate | `bash scripts/check.sh` |
| The fast check for a prose-only change | `bash scripts/check.sh --docs` |
| The mode CI picks from the diff | `bash scripts/check.sh --select` |
| The slow check, once before a milestone closes | `LOOPEX_PROVIDER_API_KEY=... bash scripts/check-release.sh` |

Each application's test helper excludes the release-only tags —
`real_provider`, `long_bound`, `node_client`, and `cross_uid` where they occur —
so `mix test` needs no credential. The fast check runs every application's suite
in its own VM and prints a line every thirty seconds; it ends with
`check: PASS` or names what failed. What each check runs, and what the slow
check additionally needs, is in [DEVELOPMENT.md](../../DEVELOPMENT.md); every
repository check and what it holds is listed in
[the architecture technical depth](architecture-technical.md#technical-arch-checks),
and which checks a change selects is in the
[verification guide](verification.md#concept-verification-selection).

<a id="technical-getting-started-layout"></a>
## The Repository Map

Concept: [Contributing: where things live](getting-started.md#concept-getting-started-layout).

| Path | What is there |
| --- | --- |
| `apps/loopex_protocol/` | Canonical encoding, tool definitions, the session protocol modules, and `priv/` schemas and vectors |
| `apps/loopex/` | The kernel: `lib/loopex.ex` (the facade), `lib/loopex/runtime/` (Control, coordinator, reducer, dispatcher), the ports, and `lib/mix/tasks/` (the repository checks) |
| `apps/loopex_store_local/` | The local Store and artifact store |
| `apps/loopex_llm_reqllm/` | The ReqLLM model adapter and its provider companion build |
| `apps/loopex_executor_local/` | The local executor, workspace lease, and coding tools |
| `apps/loopex_telemetry/` | The telemetry handler |
| `apps/loopex_composition/` | The reference stack, credential custody, and skill packs |
| `apps/loopex_reference_client/` | The thin embedded client and its recovery helpers |
| `apps/loopex_cli/` | The `loopex` command, its policies, and its daemon client |
| `apps/loopex_app_server/` | The standard-input/output server and its shipped host |
| `apps/loopex_daemon/` | The daemon |
| `clients/node/` | The independent JavaScript consumer |
| `scripts/` | `check.sh`, `check-release.sh`, and their helpers |
| `docs/` | Documentation; start at [docs/README.md](../README.md) |
| `.agents/skills/` | Portable procedures: `open-milestone`, `close-milestone`, `adr`, `mutant-hunt` |

Each application's tests are under its own `test/`, with shared helpers in
`test/support/`. Tests use a temporary `LOOPEX_HOME` and temporary workspaces,
and their helpers fail before touching real user state. The map from each
concern to its module is in
[the architecture technical depth](architecture-technical.md#technical-arch-concerns).

<a id="technical-getting-started-milestones"></a>
## Plans, Decisions, and Commits

Concept: [Contributing: how work is planned](getting-started.md#concept-getting-started-milestones).

- **What is authorized now:** the Current Status block of
  [docs/plans/README.md](../plans/README.md).
- **A milestone:** `docs/plans/NAME.md` and `docs/plans/NAME-technical.md`,
  written with the `open-milestone` skill and closed with `close-milestone`;
  the steps are in the [milestone guide](milestones.md#concept) and
  [its mechanics](milestones-technical.md#technical-depth).
- **An architecture decision:** a numbered pair under `docs/adr/`, prepared with
  the `adr` skill and accepted by the maintainer before dependent work.
- **A document:** a new active document under `docs/` is a Concept and Technical
  depth pair, indexed in its directory's `README.md` and in
  [docs/README.md](../README.md) in the same change, following the
  [charter's link and anchor rules](development-charter-technical.md#technical-traceable-depth).
- **A commit:** a short imperative title `area(marker): summary`, where the
  marker is the milestone the work belongs to, such as `docs(M5): …`, with no
  content-origin attribution; `scripts/check-commit-messages.sh` enforces the
  latter as part of the fast check.

<a id="technical-getting-started-diagnosing"></a>
## A First Trace Session

Concept: [Diagnosing a running runtime](getting-started.md#concept-getting-started-diagnosing).

Start the runtime with `diagnostics_to: self()`, then:

```elixir
{:ok, _config} = Loopex.trace(runtime, %{modules: [Loopex.Runtime.Control], level: :calls})
{:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create-1")
{:ok, status} = Loopex.trace_status(runtime)
:ok = Loopex.trace_stop(runtime)

receive do
  {:loopex_diagnostic, entry} -> IO.inspect(entry)
end
```

Each entry is bounded plain data such as
`%{"kind" => "trace_call", "module" => "Loopex.Runtime.Control", "function" => "handle_info", "arity" => 2, ...}`,
and `trace_status/1` reports how many entries were emitted and dropped.
`modules` takes exact module names or the namespace wildcards `:loopex` and
`:loopex_protocol`; `level` is `:calls`, `:returns`, or `:arguments`, and
arguments are redacted before they are rendered. The domain and ceilings are in
[the observability technical depth](observability-technical.md#technical-observability-trace).
