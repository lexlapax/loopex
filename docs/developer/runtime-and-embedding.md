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

Operator workflow and failure handling: [Runtime operations](../operator/runtime.md#concept).

<a id="technical-depth"></a>
## Technical depth

### Application and Dependency Shape

The umbrella has six M1 applications:

| Application | Role | Production dependency direction |
| --- | --- | --- |
| `loopex_protocol` | contract | none |
| `loopex` | core | protocol only |
| `loopex_store_local` | Store edge | inward to core |
| `loopex_llm_reqllm` | model edge | inward to core; the one locked ReqLLM dependency |
| `loopex_executor_local` | executor edge | inward to core |
| `loopex_reference_client` | client | inward to core; concrete edges only in tests |

Core defines exactly three boundary behaviours: `Loopex.Store`, `Loopex.Model`,
and `Loopex.Executor`. Runtime and reference-client code introduce no fourth
behaviour, broker, generic operation layer, global registry, or alternate loop.

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

The root supervisor is unnamed and uses `:rest_for_one`. Runtime control precedes
the task supervisor, dynamic session supervisor, and event dispatcher, so loss
of authority removes later transient work. A caller retains the opaque runtime
reference; no application environment or registered process identifies an
instance.

### Loop and Commit Ordering

One session coordinator is the serial writer for a session. Its working loop is:

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
- `mix loopex.deps_budget` — six-app inventory, dependency budget, and direction.
- `mix loopex.core_only` — core has no adapter resolution or environment-held
  runtime state.
- `mix loopex.docs_check` — compiled public documentation orders Concept before
  Technical depth.
- `/bin/bash -p scripts/check-m1-gate.sh` — locked milestone gate. The two
  real-provider roles receive their credential through the gate's bounded stdin
  protocol; do not export it to the gate's initial environment or put it in argv.

The exact selectors and evidence grammar are locked in
[the M1 gate](../plans/M1-gate.md). Retained matrix and negative evidence are
indexed in [docs/evidence](../evidence/README.md).
