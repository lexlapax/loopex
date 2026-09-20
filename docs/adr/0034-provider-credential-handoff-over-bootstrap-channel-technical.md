<a id="technical-depth"></a>
## Technical depth

Concept: [Provider credential handoff over the bootstrap channel](0034-provider-credential-handoff-over-bootstrap-channel.md#concept).

<a id="technical-adr-0034-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0034-provider-credential-handoff-over-bootstrap-channel.md#concept-adr-0034-decision).

### The channel and its frame

ADR 0019's launcher already opens one private channel per invocation: a
directory mode `0700` under the caller's temporary root, a Unix-domain socket
mode `0600` inside it, and a control pipe pair to the guard shell. Only the
parent VM and the one child ever hold either end, and both are removed when
the invocation's guard completes its cleanup.

The credential frame on that socket keeps the shape it has today. The codec
carries an eight-byte header — `LP`, version 2, a closed kind byte and a
length — and the `credential` kind admits exactly the two members `nonce` and
`credential`, with the credential a non-empty binary of at most 65,536 bytes
and the frame capped at 69,632. Nothing about the frame changes; what changes
is where its second member comes from.

### Ordering

The order is fixed and is the reason the credential is not folded into an
earlier frame:

1. The parent opens the namespace and the listening socket, then spawns the
   carrier and guard with `env -i` and a fixed `PATH`, passing the namespace,
   the nonce, the cleanup grace, the interpreter and worker paths, the socket
   path, the build manifest digest and the deadline as arguments. No
   credential is among them.
2. The parent writes `bootstrap:<nonce>:<grace>` on the control pipe; the
   guard answers `ready:<nonce>:<group>:<pid>:<namespace>` and execs the
   worker, again under `env -i`.
3. The parent accepts the socket and sends the `bootstrap` frame: nonce,
   codec version and build manifest digest.
4. The child answers with a `ready` frame that must equal that payload
   exactly. Until this point the child has proved nothing, and no credential
   exists anywhere in the invocation.
5. Only then does the parent send the `credential` frame, from a process
   spawned for that one send.
6. The `invocation` frame follows, carrying the request, its canonical bytes
   and its staged digest. Possible delivery begins here, not before.

A child that fails step 4 — a wrong manifest digest, a wrong nonce, a codec
version it does not speak, or a deadline that expires while it is still
booting — never reaches step 5. That is the property the two existing
bootstrap-refusal cases assert, and it is why the credential is not carried by
the step-3 frame.

### The token, the routing registry, and the custody process

**Where the token is bound, and what "per-invocation" qualifies.** The token
is bound at **composition**, per runtime, and what happens per invocation is
its **resolution**. That distinction is the whole of this section, and getting
it wrong would have made the decision unimplementable.

The seam admits nothing else. `complete/3` is called as
`module.complete(request, options, progress)`, with `options` taken from
`state.model.options` — the model configuration the runtime validated at
composition as `%{module:, model:, options:}` — and `request` is the closed
canonical projection a turn is staged into. There is no third place a caller
could put a value, and no per-call channel between the host and the adapter.
So a token "supplied with each call" has nowhere to arrive from.

The token therefore sits in `options`, beside the registry handle, and is the
same class as the executor `reference:` the runtime already takes and
`LoopexComposition` already fills with a live process reference. Its value is
a **struct**, not a binary:

```elixir
%Loopex.LLM.ReqLLM.CredentialToken{id: <<_::128>>}
```

— sixteen random bytes under a tagged name, carrying no structure the adapter
interprets and no authority of its own. It is not the credential, it does not
name a module, and it cannot be resolved by anyone not already holding the
host's registry. The registry **refuses anything that is not that struct**,
and an option carrying anything else is refused as invalid before any child is
spawned.

**A bare binary was the earlier shape, and it could not be validated.** That
revision called the token an opaque binary of at most 256 bytes from ADR
0023's alphabet and then said a bare binary "that could plausibly be bytes" is
refused — which is not decidable, because a credential *is* a bare binary and
many credentials are alphabet-clean and under 256 bytes. There is no content
test that separates a token from a secret. A struct separates them by type:
credential bytes never arrive as `%CredentialToken{}`, so the refusal is a
pattern match rather than a judgement, and a credential accidentally passed as
a token is refused at composition instead of being routed.

**One token per composed model configuration, bound at composition.** That is
the whole of what this decision fixes, and it is narrower than an earlier
revision claimed. A runtime composes **one** model configuration, its
`options` carry **one** token and **one** registry handle, and one custody
process holds the bytes behind it. There is no token collection, no
provider-selection seam and no per-call model `options` — `complete/3` takes
the composition-time configuration unchanged — so a design for two providers
would be describing a seam that does not exist.

**The per-provider generalisation is a stated future amendment**, not part of
this decision. When a second provider credential arrives, the registry's
routing-only contents make it a second row and a second token rather than a
widened value; that is the shape the generalisation will take, and it needs
its own amendment to this ADR because it needs the seam that would select
between them. ADR 0035, which is the decision that would bring one, says the
same thing from its side and is Proposed and deferred.

**Every later use of "per-invocation" in this pair qualifies the resolution.**
On each call the sender routes the token through the handle, receives the
custody process's reply, writes the frame and dies; the bytes exist in the
parent only in that process, only for that write. Two invocations resolve
independently and concurrently, and a rotation between them is visible to the
second.

**Why a per-runtime token is not the process-wide slot one level down**, which
is the obvious objection and deserves a direct answer rather than a
reassurance. The slot this decision removes was the VM's environment: one
global location, shared by every runtime in the VM, holding the **bytes**, and
read inside each call so that whichever invocation wrote last determined what
every concurrent invocation sent. A token in `options` is none of those. It is
per runtime, so two runtimes in one VM carry **different tokens routed through
different handles to different custody processes** — the isolation proof this
pair requires. It is not global, because nothing looks it up by name. And it
holds **no bytes at any time**: it is an identifier whose resolution is a call
to a process the host owns. The property that made the environment variable
wrong — concurrent work in one VM unable to carry distinct credentials — is
exactly the property this arrangement restores, now at the granularity that
matters: two *runtimes* in one VM carry different credentials, where the
environment variable gave them one slot between them.

Nothing carries `options` into a durable or observable plane, which is worth
confirming rather than assuming: the model span is built from a fixed identity
map of `session_id`, `run_id`, `attempt`, `model` and `provider`, and no
journal record, public event or snapshot contains the model configuration.

The token replaces the `{resolver_module, reference_term}` pair an earlier
draft used. The maintainer decided that on 2026-09-20. A pair that named a
module was doing two jobs at once: it carried routing (which process answers)
in the same value that travelled through adapter configuration, so every
copy of that configuration disclosed the shape of the host's credential
arrangement, and adding a second provider would have meant widening the value
rather than adding a row. An opaque token discloses nothing and is the same
size whatever the host is doing behind it.

**The routing registry is the host's, and holds routing only.** The host
composes a registry that maps token to custody process, and that is the whole
of its contents: no credential bytes, no derived material, nothing from which
a secret could be reconstructed. It is the indirection that lets the token be
opaque. The sender resolves the token through the registry to reach the
custody process; the registry itself never sees or holds a credential, so
reading it discloses which tokens exist and nothing about what they stand
for.

**How the sender reaches it, given what `complete/3` actually receives.** The
callback takes three arguments and no more — `module.complete(request,
options, progress)` is the exact call the coordinator makes — so a token in
the per-invocation configuration names *which* credential but says nothing
about *where* to ask. Those are two different things and this pair keeps them
separate:

- **The registry reference is a per-runtime capability, carried in
  `options`.** The model configuration a host composes is
  `%{module:, model:, options:}` with `options` a keyword list the runtime
  validates and hands to `complete/3` unchanged, so it is the seam that
  already exists for exactly this: something the host decides once, per
  runtime, that every invocation needs. Composition puts the registry
  reference there, under its own key, beside the token — which composition
  also puts there, once, for the one model configuration this runtime has. An earlier sentence said
  the caller supplies the token "per invocation"; that contradicted this
  pair's own binding rule and is corrected: what happens per invocation is the
  **resolution**, never the supply.
- **It is a runtime-local capability handle, exactly the class the runtime
  already takes.** The precedent is the executor: `Loopex.Runtime`'s executor
  configuration carries `reference:`, and `LoopexComposition` fills it with
  the live pid `start_edge/2` returned. That reference is composition data,
  never durable and never public, and it is what the runtime hands the
  adapter at dispatch. The credential registry handle is the same class and
  is written the same way — `%Loopex.LLM.ReqLLM.CredentialRegistry.Handle{}`
  wrapping that live reference, so the value is self-describing at a glance
  and cannot be mistaken for anything else in an options list.

  An earlier draft made it a *runtime-scoped registered name*. That is
  withdrawn: a registered name on the BEAM is VM-global whatever it is called,
  so two runtimes in one VM would be one namespace with a convention holding
  them apart, and a convention is not isolation. A handle carrying a live
  reference is scoped by who holds it, which is the property actually wanted.
- **The boundary rule is respected because of where it lives, not because of
  what it is.** The rule keeps PIDs out of durable and public data; a handle
  in composition data is neither, exactly as the executor's `reference:` is
  neither. It is never journaled, never in a public event or snapshot, never
  on the wire, and never in a token.
- **Two runtimes are isolated by construction.** Each host composes its own
  registry and holds its own handle; a token from one runtime presented in
  the other reaches a registry that has no row for it and answers
  `:unavailable`. That is a required proof, not an assertion: two hosts, two
  registries, two tokens, and neither token resolves in the other's runtime.
- **The lookup is one operation, and it is the host's.**
  `route(handle, token) -> {:ok, custody_ref} | {:error, :unavailable}`, a
  call to the registry process. It returns *where to ask*, never bytes;
  `:unavailable` covers a token with no row and a registry that is gone —
  from the sender's side those are one fact, and neither is recoverable by
  asking again.

  **A registry that is merely slow is not one of them**, and an earlier
  revision blurred the two by putting "does not answer" in this list. Silence
  is the guardian's business: the sender's lookup has no deadline of its own,
  the **invocation deadline** bounds the whole resolution, and a registry that
  has not answered when it expires produces the guardian's `:timeout` with the
  sender killed — which the closed reason set already distinguishes from every
  refusal, precisely so an operator can tell a refusal from a silence. A
  registry that is *gone* answers immediately, because the call fails rather
  than waits, and that is `:unavailable`.
- **Every wait on the registry and on custody is deadline-free, because the
  guardian owns the only deadline.** Both are `GenServer` calls, and a
  `GenServer.call/2` carries a hidden five-second default that would sit
  *inside* the invocation deadline and expire first — producing a refusal the
  guardian never decided, at a time nobody chose. So the sender calls both
  with `:infinity` (or an equivalent deadline-free protocol) and the guardian
  kills it at the invocation deadline, reporting `:timeout`. One deadline,
  owned by one process, is the whole rule; a blocked registry is therefore a
  `:timeout` from the guardian and never a silent five-second refusal.
- **Its lifetime is the host supervisor's, and a restart invalidates the
  handle.** The host starts the registry under its own supervisor when it
  composes the runtime. **Exactly which supervisor, per host:** `RuntimeOwner`
  for the reference CLI and for the app-server host, which is the process that
  already owns their composed edges; the **daemon's owner process** for the
  daemon, which links the registry and the custody process as fixed
  components. In all three the normal path stops them with the rest of the
  composition, a failed start unwinds them in the same reverse cleanup as any
  other started edge, and the owner's own death takes them with it — they are
  linked, so there is no path on which they outlive the host that composed
  them. If the registry dies, the handle a composed runtime
  holds is invalid and every resolution through it answers `:unavailable`
  **until the host recomposes** — the adapter does not re-look-up, does not
  wait and does not rebuild, because it has nothing to rebuild from. That is
  the same shape as losing custody, and it is deliberate: recomposition is the
  one repair, and it is the host's to perform.

**Custody is a separate process, and is where the bytes live.** Each reference
implementation states and proves its own: the reference CLI, the app-server
host and the M5 daemon read `Loopex.LLM.ReqLLM.credential_variable/0` exactly
once, where they compose the runtime, delete that name from the VM's
environment in the same step, hold the bytes in one host-owned custody process
registered under the runtime reference rather than a global name, whose
`format_status/1` redacts its state, and register its token in the routing
registry. The real-provider lane composes the same way. Nothing in the adapter
depends on that arrangement, and a different host may keep the bytes anywhere
it can defend.

**Loss of either is `:unavailable`, and neither is reconstructed.** If the
custody process is gone, or the registry has no row for the token, or the
registry itself is gone, resolution answers `:unavailable` and the invocation
refuses. The adapter does not retry, does not fall back, and above all does
not attempt to rebuild the secret from anything — there is nothing to rebuild
it from, by construction, because the registry holds no bytes. The host
recomposes; until it does, every invocation on that token refuses the same
way. That is the whole recovery story, and it is deliberately the shortest one
available: a mechanism that could restore a credential after its custodian
died would be a mechanism that had kept a second copy somewhere.

**Exactly one credential-bearing transfer exists in the parent, and it is
named.** An earlier draft said the value never appears in a message while also
putting custody in a long-lived process the sender asks — which cannot both be
true, because answering is a message. The contract is a permission with a
boundary, not an absolute:

- The **only** permitted credential-bearing transfer in the parent is the
  custody process's reply to the sender's `resolve` call, carrying
  `{:ok, %{credential: bytes}}` — **keyed**, for the redaction reason below —
  to the one sender process that asked. It is bounded by the
  same 1..65,536-byte rule as the frame, it is never logged, never forwarded,
  and never held after the frame is written. The registry lookup that precedes
  it carries no credential, so the token's journey through the registry adds
  no second place a secret can be seen.
- It is deliberately the same class of act as the credential frame write: one
  short-lived process receives the bytes, uses them once, and dies. ADR 0019
  already protects that process — the sender installs its own group-leader
  sink so no IO request can carry anything out of it, it is unregistered, and
  it reports only an atom or a `{:error, atom}` pair to the guardian.
- **What keeps credential bytes out of a trace: one core call that does two
  things.** ADR 0030 requires the key-bearing call to be excluded by match
  specification *before* delivery (`0030-…-technical.md:33-35`). That is
  necessary and it is not sufficient, and this pair states both halves
  together rather than replacing one with the other:

  **A match specification alone cannot hold, because a function that carries
  the credential calls functions it does not own.** `ProviderCodec.send/3`
  hands the encoded credential frame to `:gen_tcp.send/2`; a trace session
  that names `:gen_tcp` explicitly sees the frame, whatever this adapter's
  own functions are excluded. Reproduced, with a canary standing in for the
  credential:

  ```
  :trace.function(session, {:gen_tcp, :send, 2}, true, [:local])
  # tracer receives:
  {:trace, #PID<0.97.0>, :call, {:gen_tcp, :send, [#Port<0.4>, "FRAMECANARY-SECRET-42"]}}
  ```

  Excluding `:gen_tcp` would not close it either: the next callee down, or a
  future one, is outside the list again. An enumeration of callees is not a
  contract anyone can keep.

  **So the core API takes both, and the adapter supplies the function list.**
  The sender — the short-lived process that resolves the credential and writes
  the frame — calls, **before it resolves anything**:

  ```elixir
  Loopex.Trace.exclude_self(capability, functions: [{module, function, arity}])
  ```

  One call, two inputs, one core change. Core installs **both**: the
  match-specification clear for each named `{module, function, arity}`, after
  the module pattern, exactly as ADR 0030's sentence describes; and the
  process flag for the caller, which is what reaches the callees a match
  specification cannot name.

  **The adapter supplies its own MFAs, and that is what keeps the dependency
  direction intact.** Core never names an adapter function — it takes a list
  from the caller and installs it — so nothing in `loopex` knows that
  `Loopex.LLM.ReqLLM.ProviderBridge` exists. The inventory of key-bearing
  functions belongs to the component that has them, which is this adapter, and
  it is listed below.

  It returns `:ok` once the caller is excluded from **every** live trace
  session and recorded as excluded for every future one. Only then does the
  sender route the token, receive the credential and write the frame. Nothing
  the sender does after that point can appear in a trace, whatever modules or
  functions a host names — including `:gen_tcp`, including modules nobody has
  thought of.

  **The process half, probed at both toolchain pairs before it was written
  down.** A process flagged by inheritance (`:set_on_spawn` from a traced
  parent) calls `:trace.process(session, self(), false, [:all])`; the call
  returns `1`, the flags are gone, and its subsequent `:gen_tcp.send/2` with
  the canary produces **no trace message at all**, while a non-excluded
  control process's identical call produces one. There is no message for a
  sink to redact — which is the property ADR 0030 asks for, reached for the
  callees as well as for the named calls.

  **The VM does not make it sticky, and neither the tracer nor a pid in
  options can hold it.** The same probe shows a later
  `:trace.process(session, pid, true, …)` re-enabling the process, so the
  exclusion cannot be left to the BEAM. Two further facts decide where it
  lives, and both contradict an earlier revision of this pair:

  - **A tracer pid cannot be an option.** The tracer is the runtime
    supervisor's **last** child (`runtime/supervisor.ex:87`), while model
    options are built before the runtime starts — so at the moment the option
    would be filled there is no tracer to name. Core itself never holds a
    tracer pid either: `Loopex.Runtime.trace/2` resolves it **dynamically**
    through `RuntimeSupervisor.children/1` on every call (`runtime.ex:343-345`).
  - **A tracer pid would not survive a restart.** The supervisor's strategy is
    `:rest_for_one` (`runtime/supervisor.ex:92`) and the tracer is last, so a
    tracer crash restarts the tracer **and nothing else** — a new pid, and
    every earlier child, including `Control`, still alive.

  So the exclusion is reached through a **capability**, and remembered in a
  process that outlives the tracer:

  - **The capability is a host-owned process reference in model options**, the
    same class as the credential registry handle beside it and as the
    executor's `reference:`. The host starts it before composition, as it
    already starts the registry and the custody process, and hands it the
    runtime reference as soon as the composition function returns one. It
    holds no membership and makes no decision; it exists because options are
    built before the runtime and something has to bridge that order.
  - **Membership lives in `Loopex.Runtime.Control`**, chosen by reading the
    tree rather than by preference: it is the runtime supervisor's **second**
    child (`runtime/supervisor.ex:70`), so under `:rest_for_one` it survives
    every tracer restart; it already holds per-runtime process state; and it
    already monitors pids and handles `DOWN` (`control.ex:805-826`), which is
    the exact machinery the set needs.
  - **The set is bounded because Control monitors every excluded sender and
    removes it on `DOWN`.** An earlier revision kept a pid per invocation
    forever, which is a leak measured in invocations; senders are short-lived
    by construction, so the set returns to its baseline — normally empty —
    as they exit.
  - **A new trace session consults the set.** When the tracer starts a session
    it skips every pid Control holds, the same place `excluded?/3` already
    excludes the tracer and the dispatcher by role (`trace.ex:411`), and a
    tracer that has just restarted asks Control rather than starting empty.
  - **A `Control` restart is the one gap, and the claim is qualified rather
    than repeated.** `Control` is a `:permanent` child under `:rest_for_one`
    (`runtime/supervisor.ex:69-72`, `:92`), so its restart clears the set —
    and also restarts every child after it, the tracer included, which ends
    every live session. What that means precisely: the **process flags already
    installed on live sessions persist**, being state in the VM's trace
    sessions rather than in `Control`; only sessions started **after** the
    restart consult the set, and those find it empty. A sender that resolved
    before the restart is therefore still excluded for the session it was
    excluded from, and a sender that starts after it excludes itself again, as
    every sender does. The remaining case is a sender whose `exclude_self/2`
    call **finds `Control` unavailable** — mid-restart — and that one fails
    closed like any other unconfirmed exclusion: it refuses the invocation
    rather than resolving. So the absolute form — "no trace configuration can
    name it back in" — holds for configuration, which is what it is about, and
    the plan does not extend it to a supervision event that ends the sessions
    anyway.

  **It fails closed.** `exclude_self/2` returns only once both exclusions are
  installed, and it carries an **explicit** bound rather than inheriting a
  `GenServer.call` default — a hidden five seconds here would be a silent
  deadline inside the invocation's, exactly the fault the registry and custody
  calls avoid by waiting deadline-free. Here a bound is correct where there it
  was not, because the safe answer to "I cannot confirm the exclusion" is to
  refuse rather than to wait. If the capability is present but the exclusion cannot be
  installed — a tracer restarting in that instant — the sender **does not
  resolve the credential**: the invocation refuses with `:unavailable`, the
  atom the closed set already carries for "the arrangement needed to resolve
  is not there", and the caller retries as it would for any other
  `:unavailable`. The alternative, proceeding untraced-but-unexcluded, would
  be the one case where a credential is resolved in a process a session may be
  tracing.

  **Only an explicitly absent capability proceeds.** Where the host composed
  no tracing capability at all, there is no tracer and no session, so nothing
  can trace and the sender resolves normally. Absent is not the same as
  unreachable, and the two are distinguished at composition rather than at
  the call.

  **The MFAs this adapter supplies, exactly three.** They are the functions
  that hold the resolved bytes or the token, and the list is passed to
  `exclude_self/2` by the adapter itself:

  | MFA | What it holds |
  | --- | --- |
  | `Loopex.LLM.ReqLLM.ProviderBridge.route_credential/2` | The registry handle and the token |
  | `Loopex.LLM.ReqLLM.ProviderBridge.receive_custody_reply/2` | The resolved credential |
  | `Loopex.LLM.ReqLLM.ProviderBridge.write_credential_frame/2` | The resolved credential |

  Three, not two: `route_credential/2` carries the token, which the closed
  reason set treats as credential-adjacent and which this pair refuses to put
  in a trace entry either. The same three are named wherever this set counts
  them.

  **What each half buys, so neither is mistaken for the other.** The match
  specification stops those three producing a raw message at all, which is
  what ADR 0030 asks for by name. The process flag stops everything they call
  — `ProviderCodec.send/3`, `encode/2` and its private path, `:gen_tcp.send/2`,
  and whatever a future codec calls beneath them — which a match specification
  cannot reach, because it names functions and the leak is through callees.
  Neither is sufficient alone, and the module-wide exclusion of
  `ProviderCodec` an earlier revision proposed is dropped: the process flag
  covers its calls without costing every other frame's tracing.

  **What is kept as defence in depth**, explicitly labelled so nobody mistakes
  it for the mechanism: the **keyed shape**. The three bridge functions carry
  credential bytes only as a value under a credential-named key —
  `receive_custody_reply/2` returns `{:ok, %{credential: bytes}}` and never
  `{:ok, bytes}`; `write_credential_frame/2` takes that keyed map — so a
  credential that somehow reached `Entry.render/2` would be placeholdered at
  any size. It protects nothing about callees, and it is not what satisfies
  ADR 0030.

  **The proof is three cases, and the first one is the one that would have
  caught the old design.** A trace session is configured to name
  **`:gen_tcp`** explicitly, alongside `ProviderBridge` and `ProviderCodec`,
  and a real invocation runs with a **one-byte canary** as the credential. The
  case asserts the tracer receives **no raw trace message from the sender
  process at all** — not for `:gen_tcp.send/2`, not for any function — while a
  non-excluded control process performing the same `:gen_tcp.send/2` in the
  same session **does** produce one, so the case cannot pass by tracing
  nothing. The canary appears nowhere in any captured message or entry.

  The second is the default configuration: no module naming, and no entry, no
  raw message and no credential byte anywhere — the adapter is in no namespace
  wildcard, because `modules/1` expands `:loopex` and `:loopex_protocol`
  through `:application.get_key(application, :modules)` and
  `Loopex.LLM.ReqLLM.ProviderBridge` lives in `loopex_llm_reqllm`.

  The third is the ordering: `exclude_self/2` is asserted to return **before**
  the token is routed, and a session started concurrently with it is asserted
  to produce no message from the sender either way round.

  Three more cover what the capability is for. **A tracer restart keeps the
  exclusion**: the tracer is killed, the supervisor restarts it, a new session
  starts, and a sender that excluded itself before the restart is asserted to
  produce no message under the new session — which a design holding a tracer
  pid in options would fail. **The set returns to baseline**: after a run of
  invocations, the excluded-pid set `Control` holds is asserted empty again,
  proving the monitors remove what the senders left. And **it fails closed**:
  with the tracer made unavailable at the instant `exclude_self/2` is called,
  the invocation is asserted to refuse `:unavailable` and **no credential is
  resolved**, while a composition with no tracing capability at all is
  asserted to resolve normally.
- Everywhere else the earlier absolutes stand unchanged: not in guardian
  state, not in an exit reason, not in a crash report, not in an IO request,
  not in a file, not in the environment, not in argv, and in no durable or
  public plane.

**When it is resolved.** Exactly once per invocation, inside the sender
process, between the child's `ready` frame and the credential frame — step 5
above and nowhere else. A resolved value is never cached, never reused for a
second invocation, and never returned to the guardian.

**Rotation.** Per invocation, by construction: the custody process may answer
different bytes for the same token on a later call, and no layer holds a
previous answer to contradict it. The host may also rotate by pointing the
token's registry row at a new custody process, which the next invocation
follows and an in-flight one does not. A rotation that happens while an invocation
is in flight does not reach that invocation, which has already resolved; it
reaches the next one. Nothing is invalidated and no invocation is restarted.

**The guardian enforces the deadline, not the resolver.** Resolution is
bounded by the invocation's existing deadline and by nothing else; this
decision adds no second clock and, after the maintainer's decision of
2026-09-20, it does not ask the resolver to honour one either. The callback
takes no deadline argument. The guardian already owns the invocation deadline
and already supervises the sender, so it bounds the whole resolution — the
registry lookup, the call, and the wait for a reply — and kills the sender
when the instant is reached, reporting `:timeout`.

An earlier draft passed an absolute monotonic instant to the resolver and
relied on it to answer in time. That is withdrawn: it made every host's
resolver responsible for a safety property the adapter must have whatever the
host wrote, and a resolver that simply blocked would have hung the invocation
past its deadline. Enforcement belongs to the process that can act on it by
killing something. The resolver's only obligation is to answer or not.

**The closed reason set, complete.** Every way resolution can fail maps to one
of seven atoms, and the set is closed in both directions: nothing else is
produced, and nothing else is accepted.

| Atom | Produced by | For |
| --- | --- | --- |
| `:no_token` | The adapter | The configuration carries no `:credential_token` at all |
| `:invalid_token` | The adapter | A `:credential_token` that is not a `%Loopex.LLM.ReqLLM.CredentialToken{}` struct with a 16-byte `id`, refused before any lookup |
| `:missing` | A custody process | It has no credential for this token |
| `:expired` | A custody process | It has one and considers it no longer valid |
| `:oversized` | The sender | A successful reply whose bytes fall outside 1 to 65,536 |
| `:unavailable` | The registry or a custody process | A missing registry row, a gone registry, a dead custody process, a custody process that answers `:unavailable`, or **a successful reply that is malformed** — not `{:ok, %{credential: binary}}`, including a bare binary where the keyed map is required — because a reply the sender cannot read, or reads in a shape the redaction pass does not protect, is not a credential it can send |
| `:timeout` | The guardian | Resolution had not completed when the invocation deadline was reached |

An earlier draft left the first two unnamed and folded a malformed successful
reply nowhere at all, which meant three real failures had no atom to carry.
Anything returned outside this set is treated as `:unavailable`, because a
host-authored term is exactly where a secret could be smuggled into a reason.
All seven atoms carry no content, so they are safe in a message, an exit
reason and a bounded diagnostic.

**They are internal diagnostic classes, not a new public result shape.** The
seven live inside the adapter and in what the guardian records; the value
`complete/3` returns to the coordinator keeps the **existing `Loopex.Model`
refusal shape**, unchanged by this decision. A host that pattern-matches on
the adapter's result today matches the same shapes afterwards, and the atom is
what the bounded non-secret diagnostic says happened rather than a second
return contract to learn. Widening the callback's result would be a change to
an accepted port, which this decision explicitly does not make.

**What the sender reports.** `:ok` or `{:error, reason}` from that same closed
set, never a bare `:error`. The guardian has to distinguish a custody process
that refused from one that never answered — they are different operational
faults and ADR 0029's bounded status has to say which happened — and it can,
because a refusal arrives as one of the six atoms produced below the guardian
— `:no_token` and `:invalid_token` from the adapter, `:missing` and
`:expired` from a custody process, `:oversized` from the sender, and
`:unavailable` from the registry or custody — while a silence is the
guardian's own `:timeout`, the seventh. The reported reason is never the resolved value,
the token, or a host-authored string.

**Failures.** Each is a refusal with a bounded non-secret reason, and each
leaves no retained copy of anything the resolver may have produced:

| Condition | Outcome |
| --- | --- |
| No `:credential_token` in the configuration | `:no_token`, refused before the namespace is created and before any child is spawned |
| Malformed token — anything that is not a `%CredentialToken{}` struct with a 16-byte `id`, a bare binary included | `:invalid_token`, refused before any lookup and before any child is spawned. The struct is what makes this decidable: a credential is a bare binary, and no content test separates one from a token |
| A successful custody reply that is malformed — not `{:ok, %{credential: binary}}`, a bare binary included | `:unavailable`; a bare binary is refused rather than accepted, because accepting it would carry bytes in a shape the redaction pass leaves verbatim below 65 bytes |
| The registry holds no row for the token, the registry is gone, or the custody process is dead | `:unavailable`. The host recomposes; nothing is reconstructed, because the registry holds no bytes to reconstruct from |
| Custody answers `{:error, :missing}` or `{:error, :expired}` | The sender reports `{:error, that_atom}`; the invocation fails through ADR 0019's existing credential-send failure path, the guard tears the child down, and the atom becomes the bounded non-secret status ADR 0029 fixes |
| Custody answers `{:error, :unavailable}`, or anything outside the closed set | The same path, reported as `:unavailable` |
| Resolution has not completed when the guardian's invocation deadline is reached | The **guardian** kills the sender and reports `{:error, :timeout}`, distinct from every refusal; the sender's stack goes with it. A custody process that simply blocks cannot hang the invocation, because nothing depends on it noticing the time |
| Resolved value outside 1 to 65,536 bytes | Refused in the sender before the frame is written, exactly as the size check refuses today, reported as `{:error, :oversized}` |
| Two resolutions in flight at once | Independent **successes**. Each invocation has its own sender and resolves for itself; the adapter serialises nothing and shares nothing between them, and two answers for the same token may differ. Concurrency is not a refusal condition, and a custody process that refused concurrent callers would reintroduce exactly the serialisation this decision exists to remove |

No failure is retried inside the adapter. Whether to attempt again is the
coordinator's durable decision under ADR 0018, unchanged.

### Scrub points

- **In the sender.** The minimal credential sender keeps the shape it has
  today: it is spawned for this one send, it installs its own group leader
  sink so no IO request can carry anything out of it, it looks the token up in
  the host's routing registry, calls the custody process it names, receives the
  one permitted credential-bearing reply, validates the size bound, writes the
  frame itself and reports `:ok` or `{:error, reason}` from the closed set to
  the guardian — which is supervising it against the invocation deadline
  throughout. Its closure holds the token, never the resolved value; in the
  parent the value exists in the custody process and,
  for the duration of one send, in this process's own mailbox and stack, and
  nowhere else — no guardian state, no exit reason and no crash report can
  hold it.
- **In the parent's environment.** The adapter performs no *credential*
  environment read by any route. That is the property this decision owns, and
  it is narrower than "no environment read at all" on purpose.
  `Loopex.LLM.ReqLLM.credential_variable/0` remains as the one name the *host*
  reads when it composes a runtime — the reference CLI at start, and the
  real-provider lane when it names the variable in its own failure message —
  and the host deletes that name once it has read it. `ProviderBridge`, which
  holds the sender and the whole credential path, reads no environment
  variable at all.

  `ProviderLauncher.spawn_environment/0` keeps its launch-time
  `System.get_env/0` enumeration, and keeps it exactly where it is. The
  maintainer decided this on 2026-09-20, reversing an earlier draft of this
  pair that deleted the enumeration in favour of a fixed closed removal list,
  and an earlier one still that moved the snapshot to composition. Both are
  withdrawn, and the reason is that the enumeration is not part of the
  credential plane at all — it is ADR 0019's scrubbing, and ADR 0019 is
  accepted.

  What it does: at each launch it reads the live environment so the Port can
  remove every name in it, plus the unconditional `@excluded` credential and
  loader names, from the first spawned image. That image is `/usr/bin/env`
  itself, whose environment `env -i` does not clear, so without the
  enumeration an unlisted name introduced after some earlier snapshot would
  reach it. A fixed list cannot have that property, because the set of names
  present is not known until the launch. Reading it at launch, per launch, is
  what makes ADR 0019's first-image scrubbing true rather than approximately
  true, and it needs no amendment to ADR 0019 because it is ADR 0019's own
  design left alone.

  The line this decision draws is therefore between *a credential read* and
  *an environment read*. The launcher's read is never consulted for a
  credential: it does not look up the credential name, it does not pass a
  value anywhere, and every name it finds it uses only to remove. The proof
  below asserts that directly rather than inferring it from the absence of
  reads.

  One measurement is retained from the withdrawn design, because it is a fact
  about the platform rather than about the design: `Port.open`'s `{:env, …}`
  option **merges** into the inherited environment and does not replace it. A
  probe on this toolchain spawned `/usr/bin/env` with
  `{:env, [{~c"PATH", …}]}` and the first image still received all 67 of the
  parent's names, including a planted sentinel. That is why removal is name by
  name, and therefore why the enumeration exists.
- **In the child.** Unchanged: the child receives the credential on the socket
  and nowhere else. Its environment at entry is the fixed `PATH`, `LANG`,
  `LC_ALL` and the two crash-dump suppressions, and ADR 0029's bounded
  non-secret status is still the only failure information that leaves it.

### Proofs

Every case below exists today in
`apps/loopex_llm_reqllm/test/credential_plane_test.exs`. Each is re-pointed at
the per-invocation token — the module's `setup` and the two rotation cases
stop writing the process-wide variable, and each fixture composes its own
custody process and registry row — and each must hold with its assertion unchanged in meaning:

| Claim | Case |
| --- | --- |
| Version refusal before any credential | `actual version two companion refuses version one bootstrap before readiness or credential` |
| Bootstrap refusal before any credential | `invalid protected bootstrap cannot receive a credential or dispatch` |
| Late delivery after expiry is impossible | `expired bootstrap cannot deliver a credential later or relaunch` |
| Rotation between invocations | `a child transport raise after environment rotation cannot expose its request credential` |
| Two live credentials in one VM | `one child diagnostic containing two concurrently live synthetic keys cannot escape` |
| Sink loss | `loss of child diagnostic protection cannot leak its credential` |
| One child's loss does not poison another | `losing one credential-bearing child does not poison another invocation or host logs` |
| Nothing in ordinary host messages | `ordinary guardian messages and results never carry its credential` |
| Returned reasons | `a provider error echoing the key is substituted before it is returned` |
| Child Logger forms and metadata | `ordinary and split actual child Logger messages cannot expose the credential`, `all actual child Logger message forms and metadata stay private`, `repeated credential bytes in actual child metadata cannot reach host channels`, `credential-bearing child metadata keys cannot reach host channels` |
| Crash reports | `a provider request adapter that throws cannot put the credential in a stream-server crash report`, `a provider request adapter that exits cannot put the credential in a stream-server crash report`, `an actual child report containing its own request credential stays private`, `an actual child StreamServer termination cannot forward its credential` |

Two of those cases also carry the child-environment witness, and it survives
the re-pointing unchanged: the version-refusal case at
`credential_plane_test.exs:117` and the bootstrap-refusal case at `:567` each
read the child's recorded `entry-env` marker and refute
`Adapter.credential_variable()` in it. Both assertions stay exactly as they
are and mean more afterwards, because the name they refute in the child is by
then absent from the parent as well. The child-environment conformance case in
`apps/loopex_llm_reqllm/test/m0_child_environment_conformance_test.exs` is a
different proof and is untouched by this decision: its sentinel
`LOOPEX_M0_CHILDENV_PARENT_ONLY` is synthetic, so what it proves is that no
parent environment name at all reaches the child, not anything about the
credential name.

One case outside `credential_plane_test.exs` must be re-pointed too, and
cannot carry over unchanged. The size-bound case in
`apps/loopex_llm_reqllm/test/provider_retainer_boundaries_test.exs`, which
drives the 65,536-byte ceiling, delivers its credential through
`System.put_env(Adapter.credential_variable(), …)` in that module's `setup`
and again in the case body. Both writes go: the module's fixtures carry their
own custody, and the case has that invocation's custody process hold the
65,536-byte value rather than writing it into the VM. The ceiling it
proves, and the refusal above the ceiling, are unchanged.

Three proofs are new:

- **Parent environment**, stated as two checkable things rather than one
  unfalsifiable one. From the completion of composition onward — before,
  during and after a call — **the configured credential name is absent from
  the parent VM's environment**, and **no function in the adapter's call path
  reads the environment for a credential**. "During" is observed from inside
  the call, at the point the child reports readiness. The case composes the
  runtime the way a reference host does, with the variable set, and asserts
  that composition returns having deleted it.

  An earlier revision also asserted that no environment value **equals** the
  credential in use, which is a different and much weaker claim than it
  sounds: it scans values the test cannot enumerate ahead of time, it would
  fail for a host that legitimately keeps the same secret under a second name
  of its own, and passing it proves nothing about where the adapter looks.
  The two assertions above are what the decision actually rests on, and the
  drift-protection case is what enforces the second.
- **Independence across runtimes.** Two runtimes composed in one VM, each
  with its own registry, custody and token, run invocations at once; each
  child records only its own credential, and neither child — nor either
  child's diagnostics — ever sees the other's. It is stated across *runtimes*
  rather than across invocations because a composition-bound token makes the
  within-one-runtime form vacuous: two invocations of one runtime necessarily
  carry the same token. Their independence is a corollary of this case, not a
  separate witness.
- **No credential environment read in the adapter's lib tree.** The existing
  drift-protection case in `apps/loopex_llm_reqllm/test/adapter_test.exs` —
  `the adapter reads exactly one credential environment variable` — pins the
  exact `System.get_env` arguments per library file, including
  `"provider_bridge.ex" -> ["\"LOOPEX_PROVIDER_API_KEY\""]` and
  `"provider_launcher.ex" -> [""]`, the arity-zero enumeration. That case must
  survive, strengthened rather than deleted, and the allowlist it ends with is
  exact:

  | File | Expected reads | Why |
  | --- | --- | --- |
  | `provider_bridge.ex` | `[]` | The credential path reads no environment variable at all; this is the read the decision removes |
  | `provider_launcher.ex` | the arity-zero enumeration, and only that | ADR 0019's first-image scrubbing, which stays. It is not a credential read |
  | `provider_worker.ex` | its two non-secret crash-dump names | Unchanged |
  | every other file | `[]` | Unchanged |

  So the claim the case proves is "**no credential** environment read in the
  adapter's library tree", not "no environment read at all". The maintainer's
  decision of 2026-09-20 draws it there, and the earlier draft that expected
  `[]` for the launcher too is withdrawn with the deletion it belonged to.

  Because the launcher's read survives, the case carries one more obligation
  than a count: it must show that read is **never consulted for a credential**.
  Pinning an argument list cannot show that on its own, so the case asserts
  the use as well as the read — the enumeration's result flows only into the
  Port's removal list, every name it yields is mapped to `false`, no name it
  yields is compared against `credential_variable/0`, and no value it yields
  reaches the sender, the frame or any caller. A refactor that started reading
  a credential out of that enumeration would fail there.

  Its scan is widened from one regular expression over `System.get_env(...)`
  to every route by which an environment read can be written:
  `System.get_env/0` and `/1`, `System.fetch_env/1` and `fetch_env!/1`,
  `System.get_env/2`, `:os.getenv/0`, `/1` and `/2`, `:os.env/0`, and indirect
  application of any of them through `apply/3` or a captured function. Each
  route the allowlist does not name is refuted outright. The narrow scan is
  what lets an environment read return by a name the current expression does
  not match, which is the drift the case exists to catch.
- **Resolution failures.** One case per row of the failure table above:
  absent token, malformed token, a token with no registry row, a gone
  registry, a dead custody process, each of the four refusal atoms, a custody
  process returning a term outside the closed set (reported `:unavailable`), a
  custody process that blocks past the invocation deadline (the **guardian**
  kills the sender and reports `:timeout`, asserted **distinct** from every
  refusal so the guardian can tell them apart, and asserted to bound the
  invocation whatever the custody process does), and a value outside the size
  bound. Each
  asserts the outcome, its closed-set atom, that no child was spawned where
  the contract says none is, and that no message but the permitted reply, no
  exit reason and no crash report carries the resolved value. The
  two-resolutions-at-once case is a **success** case, not a refusal: both
  invocations complete with their own credentials.
- **Tracing, in two cases matching the two tiers above.** Under the
  **default** trace configuration, a session at the `arguments` level over a
  real invocation produces no entry naming `route_credential/2`,
  `receive_custody_reply/2` or `write_credential_frame/2`, no raw trace
  message for them, and no credential bytes or token anywhere — because the
  adapter is in no namespace wildcard. Under a configuration that
  **explicitly names `:gen_tcp`**, `Loopex.LLM.ReqLLM.ProviderBridge` and
  `Loopex.LLM.ReqLLM.ProviderCodec`, the tracer is asserted to receive **no
  raw trace message from the sender process at all**, while a non-excluded
  control process making the same `:gen_tcp.send/2` call in the same session
  is asserted to produce one — the pre-delivery property read where it holds,
  and a case that cannot pass by tracing nothing. A third case asserts the
  three functions exist with their exact identities and that a one-byte
  canary credential appears in no captured message or entry, so neither of the
  first two can pass vacuously.
- **The host-owned processes, proved at each host rather than in the adapter.** The
  adapter's test tree cannot prove a claim about the CLI's or the daemon's
  composition, and an earlier draft filed all three there. Each case lives
  where its subject lives, named to the file and the case so the closure
  matrix can be checked against a list rather than a directory:

  | Host | File | Cases | Lane |
  | --- | --- | --- | --- |
  | Reference CLI | `apps/loopex_cli/test/credential_custody_test.exs` | `reads the credential variable exactly once at composition`; `deletes the credential variable from the VM environment`; `custody state is redacted in a forced crash report`; `the tracing capability is composed and reaches the current tracer` | fast |
  | App-server host | `apps/loopex_app_server/test/credential_custody_test.exs` | the same four | fast |
  | Daemon | `apps/loopex_daemon/test/credential_custody_test.exs` | the same four, plus `registry, custody and capability are stopped with the daemon and on a failed start` | fast |

  Each proves that composition reads the variable exactly once, deletes it
  from the VM's environment, and that the holding process's `format_status/1`
  redacts its state under a forced crash report. The adapter's own tree keeps only what is the adapter's
  to prove: that it reads no environment variable for a credential and that
  the token and resolution contract behaves.

The parent-environment and concurrent-independence proofs and the resolution
failure cases belong in `credential_plane_test.exs` beside the cases they
generalise; the drift case and the trace-exclusion case stay in the adapter's
tree with it. The **host-owned-process cases do not**: each lives at its own host,
as the bullet above assigns them — `apps/loopex_cli/test/`,
`apps/loopex_app_server/test/` and `apps/loopex_daemon/test/` — because the
adapter's tree cannot prove a claim about another application's composition.
An earlier draft assigned them correctly and then took it back two lines
later; this is the assignment that holds.

Two details of that case matter to whoever writes the change. The literal
`"LOOPEX_PROVIDER_API_KEY"` it pins today lives in
`provider_bridge.ex:401`, inside the credential sender, while
`credential_variable/0` and its module attribute live in `req_llm.ex:49` and
`:149-150`; only the first disappears. The arity-zero enumeration the case
also pins lives in `provider_launcher.ex:23-27`, and it stays exactly there,
doing exactly what it does now: ADR 0019's first-image scrubbing, per launch.
So `adapter_test.exs:50`'s
`assert variable == "LOOPEX_PROVIDER_API_KEY"` is, afterwards, a pin on the
host-facing accessor — the one name an operator configures — and that is what
it should say it is. The neighbouring case `a missing credential is reported
before any provider is called` proves the refusal today by deleting the
variable from the VM; under this decision it proves the same refusal by
supplying no credential token with the call, which is the path that
replaces it.

### Security review

The review is an acceptance point of M5 Outcome 6, read by someone other than
the implementer, over the exact diff. It answers: that the token is opaque
and carries no credential and no authority; that the routing registry holds
routing only, with no bytes and no material a secret could be derived from;
that the resolved value has no path into guardian state, a message other than
the one permitted reply, an exit reason, a crash report, an IO request, a file
or the environment; that every row of the failure table refuses without
retaining a copy; that the guardian's deadline bounds the whole resolution
whatever a custody process does; that the cleanup and abandonment paths do not
resurrect a value; that loss of custody or registry answers `:unavailable`
rather than reconstructing anything; that a host supplying no token is refused
rather than falling back to an ambient read; and, on the host side of the
boundary, that each reference implementation reads the operator's variable
once, deletes it, redacts its custody process's state, and registers a token
that carries no bytes. Its record is retained with the milestone's evidence.

### Concurrency, as a measurement

With the process-wide read gone, the twelve `loopex_llm_reqllm` modules that
declare `async: false` for that reason may declare `async: true` one at a
time, each kept only after the application's suite stays green across several
seeds, exactly as the M4 speed work converted the other twenty-one modules.
The result is recorded against the baseline in the
[verification companion](../developer/verification-technical.md#technical-verification-speed):
that application was the fast check's critical path at M4 closure, with 96% of
its time in those twelve modules. Any module that stays serial keeps its
reason recorded beside it. The measurement is evidence about the change, never
a condition a test may be weakened to meet.

<a id="technical-adr-0034-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0034-provider-credential-handoff-over-bootstrap-channel.md#concept-adr-0034-consequences).

Adapter-internal. The `Loopex.Model` callbacks, the public protocol and its
generations, public events, snapshots, artifacts, the executor protocol and
every durable record are untouched, so no vector, schema or migration is
affected. The private codec's version and frame kinds are unchanged, and a
child built from the same manifest digest behaves identically; the build
manifest is not revised by this decision.

The one visible change is host composition: a host that starts a runtime with
this adapter passes a credential token with the call and owns both the
registry that routes it and the custody process that holds the bytes. The reference CLI, the app-server host, the M5 daemon and the
real-provider lane keep reading `LOOPEX_PROVIDER_API_KEY` where they compose,
and delete it there, so an operator's setup is unchanged and the release
check's credential frame is unchanged. An embedder that relied on the adapter reading
the environment for it must pass a token instead; that is the refusal
path, not a silent fallback, and it is stated in the operator and developer
documentation the milestone updates.

Rollback is reverting the adapter change. Nothing durable, no root and no
protocol generation records which mechanism delivered a credential to a
process that has since exited, so a rollback needs no migration and leaves no
trace to repair.

Acceptance binds this complete pair at the exact candidate the maintainer
names in the governance record. Its claims remain unproved until the tests the
M5 plan maps to Outcome 6 exist and pass and the security review is recorded.
