# Runtime and Embedding

<a id="concept"></a>
## Concept

M1 turns the minimum single-machine coding-agent trace into product code: an
embedded host starts an explicit OTP runtime, creates or resumes a durable
session, attaches at a public-event cursor, submits a prompt, and lets the
runtime coordinate model and controlled-tool turns. The host supplies authority
and concrete edges; the runtime owns loop ordering and durable session truth.

The embedded API is a direct facade, not a transport or fourth boundary
behaviour. `Loopex.ReferenceClient` demonstrates that a thin caller needs no
coordinator access, Store access, alternate reducer, policy engine, or event
truth of its own. The M1 surface is unreleased and carries no compatibility or
packaging promise.

M2 keeps that shape and changes what an embedder has to assemble. The umbrella
is now eight applications: `loopex_composition` carries the reference stack an
embedder depends on instead of copying, and `loopex_cli` is a peer surface over
the same facade. Core gains two ports — the host policy and the artifact store —
and the runtime gains a tool set, declared run bounds, and transient progress
sinks as explicit start options. The turn machine itself is documented in
[Agent loop and tools](agent-loop-and-tools.md#concept).

`LoopexComposition` is one module of shipped code, not a wiring framework. It
names four concrete implementations, resolves its state root explicitly, and
refuses to start unless the host supplies the policy that governs the run. An
embedder who wants a different Store, Model, Executor, or ArtifactStore composes
the ports and the facade directly; a layer general enough to serve both waits
until a second real composition exists to give evidence for one.

Nothing in this milestone is frozen or labelled:
[Compatibility surfaces](compatibility-surfaces.md#concept).

Operator workflow and failure handling: [Runtime operations](../operator/runtime.md#concept).
Running a coding session: [Coding sessions](../operator/coding-sessions.md#concept).

<a id="technical-depth"></a>
## Technical depth

### Application and Dependency Shape

M1 had six applications; M2 has eight, adding one `:composition` and one
`:client`:

| Application | Role | Production dependency direction |
| --- | --- | --- |
| `loopex_protocol` | contract | none |
| `loopex` | core | protocol only |
| `loopex_store_local` | Store edge | inward to core |
| `loopex_llm_reqllm` | model edge | inward to core; the one locked ReqLLM dependency |
| `loopex_executor_local` | executor edge | inward to core |
| `loopex_composition` | composition | core, protocol, and the three edges it composes; no external dependency |
| `loopex_reference_client` | client | inward to core; concrete edges only in tests |
| `loopex_cli` | client | core plus exactly one composition |

`:composition` exists because a wiring application needs exactly the direction
an `:edge` may not have and a `:client` may not be depended on for. It is the
one production role permitted to declare a dependency on the concrete edges it
composes, it declares no external dependency in any environment, and it depends
on no client and on no other composition. A `:client` may depend on at most one
composition and never on another client. `mix loopex.deps_budget` enforces the
inventory and every direction above.

Core defines five boundary behaviours. M1's three — `Loopex.Store`,
`Loopex.Model`, and `Loopex.Executor` — are joined by `Loopex.Policy`, the host
authority port, and `Loopex.ArtifactStore`, the spill port. `Loopex.Executor`
also gains one optional `cancel/2` callback, recorded in
[M2 recorded limitations](../evidence/M2-recorded-limitations.md). Runtime,
composition, and client code introduce no sixth behaviour, broker, generic
operation layer, global registry, or alternate loop.

### Runtime Composition

`Loopex.start_link/1` requires `runtime_id` and a `Loopex.Store` handle. A working
loop additionally supplies all four loop inputs together:

- `model`: `%{module: module, model: model_spec, options: keyword}`;
- `executor`: the module/reference plus identity, executor epoch, fencing token,
  workspace reference, and workspace lease;
- `tool`: the provider-facing name, description, JSON input schema, governed
  tool ID/version, and effect class; and
- `grant_decision`: the explicit host result `{:host_policy, :allow}`.

Omitting the complete loop configuration retains the lower-level runtime and
embedded session API used by the Outcome 1–4 tests. Supplying only part of it is
invalid configuration; the runtime never infers a model, executor, tool, Store,
runtime reference, or policy decision.

M2 replaces the single `tool` declaration with a tool set and adds the options
the loop needs. `:tools` is the reference distribution's own declaration and the
only path by which a reserved `loopex.` identifier reaches the registry;
`:active_tools` selects which of them a session offers, defaulting to all of
them; `:policy` names the host authority module and is required whenever any
tool is active; `:bounds` and `:sampling` carry the declared run bounds and the
output allowance; and `:progress_to` and `:diagnostics_to` are optional
unsupervised sinks for transient items. The inherited `:tool` and
`grant_decision` options remain valid and are folded into the same tool set, so
there is exactly one way a tool reaches a model. Configured defaults exist for
the bounds — 16 turns, a 1_000_000-token budget, and a 600_000 ms deadline
duration — and for `max_tokens`; they serve a host that said nothing, and a host
that explicitly supplies a malformed value is refused at start.

The root supervisor is unnamed and uses `:rest_for_one`. The tool registry now
comes first, because runtime control and every session coordinator resolve tools
through it; runtime control follows and precedes the task supervisor, dynamic
session supervisor, and event dispatcher, so loss of configuration or authority
removes later transient work. A caller retains the opaque runtime reference; no
application environment or registered process identifies an instance, and two
runtimes in one VM hold independent tool sets.

### Loop and Commit Ordering

One session coordinator is the serial writer for a session. M1's working loop
was one fixed trace of exactly two model turns and one forced tool call:

1. commit prompt admission;
2. build and commit the exact canonical model-request bytes and SHA-256 digest;
3. dispatch only that committed request through `Loopex.Model`;
4. commit the normalized model result and verify it echoes the exact bytes and
   digest;
5. for one forced tool call, build the canonical JobRequest and explicit grant,
   then commit effect intent before dispatch;
6. let `Loopex.Executor.Local` revalidate the job, grant, live lease, audience,
   expiry, epoch, identity, and fence at its final serialized pre-start boundary;
7. retain the executor receipt before returning it;
8. commit the validated receipt fact and corresponding public event before the
   second model call; and
9. commit the terminal model result and `run.finished` event.

M2 generalizes that trace without changing its commit discipline: intent still
commits before dispatch and facts before publication, and the coordinator is
still the sole serial writer. What changes is that the number of turns is
decided by the model and the declared bounds rather than fixed, that each
request is projected from committed elements rather than built from one message,
that a turn may carry several tool calls, and that a call is dispatched only
after the host policy allows it. The stage-by-stage ordering is in
[Agent loop and tools](agent-loop-and-tools.md#technical-depth).

All durable and public boundary data is bounded plain data. Provider structs,
PIDs, functions, arbitrary terms, credentials, and implementation types remain
inside their owning edge or transient runtime process.

### Embedded API

The host-facing sequence uses the public facade only:

```elixir
{:ok, runtime} = Loopex.start_link(runtime_options)
{:ok, session_id} =
  Loopex.create_session(runtime, %{"workspace" => "example"}, command_id: "create-1")
{:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
{:accepted, "prompt-1"} =
  Loopex.command(attachment, %{type: :prompt, command_id: "prompt-1", content: "Do it"})
{:ok, event} = Loopex.next_event(attachment)
:ok = Loopex.stop(runtime)
```

`Loopex.snapshot/1` returns the attachment's exact durable anchor.
`Loopex.attachment_status/1` reports bounded transient queue information.
`Loopex.progress/2` and `Loopex.diagnostic/2` are transient. None of those
observations grants authority or substitutes for Store history.

### Reference Composition

`LoopexComposition` assembles the reference local stack in one module under a
hard ceiling of eighty effective lines, counting neither blank lines nor
comments. `start/1` starts the applications an `escript` does not start for it,
opens the durable store and the artifact store under the caller's resolved state
root, opens a workspace lease and the local executor, and returns a runtime
already composed with the four bootstrap coding tools:

```elixir
{:ok, runtime} =
  LoopexComposition.start(
    runtime_id: placement_id,
    state_root: state_root,
    workspace: workspace_path,
    policy: MyHost.Policy,
    progress_to: self()
  )
```

`:policy` has no default and its absence returns `{:error,
:host_policy_required}`. The composition owns wiring and never authority: a
permissive default shipped here would answer the host's question once for every
embedder that depends on it, which is why both permissive policies in this
repository live in clients an operator must name.

`:state_root` and `:workspace` are resolved by the caller, never discovered
here, and no value is read from application environment.
`LoopexComposition.artifacts/1` returns the artifact-store handle on its own,
because an artifact outlives the run that produced it and an operator
retrieving one later needs no runtime.

It ships as an application rather than as a snippet in a guide because a snippet
is re-derived once per embedder and goes stale silently the first time the
kernel's start-up shape changes; a shipped application changes once and breaks
the build of every dependant that must change with it. It is deliberately not a
generic wiring toolkit: it names `Loopex.Store.Local`, `Loopex.LLM.ReqLLM`,
`Loopex.Executor.Local`, and `Loopex.Store.Local.Artifacts` in this one place,
which is what makes the dependency direction checkable and what makes it
unusable for an embedder who wants a different implementation of any of the
four. That embedder composes the ports and the facade directly. With exactly one
implementation of each port in the inventory, a general wiring layer would have
no second composition to give evidence for its abstraction.

### Recovery

After the original process tree is known stopped or dead, the host reopens the
local Store with `recover_stale_writer: true`, starts a replacement runtime with
the same placement identity, and calls `Loopex.resume_session/3`. The new coordinator
discovers unresolved succession state, resolves the exact prior transaction,
reads the non-authorizing ownership head, and commits a fresh owner succession
before routing commands.

An effect whose committed intent lacks a committed fact remains
`effect_dispatched`; recovery never starts executor work from that state. The
caller requests `Loopex.reconciliation_query/1`, retrieves the retained receipt
from its executor authority, constructs either
`Loopex.ReferenceClient.Recovery.receipt/2` or `outcome_unknown/1`, and submits it
with `Loopex.reconcile/2`. The current coordinator validates every query and
origin binding before committing one receipt fact or terminal unknown outcome.

### Verification Entry Points

- `mix test --exclude real_provider` — complete credential-free suite.
- `mix loopex.deps_budget` — eight-application inventory, roles including
  `:composition`, dependency budget, and direction.
- `mix loopex.core_only` — core has no adapter resolution or environment-held
  runtime state.
- `mix loopex.docs_check` — compiled public documentation orders Concept before
  Technical depth.
- `mix loopex.status` — governance rows, indexes, links, and bound artifacts.
- `bash scripts/check-m2-gate.sh` — the current locked milestone gate,
  which also re-runs M1's selectors as inherited roles.
  `scripts/check-m1-gate.sh` remains the closed M1 gate. Real-provider roles
  receive their credential through the gate's bounded stdin protocol; do not
  export it to the gate's initial environment or put it in argv.

The exact selectors and evidence grammar are locked in
[the M2 gate](../plans/M2-gate.md) and, for the closed milestone,
[the M1 gate](../plans/M1-gate.md). Retained matrix and negative evidence are
indexed in [docs/evidence](../evidence/README.md).
