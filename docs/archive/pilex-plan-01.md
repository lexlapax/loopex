# Pilex — Vision, Architecture, and Project Plan (01)

*A Pi-class agentic coding core, written in Elixir, where the runtime is the
framework. First planning document, 2026-08-14. Grounded in: pi.dev / the
`earendil-works/pi` monorepo as of Aug 2026; the current Elixir/BEAM ecosystem
(ReqLLM 1.20, OTP 26+ primitives); and the allbert-assist codebase at v1.4 M13,
whose `Coding.*` subsystem is the proven seed corpus.*

---

## 1. Vision

**Pilex is pi.dev rebuilt on the BEAM: a minimal, extensible, single-user
coding agent core — an agent is a loop around an LLM — that other products wrap.**
It is not an assistant platform, not a security product, not a channel hub.
It is the inner loop, the event vocabulary, the session substrate, and the
extension mechanism, done once, small, and well — so that an ecosystem can form
around it the way OpenClaw formed around pi.

The design center is José Valim's argument, taken literally:

> "People are sleeping on Elixir for a coding harness:
> — Hot-code swapping allows you to build an extensible plugin system similar
> to Pi, which reloads live without dropping state
> — Designing a client-server architecture, similar to OpenCode, is basically a
> byproduct of the actor model (plus you get both IO/CPU concurrency)
> — The built-in distribution means you can easily isolate the brains
> (model + session) from the hands (sandbox + tools). […] Those can definitely
> be built from scratch in other languages, but in Elixir the building blocks
> are basically part of the runtime."

and, on frameworks:

> "You don't need an external framework for this. **The runtime is the framework.**"

Those four sentences are pilex's architecture. Each maps to a concrete
subsystem, and each is something pi is currently *building by hand in
TypeScript* that the BEAM supplies natively:

| Valim's claim | What pi built by hand | What pilex gets from the runtime |
|---|---|---|
| Hot-code swap → live plugin system | jiti-style TS re-execution + `/reload`; state must be replayed from the session log | `Code.compile_file/1` + `:code.soft_purge/1`; extension code swaps while session **processes keep their state** — nothing to replay |
| Client-server as an actor-model byproduct | The new experimental `pi-protocol` / `pi-server` / `pi-client` stack: CBOR frames, session leases, a Unix-socket server — months of protocol engineering | A session **is** a process. Attach = subscribe. Multi-client, exclusive/shared leases, IO/CPU concurrency — free |
| Distribution isolates brains from hands | Not attempted; pi runs everything in one Node process, sandboxing is "use Docker around the whole thing" | `:peer` (stdio-connected node in a container), `:erpc`, optional FLAME — the session on your machine, tools in Docker or on a remote box, one session driving many nodes (the Livebook shape) |
| The runtime is the framework | pi-agent-core reimplements queues, barriers, abort signals, subscriber backpressure | GenServer/gen_statem, Task.Supervisor, Registry, monitors, supervision trees |

**Why now.** Three lines converged in 2026:

1. **Pi validated the product shape.** A sub-1,000-token prompt, ~6 tools, YOLO
   trust, TypeScript self-extension — and competitive Terminal-Bench rankings.
   Minimal harnesses are not a compromise; they are a category.
2. **Pi is converging on OTP's architecture from the outside.** The
   post-Earendil `pi-protocol`/`pi-server`/`pi-client` packages are pi growing
   a session-server: framing, leases, snapshots, locking. Every one of those is
   a hand-built replica of what the BEAM ships. The strongest possible argument
   for pilex is pi's own roadmap.
3. **The allbert experience proved both halves of the lesson.** Allbert built a
   working Pi-mode loop (`AllbertAssist.Coding.*`, ~5.8k LOC extractable, with
   tests) — so the seed corpus exists. And allbert's v1.4 is a months-long,
   5,900-line-plan effort to retrofit a kernel/pack boundary into a ~240k-LOC
   application — so the cost of *not being born with boundaries* is measured,
   not hypothetical. Pilex is born as the boundary.

**The ecosystem bet.** OpenClaw's history is the template: it consumed pi's
lower layers, replaced the top, and built a multi-channel product around the
core — possible only because pi's seams (wire API / loop / harness / UI) were
clean. Pilex aims to be that layer for the BEAM:

- **pilex** — MIT core: loop, sessions, events, tools, extensions, hands.
  Single trusted operator, YOLO by default, no authority machinery.
- **allbert-assist** — the first wrapper: adds Security Central, confirmations,
  durable objectives, memory, and channels *around* pilex sessions — Pi's
  ergonomics on Allbert's authority spine (the exact conclusion of
  `docs/archives/pi-integration-rethink.md`, now with the two halves in two
  products instead of one codebase).
- **Future wrappers** — a team/enterprise coding server (multi-user session
  leases, worktree-per-session, review gates, audit) is the natural
  "OpenClaw-for-teams" seat; a Livebook-style notebook frontend is another.
  Neither requires pilex to grow — only to hold its seams.

---

## 2. What Pi teaches (research digest)

Facts verified against pi.dev, the `earendil-works/pi` monorepo, and Mario
Zechner's essays (Aug 2026). Full detail lives in the research notes; this is
what constrains pilex.

**Philosophy.** "There are many agent harnesses but this one is yours."
Adapt the harness via extensions rather than accepting baked-in features;
"if I don't need it, it won't be built." System prompt + tool definitions
under ~1,000 tokens. Deliberate exclusions, each with a prescribed
replacement: no MCP (CLI tools + READMEs, or an extension), no sub-agents
(spawn `pi` via bash/tmux, or an extension), no permission popups (containers,
or a `tool_call` extension), no plan mode, no todos, no background bash.
Armin Ronacher's framing: the deep idea is **self-extension** — "you ask the
agent to extend itself."

**Layering.** `pi-ai` (unified LLM wire layer: ~40 providers over ~4 real wire
APIs, streaming event taxonomy, partial-JSON tool-arg streaming, cost/usage,
model registry, OAuth) → `pi-agent-core` (the `Agent` class: turn loop,
parallel/sequential tool execution, steering + follow-up queues, event
stream) → `pi-coding-agent` (harness: JSONL tree sessions, compaction,
extensions, skills, themes, four modes — TUI / print / JSON / RPC) →
`pi-tui` (differential rendering, synchronized output). The seams are the
product: OpenClaw consumed the bottom, replaced the top, and eventually forked
the middle while keeping only `pi-tui`.

**Event vocabulary** (shared by the loop, the TUI, JSON mode, and RPC mode):
`agent_start → turn_start → message_start/update/end` (wrapping
`text_delta` / `thinking_delta` / `toolcall_delta` inner events) →
`tool_execution_start/update/end` → `turn_end` (carries batched tool results)
→ … → `agent_end`, plus harness-level `agent_settled`, `queue_update`,
`compaction_start/end`, `auto_retry_*`. One vocabulary end-to-end is what
makes four frontends cheap.

**Sessions.** JSONL **trees** (format v3): line 1 is a header
(`{type:"session", version, id, cwd, parentSession?}`); every entry has
`{id, parentId, timestamp}`; two children of one parent = a branch; context
assembly walks leaf→root honoring compaction entries. Entry types: `message`,
`model_change`, `thinking_level_change`, `compaction`, `branch_summary`,
`custom` (extension state, excluded from LLM context), `label`,
`session_info`. `/fork`, `/clone`, `/tree`, `--no-session`. Compaction
auto-triggers on a context-window reserve (default 16,384 reserve / 20,000
keep-recent), writes a structured summary, and is extension-interceptable.

**Extensions.** TS files in `~/.pi/agent/extensions/` and trust-gated project
`.pi/extensions/`, hot-reloaded via `/reload`. They register tools (including
replacing built-ins), slash commands, shortcuts, flags, providers, renderers;
they hook the loop (`before_agent_start`, `tool_call` — mutate args or block,
`tool_result`, `context` — rewrite messages before every LLM call, `input`,
compaction hooks) and get a UI capability (`ctx.ui.select/confirm/input/…`)
that **round-trips over RPC** so a host can render pi dialogs in its own UI.
Extension state survives reload only by replaying the session log on
`session_start` — the pattern pilex makes unnecessary.

**Remote direction.** `pi-protocol` (length-prefixed CBOR frames, versioned
hello, snapshots, locking), `pi-server` (Unix-socket session server),
`pi-client` (`SessionLease`, exclusive vs shared attach). This is the part of
pi that OTP makes nearly free, and its existence confirms multi-client
session-serving is where the category is heading.

**What the BEAM adds that pi structurally cannot.** One Node process means:
a crash anywhere is a crash everywhere; extension state lives in module scope
and dies on reload; parallel tools share one event loop; sandboxing is
all-or-nothing (containerize the whole agent). Pilex gets per-session crash
isolation, supervised restart with state rebuilt from the session log,
extension crash-isolation, real parallelism, and a *per-tool-call* sandbox
boundary (the hands node) — all from the runtime.

---

## 3. Design principles (locked-decision candidates)

Numbered for operator sign-off, in the allbert Locked Decision style. LD1–LD4
are the identity of the project; the rest are strong defaults.

- **LD1 — The runtime is the framework.** No agent framework in pilex. Agents,
  sessions, queues, buses, and supervision are plain OTP (`gen_statem`,
  `GenServer`, `DynamicSupervisor`, `Registry`, `Task.Supervisor`, monitors).
  Dependencies are *libraries* with narrow jobs. Jido is explicitly not a
  dependency — the LLM-calling piece of that ecosystem, **ReqLLM**, is
  standalone by design (built on Req + Finch only; jido_ai depends on it, not
  the reverse) and is the one significant dep pilex takes.
- **LD2 — Pi's minimalism budget is a hard constraint.** System prompt + tool
  definitions ≤ 1,000 tokens. Core tool surface ≤ 7 (`read`, `write`, `edit`,
  `bash`, `grep`, `glob`, `ls`). Pi's exclusion list is pilex's exclusion
  list: no MCP, no sub-agents, no permissions, no plan mode, no todos in core
  — each answered by an extension or a wrapper (§7). Every proposed core
  addition must answer: *why is this not an extension?*
- **LD3 — Sessions are processes; files are truth.** One supervised
  `Pilex.Session` process per live session. Durable state is an append-only
  JSONL tree on disk (§4.5); process state is a projection rebuilt from it on
  restart. Event-sourced by construction — crash recovery, attach, fork, and
  audit all fall out of the same walk.
- **LD4 — YOLO core; authority is a wrapper concern.** Pilex trusts its
  operator exactly as pi does: full filesystem, no permission prompts, "run it
  in a container if you don't trust the work." The
  `pi-integration-rethink` axis (single-operator YOLO vs cross-channel gated)
  separates *products*, not features — pilex takes one side, allbert keeps the
  other, and the seam between them is three behaviours (§7). Pilex never
  grows a Security Central.
- **LD5 — One event vocabulary end-to-end.** A single typed event contract
  (§4.3) drives the TUI, print/JSON mode, RPC clients, web attach, and
  wrappers. No frontend gets a private stream shape. (Proven in allbert:
  `Coding.StreamEvent` + pure `StreamRenderer` — lifted, then extended with
  pi's turn/lifecycle framing.)
- **LD6 — Extensions are compiled Elixir, trust is explicit, state is not
  their problem.** Extensions are `.ex` files compiled at runtime
  (`Code.compile_file/1`), hot-swapped with `:code.soft_purge/1`, supervised
  per-extension. Because durable state lives in session processes and the
  log, a reload swaps *code* without dropping *state* — Valim's first pillar,
  and the concrete one-up over pi's replay-on-reload pattern. Project-local
  extensions are trust-gated (pi's `trust.json` shape). Compiling Elixir is
  arbitrary code execution — pilex says so plainly, gates on trust, validates
  module-name prefixes (flat namespace clobbering), and routes *untrusted*
  code to a hands node, never into the brains.
- **LD7 — Brains/hands is an executor decision, not an architecture.** Every
  tool call goes through one `Pilex.Executor` behaviour. Placements:
  `Local` (same node — the default), `Peer` (a `:peer` node launched over
  stdio into a container — sandboxed, no EPMD, no open distribution ports),
  `Node` (`:erpc` to a trusted remote), `Flame` (elastic trusted scale-out,
  optional). The session — model credentials, context, log — never leaves the
  brains node. Distribution cookies are not a security boundary; the container
  is; stdio transport is preferred for sandboxed hands, and terms arriving
  from hands are treated as data, not trusted structure.
- **LD8 — Born with boundaries.** Pilex ships as a small number of OTP
  applications with enforced compile-time seams from day 0 (§4.0) — the v1.4
  lesson applied in the cheap direction. No namespace grows past its app.
- **LD9 — Shape-compatible sessions, not byte-compatible.** The JSONL tree
  (header line; `id`/`parentId`/`timestamp` entries; the same entry-type set)
  follows pi's v3 shape so the mental model and tooling transfer; message
  payloads are ReqLLM-shaped, so byte compatibility is a non-goal. A
  `pilex import` for pi session files is a cheap later add.
- **LD10 — Headless first.** The loop, sessions, events, and print/JSON modes
  land before any interactive UI. The TUI is a *client* of the event stream,
  never its owner. (Allbert's `stream_event_sink` pattern, generalized.)
- **LD11 — Every shared resource has one owning process.** Allbert v1.1's
  eight corrective rounds traced to resource ownership (the adapter mailbox,
  then the sole SQLite writer). Pilex applies it from the start: one writer
  per session file, one owner per terminal, one owner per hands connection.
  The core has **no database**; the optional SQLite session backend (separate
  package, later) inherits allbert's `WriterLock` (~100 LOC, lift verbatim).
- **LD12 — Test isolation from day 0.** Every test runs against a temp
  `PILEX_HOME`; no test touches a real home or shares global state. Provider
  calls in tests are fixture-driven (ReqLLM fixtures); real-provider runs are
  a tagged, explicitly invoked lane. (Allbert learned this at v0.53 prices;
  pilex starts there.)

---

## 4. Architecture

### 4.0 Applications and layout

Mirroring pi's four-package layering, minus the layer Elixir already has
(ReqLLM ≈ pi-ai):

| App / package | pi analogue | Contents |
|---|---|---|
| `pilex_core` | pi-agent-core + most of pi-coding-agent | Session processes, turn loop, event contract, tool behaviour + 7 core tools, JSONL tree store, compaction, extension host, executor behaviour + Local/Peer/Node executors, model layer (thin over ReqLLM) |
| `pilex` | pi-coding-agent CLI + pi-tui (line-oriented) | The `pilex` binary: TUI, print/JSON/RPC modes, daemon + attach, config/home, AGENTS.md + skills discovery, packaging |
| `pilex_web` *(later, optional)* | pi-web-ui/pi-server | Bandit + Plug + WebSock attach surface; no Phoenix |
| `pilex_store_sqlite` *(later, optional)* | session-backends/sqlite-node | SQLite session backend on `WriterLock` |

Two packages at v0.1. `pilex_core` never depends on UI, HTTP, or persistence
beyond the file store. Deps for the pair:
`req_llm` (~> 1.20), `jason`, `owl` (TUI), `muontrap` (default process
runner), `erlexec` (PTY / process-group kill, when needed), `burrito`
(packaging). Nothing else of substance — no `jido`, no `phoenix`, no Ecto.

### 4.1 Supervision tree

```
Pilex.Supervisor
├── Registry            (Pilex.Registry — sessions, turns, leases, subscribers)
├── Phoenix.PubSub      (Pilex.PubSub — per-session event topics; standalone lib, no Phoenix)
├── Pilex.Store         (session-file IO: one writer process per open session file)
├── Pilex.Extensions    (host: discover/compile/reload; one supervised process per extension)
├── Pilex.Hands         (DynamicSupervisor: peer/erpc executor connections)
├── Pilex.Sessions      (DynamicSupervisor)
│    └── Pilex.Session  (gen_statem, one per live session)
│         └── Task.Supervisor (the turn task; parallel tool tasks)
└── frontends, per mode
     ├── Pilex.TUI       (owl renderer + raw-input owner)
     ├── Pilex.RPC       (LF-delimited JSON over stdio, pi RPC-mode shaped)
     └── Pilex.Serve     (daemon listener: Unix socket; pilex_web adds WebSocket)
```

A session crash kills one session; the supervisor restarts it and the process
rebuilds from its JSONL log (LD3). A tool task crash fails one tool call. An
extension crash fails one extension. The TUI crashing does not touch the
session — it re-attaches. This paragraph is the client-server pillar: there is
no "server mode" to build, only listeners to open.

### 4.2 The session process and turn loop

`Pilex.Session` is a `gen_statem` with states `idle → streaming →
executing_tools → (compacting) → idle`, holding: the ReqLLM context
projection, current model + thinking level, tree position (leaf id), steering
and follow-up queues, active turn task ref, and subscriber set.

The turn loop (one supervised task per turn):

```
prompt/steer/follow_up arrives
  → context_transform hooks (extensions: prune/inject)
  → ReqLLM.stream_text(model, context, tools)     # brains node
  → stream chunks → typed events → PubSub fan-out  # §4.3
  → tool calls collected (partial-JSON args streamed as deltas)
  → tool batch: preflight sequentially (tool_call hooks may mutate/block)
      → execute via Pilex.Executor placement       # §4.7 — maybe another node
      → parallel by default; sequential per-tool opt-out (pi semantics)
  → results appended to context + log → loop until no tool calls
  → steering queue drained between tool batches (pi: steer)
  → follow-up queue drained after the agent would stop (pi: follow_up)
  → agent_settled when nothing is pending
```

Abort is a monitor + `Task.Supervisor.terminate_child` + provider-stream
cancel fun (allbert's `TurnSupervisor` already implements
register-stream-cancel + partial-response synthesis; it ports directly, with
ADR 0085's cooperative-cancellation semantics behind it). Esc-to-interrupt,
steer-vs-new-input routing, and queue clearing follow pi's TUI conventions
(Enter = steer, Alt+Enter = follow-up, Esc = abort restoring queues).

**Attach semantics** (pi's `SessionLease`, natively): any process may
*observe* a session (subscribe to its topic); at most one client holds the
*input lease* (exclusive prompt/steer rights) — a `Registry` entry with a
monitor, released on crash. Shared-observer + exclusive-driver covers the
TUI + web + wrapper cases without protocol work.

### 4.3 The event contract

One typed vocabulary, every consumer. Merges pi's agent/harness framing with
allbert's proven `Coding.StreamEvent` (monotonic per-turn `seq`,
validated-on-construction, string-key-tolerant for transport):

| Phase | Events |
|---|---|
| Lifecycle | `session_started`, `agent_start`, `agent_end`, `agent_settled`, `queue_update` |
| Turn | `turn_start`, `turn_end` (batched tool results, usage/cost), `turn_cancelled` |
| Message stream | `text_delta`, `thinking_delta`, `tool_call_delta` (partial JSON args), `tool_call_ready` |
| Tool execution | `tool_start`, `tool_update` (streamed output), `tool_end` (split payload: model `content` + display `detail`) |
| Housekeeping | `compaction_start/end`, `retry_start/end`, `model_changed`, `thinking_changed`, `error` (partial content preserved, pi's no-throw contract) |

Every event carries `{session_id, turn_id, seq}`. Fan-out is
`Phoenix.PubSub.broadcast` on `"session:<id>"` — subscribers on any node in
the cluster receive it, which is what makes a remote observer UI a
non-feature. Durable journaling is one plain consumer appending to the log —
no GenStage unless a real backpressure need appears.

The **split tool result** (model payload vs display payload) is load-bearing:
pi's cleanest idea, already adopted by allbert (ADR 0029/0067), and the reason
one event stream can serve a dumb terminal and a rich UI without re-rendering
logic in the core.

### 4.4 Tools

```elixir
defmodule Pilex.Tool do
  @callback spec() :: %{name: String.t(), description: String.t(), parameters: map()} # JSON Schema
  @callback execution_mode() :: :parallel | :sequential
  @callback execute(args :: map(), ctx :: Pilex.Tool.Ctx.t()) ::
              {:ok, %{content: iodata(), detail: term()}} | {:error, iodata()}
end
# Ctx: session_id, turn_id, cwd, emit/1 (progress events), abort_ref, executor
```

Seven core tools, seeded from allbert's stripped `Actions.Coding.*` (the
~110-LOC security envelope per tool is exactly what gets deleted; the ~40-LOC
working core remains): `read`, `write`, `edit` (exact-match, from
`FileEffects`), `bash` (argv-vs-raw classification from `BashSpec`; muontrap
child-tree kill; erlexec PTY when interactive), `grep`/`glob` (from
`Coding.Search`), `ls`. Path discipline (cwd jail, symlink policy,
gitignore awareness) comes from `Coding.PathPolicy` — in pilex it is a
*convenience* (correct relative behavior), not a security boundary (LD4).
Errors become `isError` tool results, never crashes of the loop.
Tool results are byte-bounded toward the model (allbert: 12,000 bytes) with
overflow spilled to files the model can `read` — pi's file-as-state ethos.

### 4.5 Sessions on disk

`$PILEX_HOME/sessions/<cwd-slug>/<timestamp>_<uuid>.jsonl`, format v1:

- Line 1 header: `{"type":"session","version":1,"id":…,"cwd":…,"parent_session":…}`
- Entries: `{type, id, parent_id, ts, …}` — a tree; branch = two children of
  one parent; current position = leaf. Types: `message` (user / assistant
  with text/thinking/tool-call blocks + usage/cost/stop-reason / tool_result
  / bash_execution / custom-in-context), `model_change`, `thinking_change`,
  `compaction` (`summary`, `first_kept_id`, token counts, read/modified
  files), `branch_summary`, `custom` (extension state, excluded from
  context), `label`, `session_info`.
- Context assembly = leaf→root walk honoring compaction (pi's
  `buildContextEntries` semantics). Fork = new file with `parent_session`;
  clone = copy of the active branch; `--no-session` = in-memory store.

Compaction: auto at `context_tokens > window − reserve` (defaults: reserve
16,384, keep-recent 20,000 — pi's numbers until measurement says otherwise);
structured summary (goal, progress, decisions, next steps, file lists);
repeat compactions stack from the previous boundary; manual
`/compact [instructions]`; extension-interceptable before write.

### 4.6 Extensions

Discovery: `$PILEX_HOME/extensions/*.ex` (or `<dir>/extension.ex`), plus
trust-gated project `.pilex/extensions/`. Each compiles in its own supervised
host process; a compile failure or crash disables that extension, not pilex.

```elixir
defmodule Pilex.Extension do
  @callback init(api :: Pilex.Extension.API.t()) :: {:ok, state} | {:error, term()}
  # Optional hook callbacks, mirroring pi's surface:
  #   session_start/2, before_agent_start/2 (mutate system prompt / inject),
  #   tool_call/2 (mutate args | {:block, reason}), tool_result/2 (rewrite),
  #   context/2 (rewrite messages before every LLM call — the memory/pruning seam),
  #   input/2 ({:handled, …} | :continue), compaction/2, agent_settled/2
end
```

The API registers tools (including replacing built-ins), slash commands,
shortcuts, providers, and renderers; exposes `ui` (select/confirm/input/
notify/status) that round-trips over RPC exactly as pi's does, so hosts render
pilex dialogs in their own UI; and exposes `append_entry`/`custom message`
for durable extension state.

Reload (`/reload` or a file-watcher): recompile → `:code.soft_purge` the old
version (falling back to purge under supervision) → re-init hosts. Session
processes are untouched — **live reload without dropping state** is the demo
that carries the project's thesis, and it must work in milestone M3, on a
mid-turn session, on camera.

Two honest lines in the docs from day one: extensions run with your full
system permissions (pi's stance, stated as plainly); and compiling Elixir
*is* executing it (module bodies run at compile time) — trust gating is the
only brake, and untrusted code belongs on a hands node, or nowhere.

### 4.7 Hands: the distribution pillar

```elixir
defmodule Pilex.Executor do
  @callback start(opts) :: {:ok, handle} | {:error, term()}
  @callback run(handle, tool :: module(), args :: map(), ctx) ::
              {:ok, result} | {:error, term()}
  @callback stop(handle) :: :ok
end
```

- `Executor.Local` — same node. The default; zero ceremony.
- `Executor.Peer` — a `:peer` node whose exec is `docker run -i <image>`
  (or podman/firejail), **connected over stdio** (`connection: :standard_io`):
  no EPMD, no listening distribution port, container filesystem/network as the
  sandbox. The hands node runs a minimal pilex-hands release (tools +
  executor server only — no model creds, no session log). This is the
  sandboxed placement pi answers with "wrap all of pi in Docker" — pilex
  scopes it to the tool call.
- `Executor.Node` — `:erpc` to an already-running trusted node (your build
  box, a beefy remote). Cookie-authenticated distribution; documented as a
  *trusted* placement only.
- `Executor.Flame` *(optional, later)* — a FLAME pool for elastic trusted
  scale-out (same-release closures; not a sandbox; OTP 26+).

Placement is per-session config with per-tool override (`bash` on the peer,
`read` local against a synced worktree — or everything on the peer). One
session may hold several hands handles at once — one brain, many hands, the
Livebook topology. Version-skew discipline: the executor protocol is a small
versioned term contract, because a hands node is a different release.

### 4.8 Model layer

ReqLLM 1.x is the wire layer: 21 providers / ~1,205 models via LLMDB,
`"provider:model"` specs plus plain maps for local endpoints (Ollama, vLLM),
normalized `StreamChunk`s (`:content`, `:thinking`, `:tool_call`, `:meta`),
tool-call normalization, usage + best-effort USD cost per response, telemetry.
Pilex adds a thin `Pilex.Model` (~300 LOC, seeded from allbert's
`Settings.ModelRuntime` + `ProviderCatalog` with config reads swapped to
`Pilex.Config`): model aliases and roles (`fast` / `capable` / `thinking`),
auth resolution order (explicit key > stored > env), base-URL classing for
local endpoints, and mid-session model switch — including cross-provider
thinking-block handoff (pi transforms incompatible thinking blocks to tagged
text; ReqLLM's canonical context makes this cheap; verify against ReqLLM
current behavior at build time).

The `reasoning` knob follows pi's unified scale
(`minimal|low|medium|high|xhigh|max`) mapped per provider.

### 4.9 Frontends and channel semantics

Frontends are event-stream clients holding (at most) the input lease:

- **TUI** — line-oriented on `owl` (the Claude-Code-shaped genre default;
  allbert's `LiveRegion`/`InputDriver` + pure `StreamRenderer` are the
  reference consumer implementation, and OTP 26+ `prim_tty` fixed the
  historical raw-input pain). A rich alt-screen TUI (ExRatatui, or an external
  Rust/Go TUI speaking RPC) is an explicit later option, not a v0.x bet —
  the ecosystem's full-screen TUI story is its weakest area and pilex should
  not be hostage to it.
- **print / JSON modes** — one-shot and JSONL-event-stream, for scripts and CI
  (pi's `-p` / `--mode json`).
- **RPC mode** — bidirectional LF-delimited JSON over stdio, command
  vocabulary shaped on pi's (prompt/steer/follow_up/abort/get_state/
  set_model/compact/fork/tree/…), so anything that can embed pi can embed
  pilex with a shim.
- **daemon + attach** — `pilex serve` opens a Unix socket; `pilex attach`
  connects a thin client; BEAM-native clients may instead join via
  distribution and subscribe directly. This is allbert's daemon/attach
  product experience (ADR 0091) re-derived from primitives — and it is also
  exactly the `pi-server`/`pi-client` roadmap, pre-empted.

A "channel" in pilex is precisely: an event-stream subscriber + an input-lease
holder + a renderer. The wrapper (allbert) is what turns channels into
products (identity, delivery receipts, policy); pilex only guarantees the
semantics: ordered per-turn `seq`, split payloads, replayable from the log.

---

## 5. Harvest map (allbert → pilex)

The seed corpus. ~5.8k LOC of production code + ~3.4k LOC of tests port with
three seams stubbed; the survey is from a full-repo sweep at v1.4 M13.

| Allbert module(s) | Pilex home | Action |
|---|---|---|
| `Coding.StreamEvent`, `StreamRenderer`, `StreamPipeline` (~520 LOC) | `pilex_core` events | **Lift verbatim** (drop `Redactor`/`Response.normalize` calls) |
| `Coding.StreamingTurn`, `ToolLoop`, `Prompt`, `Session` (~1,180) | `pilex_core` loop | **Lift with 3 seams**: `Settings`→`Pilex.Config`, `Actions.Runner.run/3`→`Pilex.Executor`, drop `ApprovalHandoff` |
| `Coding.TurnSupervisor` (~400) | `pilex_core` turn | **Lift** (Registry + Task.Supervisor + stream-cancel + partial-response synthesis) |
| `Coding.PathPolicy`, `Search`, `FileEffects`, `BashSpec` + 6 `Actions.Coding.*` stripped of the security envelope (~1,700) | `pilex_core` tools | **Lift**; delete per-tool authorize/deny/block scaffolding |
| `Settings.ModelRuntime`, `ProviderCatalog`, `models.json`, `Models.*` (~1,400) | `pilex_core` model | **Lift-with-rewrite** (config reads → `Pilex.Config` behaviour) |
| `Runtime.WriterLock` (+Holder) (~150) | `pilex_store_sqlite` (later) | **Lift verbatim** |
| `Channels.Message` + `Channels.Outbound` + descriptor shape (~150) | `pilex_core` frontend contract | **Lift the shape** (2-callback behaviour + descriptor keys), not the Ecto/HMAC substrate |
| `Coding.CommandGrants` (repo-fingerprinted "always allow") | wrapper (allbert) | Stays with authority; good idea, wrong layer |
| `AllbertTUI.LiveRegion`, `InputDriver` (~950) | `pilex` TUI | **Reference implementation** — reimplement thin, without the channel substrate |
| `Signals` taxonomy, `IntentAgent`, `Objectives`, Security/Settings Central, Memory, Packs | — | **Do not extract.** These are allbert |

Design inputs to re-read at build time: ADR 0068 (Pi-mode surface — the most
important single doc), 0067 (split payload contract), 0029 (typed responses),
0085 (cooperative cancellation), 0091 (daemon/attach), and
`docs/archives/pi-integration-rethink.md`.

License note: allbert code is being ported by its own author into a new MIT
project — record the provenance in the pilex repo anyway.

## 6. What pilex is not (exclusions, each with its home)

| Excluded | Where it lives instead |
|---|---|
| Permissions, confirmations, trust tiers, audit | Wrapper (allbert Security Central; a `tool_call` extension can add inline confirm, as in pi) |
| Memory (markdown memory, claims, retrieval) | Wrapper; a `context`-hook extension is the integration point |
| Intent routing, objectives, fan-out, durable jobs | Wrapper (allbert's stages 3–5) |
| Channels as products (Slack/Telegram/…, identity, receipts) | Wrapper; pilex provides the frontend contract only |
| MCP client | Extension (pi's stance; Zechner's data: idle MCP servers cost 7–9% of context; CLI + README beats it) |
| Sub-agents | Extension (spawn `pilex -p` via bash/tmux, or a supervised-session extension) |
| Plan mode, todos, background bash | Files (`PLAN.md`/`TODO.md`) and tmux, per pi; or extensions |
| Web UI product, hosted multi-user auth | `pilex_web` stays a bare attach surface; products are wrappers |
| A database | JSONL core; SQLite backend optional package |

## 7. The wrapper story: allbert around pilex

The seam is three behaviours plus the event stream — exactly the cut-points
the extraction survey identified:

1. **`Pilex.Executor`** ← allbert implements with `Actions.Runner.run/3` +
   Security Central: every pilex tool call becomes a registered action run,
   gated and traced. Gates cheap at the local-coding tier, absent never —
   ADR 0068's contract, now enforced by a package boundary instead of
   convention.
2. **`Pilex.Config`** ← allbert implements with Settings Central + Vault
   (allbert's `Coding.Config` already funnels every read through one
   `setting/2` helper — a ready-made adapter).
3. **The event stream** ← allbert's TUI/web/channels subscribe as ordinary
   frontends; allbert may hold the input lease and route steering per its own
   policy.
4. *(Later, optional)* **`Pilex.Extension`** ← allbert skills/memory surface
   as pilex extensions (the `context` hook is the Active-Memory injection
   point).

Consequences for the allbert roadmap (operator decisions, not enacted here):

- **v1.4 finishes as planned.** M13 is closed; what remains is release
  engineering (M13.3/M13.4 → M14–M17). Nothing in this document blocks or
  reopens it — and v1.4's pack contract is precisely what makes allbert
  *wrappable* later. Pilex is where new inner-loop investment goes; it is not
  a reason to abandon a 90%-done release.
- **Pilex is a separate repo and track, not a ladder entry.** It does not
  enter `roadmap.md`; the *integration* ("allbert consumes pilex_core behind
  a flag, `Coding.*` retired") is the future ladder candidate, natural
  around the 2.x boundary — and it makes 2.1 self-hosting concrete: allbert
  developing allbert *is* a pilex session with an allbert executor.
- **Recommended sequencing:** finish v1.4 → run pilex M0–M4 as the parallel
  greenfield track (it is small; §9) → decide the 1.5-vs-integration order
  with pilex v0.1 in hand rather than on paper.

The third seat — a team/enterprise wrapper (multi-user session server,
worktree-per-session, review gates, org policy) — is deliberately left to the
ecosystem; pilex's obligation to it is only: hold the seams, keep MIT, keep
the protocol stable.

## 8. Development posture

What transfers from allbert's process, and what deliberately does not:

**Keep** — test isolation from day 0 (LD12); one-owner-per-resource (LD11);
pre/post measured numbers for any improvement claim; no carried exceptions at
release close; paste-executable runbooks with inline PASS criteria; no
AI-tool attribution in commits/PRs/release notes; commit titles
`<version> <small title>`.

**Drop** — the 5,900-line living plan document, per-milestone evidence
ledgers, multi-round gate cascades, manifest digests. Pilex is a greenfield
core with no installed base: the process is a short plan per milestone, an
ADR-lite log (one page per locked decision), CI green, and a demo. Process
weight was the *cost* of retrofitting authority into a monolith; pilex's whole
premise is not paying it.

**Practicalities** — repo `lexlapax/pilex`, MIT (matching pi's ethos and the
wrapper story). CI: GitHub Actions matrix building mix releases + burrito
binaries (macOS arm64, Linux x64/arm64); escript is disqualified (needs host
Erlang). The release must include the `:compiler` application — runtime
extension compilation depends on it and a minimal release omits it. Version
lockstep across `pilex_core`/`pilex` (pi's monorepo convention).

## 9. Roadmap

Each milestone proves one pillar, ends with a runnable demo, and is
T-shirt-sized for one developer plus agents. Format/event contracts freeze
*early* because they are the expensive things to change.

| M | Deliverable | Pillar proven | Acceptance | Size |
|---|---|---|---|---|
| **M0** | Repo, apps, CI; **event contract v1 + session format v1 frozen** as docs + typespecs + property tests | Born with boundaries (LD8) | Contracts documented; fixture round-trip tests green | S |
| **M1** | Headless loop: ReqLLM streaming + 7 tools + JSONL tree sessions + `-p`/`--json` modes | The loop; runtime-as-framework (LD1) | Scripted multi-turn coding task passes against a real provider *and* replays from fixtures; resume from log after `kill -9` | M |
| **M2** | Interactive TUI (owl): streaming render, Esc-abort, steer/follow-up queues, `/model` mid-session switch | Ergonomics; one event vocabulary (LD5) | Side-by-side feature parity checklist vs pi TUI core flows | M |
| **M3** | Extensions: discovery, compile, trust gate, hooks, commands, **live `/reload` mid-session without state loss**; AGENTS.md + skills loading | Hot-code swap (Valim 1, LD6) | The on-camera demo: mutate an extension mid-turn; session continues | M |
| **M4** | `pilex serve` + `pilex attach`: daemon, Unix socket, RPC mode, input lease, multi-client observe | Client-server (Valim 2) | Two terminals + one JSON client attached to one live session; driver crash → observer unaffected → re-attach | M |
| **M5** | Hands: `Executor` behaviour, `Peer` Docker placement over stdio, `Node`/erpc placement | Distribution (Valim 3, LD7) | `bash`/`write` execute in a container while the session runs on the host; one session drives two hands nodes | L |
| **M6** | Compaction + tree: auto/manual compact, `/fork`, `/tree`, branch summaries | Long-session durability | Multi-hour session compacts and stays coherent; fork/branch round-trips | M |
| **M7** | Hardening + docs + packaged binaries (burrito) → **v0.1.0 public** | Shippable | Install-from-release smoke on macOS + Linux; docs cover every LD | M |
| **M8** | **The OpenClaw moment**: allbert consumes `pilex_core` behind a flag — executor→Actions.Runner, config→Settings, TUI as frontend | The wrapper thesis | Allbert's Pi-mode acceptance tests pass on the pilex loop | L |

M1–M3 are the identity; if the M3 demo doesn't land, the thesis is wrong and
the project should stop and say why. M8 is scheduled *after* v0.1.0 ships so
pilex's contracts stabilize against a public audience before its biggest
consumer bends them.

## 10. Risks

| Risk | Assessment | Mitigation |
|---|---|---|
| ReqLLM dependency (agentjido org, fast-moving) | Post-1.0 with a stated compat policy, ~30k downloads/mo, standalone by design; still effectively one org | It is a *library* on Req: pinnable, forkable, vendorable. The `Pilex.Model` seam means a provider-layer swap touches one module |
| Provider behavioral divergence (pi: "4 wire APIs, wildly divergent behavior"; token/cache accounting inconsistent) | Real, permanent | ReqLLM's fixture corpus absorbs most; pilex adds a small provider-quirk test lane; cost figures labeled best-effort |
| Elixir TUI ecosystem weakness | The known weakest area | Line-oriented owl UI is the genre default anyway; RPC mode makes an external rich TUI possible without core changes; ExRatatui watched, not bet on |
| Hot-reload sharp edges (purge kills processes still running old code; flat module namespace) | Manageable, must be engineered honestly | `soft_purge` first; supervised extension hosts absorb kills; module-prefix validation; the M3 demo is the regression test |
| Sandbox overclaim | The classic failure of agent harnesses | LD4/LD7 language is explicit: the *container* is the boundary, cookies are not, hands terms are data; docs say what pi's do — no permission system in core |
| Split focus vs the allbert ladder | The real cost | §7 sequencing: v1.4 finishes; pilex M0–M4 is deliberately small; the integration decision waits for working software |
| Scope creep toward allbert | The gravitational pull of an existing 240k-LOC feature set | LD2's standing question ("why is this not an extension?") plus §6's table are the budget; anything crossing it needs a new LD |
| Pi moves (protocol, formats, Earendil tiering) | Pi is now venture-adjacent with a fair-source tier planned | Pilex is shape-compatible, not byte-compatible (LD9) — inspiration, not tracking. MIT core matches pi's non-negotiable |

## 11. Open questions for the operator

1. **Name and repo** — `pilex` at `lexlapax/pilex`, MIT? (Assumed throughout.)
2. **Sequencing** — accept §7's recommendation (finish v1.4; pilex M0–M4
   parallel; re-decide 1.5-vs-integration with v0.1 in hand)?
3. **LD sign-off** — LD1–LD12 as written, amendments, or vetoes?
4. **Session-format ambition** — is shape-compatible (LD9) right, or is
   byte-level pi session import/export worth paying for at M1?
5. **TUI ambition** — line-oriented owl for v0.x (recommended), or is a rich
   alt-screen TUI a v0.x requirement?
6. **Hands image** — is a minimal `pilex-hands` Docker image part of v0.1.0's
   published artifacts, or documentation-only at first?

---

*Companion sources: `docs/archives/pi-integration-rethink.md` (the authority
axis), ADR 0068/0067/0029/0085/0091 (design inputs), and the three 2026-08-14
research briefings (pi architecture; BEAM building blocks; allbert extraction
survey) this document synthesizes.*
