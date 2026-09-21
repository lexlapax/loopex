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

This decision narrowly supersedes ADR 0019's statements that the environment
variable is the invocation's sole credential source, that the ready sender
resolves that variable, and that the sender must be raw-spawned and owned only
by the guardian. Host composition now consumes the variable once, the ready
sender resolves the composition-bound token through custody, and managed
guardian/sender processes are direct temporary `owner_workers` children. The
sender's supervised initial call and closure remain token-free, so they do not
carry the key in a crash-reportable child argument. Direct mode retains ADR
0019's raw linked-and-monitored sender.
ADR 0019's private channel, launch-time environment enumeration and scrubbing,
failure teardown, and forensic-memory disclaimer remain in force.

The credential frame on that socket keeps the shape it has today. The codec
carries an eight-byte header — `LP`, version 2, a closed kind byte and a
length — and the `credential` kind admits exactly the two members `nonce` and
`credential`, with the credential a non-empty binary of at most 65,536 bytes
and the frame's **payload** capped at 69,632 — `cap(:credential)` is
`@semantic_bytes + @envelope_bytes`, 65,536 + 4,096
(`provider_codec.ex:53-54`, `:80`) — with the frame on the wire eight bytes
longer than that, `encode/2` prefixing `<<"LP", version, code, length::32>>`
before the payload (`:92`). An earlier revision called 69,632 the frame cap,
which is the one number a reader sizing a buffer would get wrong. Nothing
about the frame changes; what changes
is where its second member comes from.

### Ordering

The managed order is fixed and is the reason the credential is not folded into
an earlier frame:

1. Before opening a namespace, starting a Port or receiver, installing a sink,
   asking for trace exclusion, routing a token or performing any provider
   action, the callback preallocates distinct `guardian_ref` and `sender_ref`
   values plus the guardian's `stop_reference`.
2. A linked start proxy asks Core's `owner_workers` supervisor to start the
   guardian. Its initial argument is exactly
   `{guardian_ref, callback_owner_pid, stop_reference}`. The guardian monitors
   the callback owner, sends exactly
   `{:guardian_started, guardian_ref, guardian_pid}` to that expected pid, and
   waits inert. Owner loss, a wrong reference or a wrong pid makes it exit
   without starting any helper or provider action. Independently, the proxy
   catches a starter refusal or exit and sends exactly either
   `{:start_proxy_result, :guardian, guardian_ref, proxy_pid,
   {:ok, guardian_pid}}` or
   `{:start_proxy_result, :guardian, guardian_ref, proxy_pid,
   {:error, :unavailable}}`. The callback requires both
   that exact proxy result and the exact child acknowledgement in either mailbox
   order. As soon as either matching message first discloses `guardian_pid`, the
   callback installs a monitor on that exact child. Child `DOWN` before the
   ownership transfer completes is `:unavailable`. The callback consumes the
   proxy's normal `DOWN` before it continues.
3. With that guardian monitor still installed, the callback calls
   `ProviderLifetime.register(guardian_pid, stop_reference)`, and accepts only
   `{:managed, retainer_pid, cleanup_grace_ms}` with the exact documented
   types. It sends exactly
   `{:authorize_guardian, guardian_ref, callback_owner_pid, retainer_pid,
   cleanup_grace_ms, sender_ref}`. The guardian checks the reference and
   callback pid and installs a monitor on `retainer_pid` before it flushes the
   callback-owner monitor, then returns exactly
   `{:guardian_authorized, guardian_ref, guardian_pid}`. The
   callback receives that acknowledgement, then demonitor-flushes its child
   monitor because the retainer monitor now owns guardian lifetime, before it
   starts the sender. From
   then on the guardian must accept and
   acknowledge Core's exact `:loopex_provider_resource_stop` request even while
   sender start, adoption or provider bootstrap is still pending.
4. A second linked start proxy asks the same supervisor to start the sender.
   Its initial argument contains only `sender_ref`, the callback owner pid, the
   guardian pid and the tracing capability. It contains no token, registry
   handle, socket, nonce, request or credential. The sender monitors the
   callback owner, sends exactly
   `{:sender_started, sender_ref, sender_pid}` to that expected pid and waits
   inert. Its proxy uses the same protocol with `:sender`, `sender_ref` and
   sender pid. The callback again requires both exact answers and reaps the
   proxy before authorization. As soon as either matching answer first
   discloses `sender_pid`, the callback monitors that exact child; child `DOWN`
   before adoption completion is `:unavailable`. The guardian proxy is gone before the sender
   proxy can exist. A wrong reference, kind, proxy pid, child pid or result
   shape is `:unavailable` and reverse-cleans any child already acknowledged.
5. While its scope and the authorized guardian are still live, the callback
   sends exactly
   `{:authorize_sender, sender_ref, callback_owner_pid, guardian_pid}` to that
   exact sender. The sender checks both pids, links to the guardian and sends
   `{:sender_adopt, sender_ref, sender_pid}`. The guardian checks the expected
   reference and pid, installs a sender monitor and replies exactly
   `{:sender_adopted_by_guardian, sender_ref, sender_pid, guardian_pid}`. Only
   then does the sender flush its callback-owner monitor and send exactly
   `{:sender_adopted, sender_ref, sender_pid}` to the callback.
   It remains parked, without performing exclusion or starting its sink. Only
   after the callback receives that acknowledgement does it demonitor-flush its
   sender monitor — the guardian has already installed its own — and send the guardian its full
   initialize message, including the request/configuration, opaque token and
   registry handle but no credential bytes. The sender still holds no token,
   registry handle, socket, nonce, request or credential.
6. The guardian opens the namespace and listening socket, then starts ADR
   0019's carrier and guard with `env -i` and a fixed `PATH`, passing the
   namespace, nonce, cleanup grace, interpreter and worker paths, socket path,
   build-manifest digest and the existing absolute invocation deadline. No
   credential is among them. The parent writes
   `bootstrap:<nonce>:<grace>` on the control pipe; the guard answers
   `ready:<nonce>:<group>:<pid>:<namespace>` and execs the worker, again under
   `env -i`.
7. The guardian accepts the socket and sends the `bootstrap` frame: nonce,
   codec version and build-manifest digest. The child answers with a `ready`
   frame that must equal that payload exactly. Until this point the child has
   proved nothing, and no credential has entered the invocation's provider
   process tree or private channel.
8. Exact readiness lets the guardian send exactly
   `{:begin_bootstrap, sender_ref, guardian_pid, sender_pid, absolute_deadline}` to the parked
   sender. The sender validates the reference, both pids and that absolute
   instant on receipt, retains the instant, and rechecks
   `now < absolute_deadline` immediately before it installs both trace
   exclusions. It drains every pre-clear trace signal, rechecks the instant
   immediately before it spawns and installs its group-leader sink from the
   untraced process. The sink is linked for abnormal termination and also
   monitors the exact sender so a normal sender exit ends it. The sender
   verifies both pids clear and sends exactly
   `{:bootstrap_result, sender_ref, sender_pid, guardian_pid, :ok}`. An
   immediate exclusion or sink-installation refusal uses the same tuple with
   `{:error, :unavailable}`. A matching binding with any other result fails
   closed as `:unavailable`; a wrong reference or pid is ignored and cannot
   release credential context.
9. Only after validating that acknowledgement and rechecking the retained
   instant does the guardian send exactly
   `{:credential_context, sender_ref, guardian_pid, sender_pid, token,
   registry_handle, accepted_socket, invocation_nonce}`. The sender
   revalidates the reference, both pids and its retained deadline on receipt,
   then rechecks the instant immediately before it performs only the registry
   lookup. It parks with the returned custody reference and sends exactly
   `{:credential_phase_result, sender_ref, guardian_pid, sender_pid,
   :registry, :ok}`. An immediate registry refusal uses the same tuple with
   `{:error, :unavailable}`. The guardian revalidates every field, the allowed
   result for that phase and the absolute instant
   before replying exactly
   `{:credential_phase_continue, sender_ref, guardian_pid, sender_pid,
   :registry, absolute_deadline}`. The sender validates the unchanged retained
   deadline, rechecks it on receipt and rechecks it again immediately before
   the permitted call; only then does that continuation permit custody
   resolution. The sender validates the exact custody reply, parks
   while it alone holds the returned bytes, and sends the exact phase-result
   tuple with `:custody, :ok`, or with one normalized allowed closed-set error;
   neither that message nor the guardian's matching exact continuation carries
   the custody reference or bytes. That continuation includes the same absolute
   deadline and permits only the `credential` frame write under the bound nonce
   after the sender's receipt-time and immediate-pre-write rechecks. After a
   successful write the sender drops every credential-bearing logical reference
   and tail-calls a final wait whose arguments are non-secret. That
   wait sends the exact result tuple with `:credential_frame, :ok` and parks; an
   immediate write failure instead sends normalized
   `{:error, :unavailable}`. Only the
   guardian's matching exact continuation, again carrying the same deadline,
   permits the next step. A stale, mismatched or out-of-order tuple is ignored
   and then refused by the unchanged deadline; it cannot advance the sender.
10. The final `:credential_frame` continuation permits only successful sender
    exit. The sender validates the unchanged deadline, rechecks it on receipt
    and immediately before that transition, and exits normally from its
    already non-secret final wait. The guardian consumes the exact normal sender
    monitor `DOWN`, rechecks the same instant, then starts its generic phase-send helper
    for the `invocation` frame carrying the request, its canonical bytes and its
    staged digest. Possible delivery begins here, not before, and the
    credential sender never receives the request. The same three phase gates
    and tuple bindings govern the raw guardian and sender in Direct mode. If
    `:begin_bootstrap`, credential context or any continuation is consumed at or
    after the retained instant, the sender starts no next phase, scrubs any
    custody bytes and exits with the fixed non-secret `:credential_deadline`
    reason. The guardian
    reports `:timeout` only after its own clock confirms expiry and starts no
    invocation helper.

The phase-result union is closed: `:registry` permits only `:ok` or
`{:error, :unavailable}`; `:custody` permits `:ok`, custody-originated
`:missing`, `:expired` or `:unavailable`, and sender-originated `:oversized`
after its byte-bound check; custody itself may not originate `:oversized`; and
`:credential_frame` permits only `:ok` or `{:error, :unavailable}`. The sender
normalizes a producer's answer and performs the size check before sending that exact ref/pid/phase-bound
tuple. No phase result or continuation carries a custody reference or
credential bytes, and any other result shape fails closed as `:unavailable`.
An error result ends the sequence and never receives a continuation.

A child that fails step 7 — a wrong manifest digest, a wrong nonce, a codec
version it does not speak, or an expired deadline — never reaches step 8. A
guardian or sender that loses authorization before adoption never reaches step
6. Those are separate properties: the managed-start witnesses prove inert
abandonment, and the existing bootstrap-refusal cases prove no credential is
sent before child readiness.

### The token, routing registry, custody process and tracing capability

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
host's registry. The registry accepts only the exact runtime map shape:
`map_size(token) == 2` with keys `[:__struct__, :id]`, the named struct tag and
a sixteen-byte `id`. A forged struct-shaped map with any extra key is
malformed. An option carrying anything else is refused as invalid before
routing or child creation.

**A bare binary was the earlier shape, and it could not be validated.** That
revision called the token an opaque binary of at most 256 bytes from ADR
0023's alphabet and then said a bare binary "that could plausibly be bytes" is
refused — which is not decidable, because a credential *is* a bare binary and
many credentials are alphabet-clean and under 256 bytes. There is no content
test that separates a token from a secret. A struct separates them by type:
credential bytes never arrive as `%CredentialToken{}`, so the refusal is a
pattern match rather than a judgement, and a credential accidentally passed as
a token is refused by adapter preflight before routing or child creation.

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
custody process's reply, writes the frame and dies; outside the host's custody
process, the bytes enter adapter-side parent code only in that sender and only
for that write. Two invocations resolve
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
the composition-time model configuration used for the invocation names *which* credential but says nothing
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
  is written the same way —
  `%Loopex.LLM.ReqLLM.CredentialRegistry.Handle{pid: local_pid,
  incarnation: <<_::128>>}`. Validation requires `map_size(handle) == 3`, exact
  keys `[:__struct__, :pid, :incarnation]`, the named struct tag, a pid on the
  current node, a sixteen-byte incarnation and a live process at composition;
  `route` sends `{:route, incarnation, token}` and an incarnation mismatch is
  `:unavailable`. The later process-death race is still handled by the call.
  The tagged value is self-describing at a glance and cannot be mistaken for
  anything else in an options list.

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
  asking again. The accepted reply set is exact: `{:ok, custody_ref}` is
  accepted only when the reference passes the validator below, and
  `{:error, :unavailable}` is the registry's only accepted refusal. Every
  other registry reply becomes `:unavailable`, including another in-set atom
  such as `:missing`, `:expired`, `:timeout`, `:oversized`, `:no_token` or
  `:invalid_token`, an arbitrary atom or tuple, and a malformed or extra-key
  successful reference. This producer check prevents a host-authored registry
  reply from selecting another component's private classification.

  A configured token requires a `%CredentialRegistry.Handle{}` whose fields
  pass the handle validator. A missing handle or any other term refuses host
  composition before an invocation can start. A structurally valid handle whose
  process later dies is the runtime `:unavailable` case. A route reply shaped as
  `{:ok, custody_ref}` still normalizes to `:unavailable` unless `custody_ref`
  passes the custody-reference validator; host-authored successful terms never
  pass through as reasons.

  The one accepted private shape is exact:

  ```elixir
  %Loopex.LLM.ReqLLM.CredentialCustody.Ref{
    pid: local_pid,
    incarnation: <<_::128>>
  }
  ```

  The registry stores that struct as its routing row. Validation requires
  `map_size(ref) == 3`, exact keys `[:__struct__, :pid, :incarnation]`, the
  named struct tag, a pid on the current node, a live process at the check, and
  a sixteen-byte incarnation. The sender calls the custody protocol with that
  incarnation; `GenServer.call` supplies request/reply correlation. A process
  exit, incarnation mismatch or malformed reply is `:unavailable`. The liveness check is
  not treated as a guarantee — custody may die immediately afterwards, and the
  guarded call handles that race. The shape is composition-private, never
  durable or public, and gives the malformed-route proof a positive contract
  to compare against.

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
- **Its lifetime is the host owner's, and a restart invalidates the
  handle.** The host owner process starts the registry when it composes the
  runtime. **Exactly which owner, per host:** the owner process spawned by
  `LoopexComposition.RuntimeOwner` for the reference CLI and app-server host,
  and the daemon's owner process for the daemon. `RuntimeOwner` creates an owner
  process; it is not a supervisor. Each owner links the registry, custody
  process and tracing capability as fixed components. In all three the normal path stops
  them with the rest of the composition, a failed start unwinds them in the
  same reverse cleanup as any other started edge, and the owner's own death
  takes them with it, so there is no path on which they outlive the host that
  composed them. If the registry dies, the handle a composed runtime
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
registered under the runtime reference rather than a global name, and register
its token in the routing registry. Both host processes implement the same
defensive `format_status/1` shape as core's `OwnerGroup`: they replace
`state`, `message` and `reason` with fixed redacted atoms and replace `log`
with `[]`. Custody needs that protection for the credential bytes; the registry
needs it for its opaque tokens and custody references. The real-provider lane
composes the same way. Nothing in the adapter
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

**Exactly one credential-bearing BEAM message exists from the adapter edge
inward, followed by one private-channel frame to the child, and both are
named.** Host-owned composition moving the environment input into
custody, and later host-owned rotation replacing it there, are outside this
count. An earlier draft said the value never appears in a message while also
putting custody in a long-lived process the sender asks — which cannot both be
true, because answering is a message. The contract is a permission with a
boundary, not an absolute:

- The **only** permitted credential-bearing BEAM message into or within the adapter is the
  custody process's reply to the sender's `resolve` call, carrying
  `{:ok, %{credential: bytes}}` — **keyed**, for the redaction reason below —
  to the one sender process that asked. It is bounded by the
  same 1..65,536-byte rule as the frame, it is never logged, never forwarded,
  and never held after the frame is written. The registry lookup that precedes
  it carries no credential, so the token's journey through the registry adds
  no second parent-VM message in which a secret can be seen.
- The sender then performs the one required credential-bearing frame write on
  the child's private socket. It is deliberately the same class of act as the custody reply: one
  short-lived process receives the bytes, uses them once, and dies. ADR 0019
  already protects that process — the sender installs its own group-leader
  sink so no IO request can carry anything out of it, it is unregistered, and
  it reports only an atom or a `{:error, atom}` pair to the guardian.
- **What keeps credential bytes out of a runtime-managed sender's trace: one
  core call that does two things.** ADR 0030 requires the key-bearing call to be excluded by match
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

  **The sender cannot exclude itself first, because it is already traced when
  it starts.** This pair said for several revisions that the sender "calls
  `exclude_self/2` before it resolves anything", which is true of the
  function body and beside the point: `set_on_spawn` gives a spawned process
  its parent's trace flags **at spawn**, so the closure's own entry call is
  traced — and the closure **holds the token**, because that is how a spawned
  function receives anything. An audit probe saw exactly that: the entry call,
  token included, delivered to the tracer before the first line of the body
  could run. Ordering inside the body cannot fix an exposure that happens at
  the boundary into it.

  **So the bridge starts and adopts a token-free parked sender.** Its initial
  supervised argument holds **no token, no registry handle, no channel context
  and no credential**. It contains only the exact sender start reference,
  callback-owner pid, guardian pid and tracing capability. Guardian and sender
  remain plain recursive Task functions rather than GenServers: Task reporting
  can render their token-free initial arguments, while later token, handle and
  credential messages are consumed into loop locals rather than retained as a
  reportable GenServer state. The complete Task/supervisor-report witness below
  guards that implementation choice. Before provider
  launch the sender completes its non-secret managed-start authorization,
  links to the guardian, obtains the guardian's monitor acknowledgement, drops
  its temporary callback monitor and parks. Exact provider readiness releases
  it with
  `{:begin_bootstrap, sender_ref, guardian_pid, sender_pid, absolute_deadline}`.
  It validates and retains that instant, rechecks it, establishes its exclusion
  synchronously and confirms success with
  `{:bootstrap_result, sender_ref, sender_pid, guardian_pid, :ok}`. Immediate
  exclusion or sink-installation failure returns the same bound tuple with
  `{:error, :unavailable}`. **Only after the guardian validates exact success
  before the deadline** does the sender receive the exact `:credential_context` tuple containing the
  same binding, token, registry reference, accepted socket and invocation nonce,
  and only then does it enter the three guardian-gated phases for registry
  lookup, custody resolution and frame writing. Each phase returns its exact
  producer-scoped result and parks before the next one. Every continuation
  repeats the retained deadline; the sender rechecks it on receipt and again
  immediately before the permitted operation. Neither a result nor a
  continuation carries credential bytes.
  A message sent to an already-excluded process is not a traced call, so
  nothing the tracer can see ever carries the token.

  Its witness asserts the property the old ordering could not: the tracer
  receives **no raw trace message from that process carrying the token, at any
  point in its life** — entry included — while a non-excluded control process
  spawned with the same closure shape does produce one, so the case cannot
  pass by tracing nothing.

  **The core API takes both inputs, and the adapter supplies the function
  list.** The parked process — which becomes the credential sender only after
  exact readiness — calls, after its non-secret authorization, adoption and
  exact `:begin_bootstrap` tuple but **before it receives any token, registry
  handle, socket, nonce or credential**:

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

  In managed mode it returns `:ok` once the caller is excluded from **every** live trace
  session and recorded as excluded for every future one. Only then is the
  token sent to it, and only then does it route the token, receive the
  credential and write the frame. Nothing
  the sender does after that point can appear in a trace, whatever modules or
  functions a host names — including `:gen_tcp`, including modules nobody has
  thought of.

  **That promise is about credential bytes, and it begins at the exclusion
  point**, which an earlier revision stated absolutely and therefore stated
  too widely. The **token** reaches the sender by travelling somewhere the
  exclusion cannot cover: it sits in the model configuration's `options`, and
  the coordinator hands those options to the adapter as the second argument of
  `module.complete(request, options, progress)`
  (`session_coordinator.ex:3231`) — inside a **coordinator**, a process the
  runtime owns and `:set_on_spawn` therefore traces, and **before the sender
  process exists at all**. A session that names the adapter module sees that
  call. There is no ordering that fixes it: the token has to arrive before the
  sender can exclude itself on its behalf.

  So the token is covered by **redaction**, not by exclusion, and this pair
  says which rather than letting the absolute claim imply otherwise:

  - the **credential bytes** never appear in an adapter-sender trace message
    after exclusion, because the sender excludes itself before it holds them.
    Host-owned custody and composition transfers are outside this adapter
    claim, as the transfer boundary above already states;
  - the **token** may appear in a raw trace message for `complete/3`, and what
    keeps it out of an **entry** is `Loopex.Trace.Entry`'s credential
    redaction — which today does not reach it.

  **The gap is exact, and closing it is part of core change 3.** `Entry` keys
  its redaction off a map key: `redact/3` placeholders any value whose key
  matches `@credential_pattern` — which does match `token`
  (`entry.ex:25`, `:140-146`, `:220`). But `options` is a **keyword list**,
  and a keyword list reaches `redact_list/4`, which walks every element with
  the key argument `nil` (`entry.ex:206-218`) and then redacts each
  `{key, value}` pair through the tuple clause, again with `nil`
  (`entry.ex:153-158`). The key never reaches `credential_key?/1`. A
  `%Loopex.LLM.ReqLLM.CredentialToken{id: <<16 bytes>>}` under
  `credential_token:` is therefore rendered **verbatim** today: the struct's
  own field is `id`, which matches nothing, and sixteen bytes is under the
  64-byte binary threshold at `entry.ex:148`.

  So core change 3 carries one further clause in `Entry`, and it is generic
  rather than about this adapter: **a `{key, value}` pair inside a list is
  redacted with `key` as its key** when `key` is an atom or a binary, exactly
  as the same pair inside a map already is. That is the missing half of a rule
  `Entry` already has, it closes every keyword list — `api_key:`,
  `authorization:`, anything under 64 bytes — and it names no module core is
  not allowed to know about. With it, the token renders as a `credential`
  placeholder, and this pair's option key is `:credential_token` precisely so
  that it does.

  Its witness is the pair that must differ: `Entry.render/2` over a keyword
  list carrying a `%CredentialToken{}` under `:credential_token` produces no
  occurrence of the token's bytes, while the same token under a key naming
  nothing does — so a case cannot pass because the value was short, absent or
  never rendered.

  Entry redaction happens after Trace has received the raw trace tuple, so it
  cannot protect the callback's last-message crash material. Trace therefore
  implements the same defensive `format_status/1` boundary as the credential
  custodians: it replaces `state`, `message` and `reason` with fixed redacted
  atoms and `log` with `[]`. A raw arguments-level trace tuple for `complete/3`
  carrying distinct token and registry-handle canaries is the actual last
  message when the callback is forced to crash. The case captures the complete
  OTP report and owner-observed exit, proves those four replacements occurred,
  and refutes both canaries everywhere in both. Entry rendering and Trace status
  redaction are separate witnesses: the first protects emitted entries; the
  second protects the one process allowed to consume raw trace messages.

  **The process half, probed at both toolchain pairs before it was written
  down.** A process flagged by inheritance (`:set_on_spawn` from a traced
  parent) calls `:trace.process(session, self(), false, [:all])`; the call
  returns `1`, the flags are gone, and its subsequent `:gen_tcp.send/2` with
  the canary produces **no trace message at all**, while a non-excluded
  control process's identical call produces one. There is no message for a
  sink to redact — which is the property ADR 0030 asks for, reached for the
  callees as well as for the named calls.

  Clearing the flags is necessary but is not the acknowledgement barrier. A
  raw signal emitted before the clear may still be in flight, and the current
  tracer also retains a call start in `state.calls` until its matching return.
  Clearing a sender suppresses that return and would strand the row. M5 closes
  both gaps in `Loopex.Trace`: level `:calls` retains no start time because its
  match specification requests no return; `:returns` and `:arguments` monitor
  every pid represented in the pending-call map, remove the monitor when the
  last key is taken, and purge every key for that pid on confirmed `DOWN`.
  Session destruction demonitor-flushes the retained monitors with the rest of
  the session state.

  Managed exclusion adds the live-process cut. After clearing the sender's
  flags, the Trace process calls `:trace.delivered(session, sender_pid)` and
  records the returned reference instead of blocking its `GenServer` callback.
  It continues reducing raw trace messages. Only when it consumes the matching
  `{:trace_delivered, sender_pid, ref}` does it purge that pid's remaining call
  keys and acknowledge the exclusion to `Control`. The guardian's one deadline
  bounds this asynchronous barrier too. Thus every pre-clear signal is reduced
  before acknowledgement, no post-ack signal arrives, and no call row whose
  return was suppressed remains behind.

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

  - **The capability is a tagged host-owned process reference in model
    options**:
    `%Loopex.Trace.Capability.Handle{pid: local_pid,
    incarnation: <<_::128>>}`. Validation requires `map_size(handle) == 3`,
    exact keys `[:__struct__, :pid, :incarnation]`, the named struct tag, a
    local live pid and sixteen-byte incarnation. The capability starts unbound.
    Its first successful `bind(handle, runtime)` stores exactly that runtime
    identity; repeating the same bind is idempotent, while a different runtime
    refuses `:capability_already_bound` without changing the first binding.
    Composition succeeds only after binding the exact runtime token, and later
    exclusion messages carry the incarnation. The shape is the same private
    class as the credential registry handle beside it and as the
    executor's `reference:`. The host starts it before the runtime, as it
    already starts the registry and custody process, and hands it the runtime
    reference after runtime start but before the composition owner reports
    success to its caller. A failed or cross-runtime bind is a failed
    composition before runtime use, child creation, token routing or custody
    access and unwinds
    the runtime, capability, custody and registry in reverse order. It
    holds no membership and makes no decision; it exists because options are
    built before the runtime and something has to bridge that order.
  - **Membership lives in `Loopex.Runtime.Control`**, chosen by reading the
    tree rather than by preference: it is the runtime supervisor's **second**
    child (`runtime/supervisor.ex:70`), so under `:rest_for_one` it survives
    every tracer restart; it already holds per-runtime process state; and it
    already monitors pids and handles `DOWN` (`control.ex:805-826`), which is
    the exact machinery the set needs.
  - **A future trace session must find the MFA exclusions too, not only the
    pids.** `Control` holding excluded pids answers "skip this process" for a
    session that starts later; it does not answer "clear these functions",
    which is the half ADR 0030 names by name. So `Control` retains **both**: the
    excluded pid set, and a **ref-counted union of the excluded MFAs** — a
    count per identity, incremented when a sender installs it and decremented
    when that sender's `DOWN` arrives, so an identity is cleared for a new
    session exactly while some live sender needs it. On the transition from one
    owner to zero, `Control` restores that MFA in every live session to the
    pattern selected by that session's own configuration; a session that did
    not select it remains clear. It derives the restoration from the retained
    session selection rather than from a stale captured pattern. A set without
    counts would either leak the clear forever, restore while another sender
    still relied on it, or overwrite a host's selected pattern.
  - **Starting and stopping a trace session are serialised against installing
    an exclusion, and strong-handle ownership is singular.** M5 reroutes
    `Loopex.Runtime.trace/2` and matching stop through `Control`; they no longer
    call `Trace.start_session/3` directly. Control uses an asynchronous,
    reference-tagged request/ack handshake, never a nested call into Trace. It
    sends the current excluded-pid set, ref-counted MFA union and exclusion
    version, remains available to `post_commit`, `current_owner` and later
    exclusions, and replies to the trace caller only after Trace acknowledges
    the current version.

    Trace creates one private ETS table that only the Trace process may access.
    The existing internal `trace_module` option becomes the sole dispatch seam
    for every named-session operation Trace performs: session create, function
    and process selection, delivery barriers, information queries and destroy.
    Production always supplies `:trace`; the test module supplies the same
    closed operation surface and returns an identifiable canary-bearing handle.
    Each full handle returned by `:trace.session_create/3` moves immediately
    from the creating callback's local variable into that table and never enters
    callback state, a reply or another message. Callback state retains only the
    table identifier, normalized configuration and weak `{name, id}` identity;
    `:sys.get_state/1` can therefore copy no full handle, and the private table
    denies a caller that learns its identifier. Trace sends only the weak
    identity to Control; it never finds the session by name in
    `:trace.session_info(:all)`, where another runtime may have the same
    `:loopex_trace` name. Control retains normalized configuration and selected
    MFAs plus that weak identity, which does not keep the session alive, and
    monitors the exact Trace pid. A
    version change while start is pending sends the delta and requires another
    acknowledgement before publication. The internal acknowledgement may carry
    the weak identity, normalized configuration and selected MFAs, but Control
    preserves the existing experimental embedded API: `Loopex.Runtime.trace/2`
    still returns its present `{:ok, session_description}` shape and trace stop
    and status retain their present shapes. Explicit stop makes Trace read and
    destroy the full handle inside its private table, delete that row and
    acknowledge absence before Control drops the retained weak identity and
    selection.

    Trace replacement has a registration handshake because supervisor start and
    delivery of Control's monitor `DOWN` are not ordered. A new Trace announces
    its exact pid and incarnation to Control and stays idle. If Control still
    records the predecessor pid, it either proves that exact pid dead,
    demonitor-flushes it and performs the same loss transition, or queues the
    hello until that exact `DOWN`; if the `DOWN` arrived first, it consumes the
    already-recorded loss and accepts the hello. Only then does Control send the
    retained weak identities, configuration, selected MFAs, live excluded pids,
    ref-counted MFA union and version. The replacement is pending rather than
    current until its acknowledgement, and trace start and status publish
    nothing from it meanwhile.

    The private table is owned by Trace and has no heir, so process death
    deletes the table and releases its last full handles even when
    `terminate/2` is bypassed. Before creating a replacement session the new
    process checks the exact old weak identity in
    `:trace.session_info(:all)`. When absent it skips destroy. When present it
    calls `:trace.session_destroy(old_weak)` and accepts `true`; it normalizes a
    racing `false` or `ArgumentError`/`:badarg` only after a fresh all-session
    query confirms that exact weak identity is now absent. Any other error, or a
    still-present identity, fails replacement. It then creates the replacement, installs every
    retained exclusion at the current version and acknowledges. Control
    publishes or replies only after that acknowledgement. Caller death cancels
    only its pending reply, not the lifecycle operation.

    This ordering prevents a session from being created between process
    exclusion and MFA clearing. The witness races start with exclusion in both
    mailbox orders, races stop with the last sender exit, and proves Control
    never receives a full handle. The test forces both mailbox orders — old
    `DOWN` before replacement hello and replacement hello before old `DOWN` —
    and in each observes exactly one current Trace monitor and one private
    handle table after acknowledgement, no start or status publication before
    it, and no lookup by the shared session name. The fake module records that
    every operation after creation received its exact canary-bearing handle, so
    the witness proves the handle entered the private table and remained usable
    without exposing it. `:sys.get_state/1`, an OTP
    status request and a complete forced-crash report are each inspected and
    contain no full handle; the status and crash cases also prove the defensive
    replacements rather than passing because no report was emitted. Killing
    Trace while the test retains only the weak handle deletes the table and
    makes the old weak identity disappear before the replacement publishes; a
    non-excluded control process proves the replacement is live.
  - **The set is leak-free and proportional rather than bounded**, and the
    distinction is worth the word: nothing caps it, because nothing may refuse
    a sender. What holds is that every entry has an owner whose `DOWN`
    removes it, so the set is proportional to the senders alive at that
    instant and returns to its baseline — normally empty — as they exit.
    Calling it "bounded" implied a ceiling the design does not have.
  - **Control monitors every excluded sender and
    removes it on `DOWN`.** An earlier revision kept a pid per invocation
    forever, which is a leak measured in invocations; senders are short-lived
    by construction, so the set returns to its baseline — normally empty —
    as they exit.
  - **A new trace session consults the set.** Control-mediated start supplies
    every retained pid and MFA exclusion to a new or replacement tracer, so the
    session skips every pid Control holds, the same place `excluded?/3` already
    excludes the tracer and dispatcher by role (`trace.ex:411`); a restarted
    tracer never starts from an empty private snapshot.
  - **A `Control` restart is a runtime-wide event rather than a tracing
    continuation.** `Control` is a `:permanent` child under
    `:rest_for_one` and is the **second** of the root's seven children
    (`runtime/supervisor.ex:64-90`, strategy at `:92`), so its restart clears
    the set — and also restarts **every child after it**: the worker task
    supervisor, the owner-group and session dynamic supervisors, the event
    dispatcher and, last, the tracer (`:73`, `:74-77`, `:78-81`, `:82-85`,
    `:86-89`). Trace's private ETS table is the sole retained holder of every
    full strong session handle, so stopping its owner deletes the table and
    releases those last strong handles even if `terminate/2` is bypassed;
    callback state and Control retain only weak identities. The replacement
    destroys an old weak identity or confirms its absence before it publishes a
    new session. The same restart ends every session coordinator.
    M5 also extends `Loopex.Runtime.ProviderLifetime` with an opaque supervised
    child starter threaded through the coordinator's provider-call scope. In a
    managed call, `ProviderBridge` starts both its guardian and its parked
    credential sender as direct `restart: :temporary, shutdown: :brutal_kill`
    children of that owner group's existing `owner_workers` Task.Supervisor.
    Only those two members of the **adapter bridge tree** are direct managed
    children; core's existing provider-call guard and permit-gated provider worker task are already
    direct children of the same supervisor (`session_coordinator.ex:2834-2855`). The guardian continues to start
    and own ADR 0019's socket receiver and generic phase-send helpers; the
    guardian permits at most one socket receiver and at most one generic
    phase-send helper live at a time; the credential sender starts and owns
    exactly one group-leader sink. The registered guardian calls `Port.open/2`
    and owns that Port; the Port's direct OS image is ADR 0019's carrier, the
    carrier starts the independent OS guard, and the guard starts and owns the
    provider BEAM. Links and
    monitors end those raw helpers when their direct owner ends. Managed mode
    has at most one transient linked start proxy at a time; Direct mode has
    none.
    `OwnerGroup.terminate/2` synchronously stops that supervisor, which kills
    and awaits both children before the root can restart through to Trace last.
    Managed start is a two-gate operation-ID handshake rather than a blocking
    `Task.Supervisor.start_child/3` call from the provider callback. The callback
    preallocates distinct `guardian_ref` and `sender_ref` values plus the
    guardian's `stop_reference`. The guardian child argument is exactly
    `{guardian_ref, callback_owner_pid, stop_reference}`; no request,
    configuration, deadline, token or registry handle is present. It uses one linked proxy at a time, so at most
    one transient start proxy exists for the invocation. A materialized child
    monitors the callback owner, sends exactly
    `{:guardian_started, guardian_ref, guardian_pid}` to that expected pid, and
    waits inert. Owner `DOWN`, cancellation, a mismatched reference or a wrong
    pid makes it exit without side effects.

    The linked proxy catches a refusal or exit from the supervised-start call
    and returns the exact tagged result
    `{:start_proxy_result, :guardian, guardian_ref, proxy_pid, result}`, where
    `result` is exactly `{:ok, guardian_pid}` or `{:error, :unavailable}`. The
    callback monitors the proxy and requires that result plus
    `{:guardian_started, guardian_ref, guardian_pid}`; either may arrive first,
    but both pids and the reference must match. As soon as the first matching
    message discloses the child pid, the callback monitors that child too; an
    exact child `DOWN` before transfer completion is `:unavailable`. It then consumes the proxy's
    normal `DOWN` before Core registration. A proxy `DOWN` without its result,
    an unexpected result or a mismatch is `:unavailable` and reverse-cleans an
    acknowledged child. The sender proxy repeats the same protocol with kind
    `:sender`, `sender_ref`, sender pid and `:sender_started`; the first proxy is
    therefore gone before the second can exist.

    After the guardian acknowledgement, the callback keeps that child monitor
    and calls `ProviderLifetime.register(guardian_pid, stop_reference)`. It accepts
    only `{:managed, retainer_pid, cleanup_grace_ms}` with a live pid and valid
    period, then sends exactly
    `{:authorize_guardian, guardian_ref, callback_owner_pid, retainer_pid,
    cleanup_grace_ms, sender_ref}`. The guardian checks the reference and
    callback pid and installs the retainer monitor before it drops and flushes
    the callback-owner monitor, then returns exactly
    `{:guardian_authorized, guardian_ref, guardian_pid}`. The callback
    receives it, then demonitor-flushes its guardian monitor because the
    retainer monitor is installed, before starting the sender. From that point the guardian implements
    Core's correlated `:loopex_provider_resource_stop` request and acknowledgement
    even if no sender or provider child exists yet. Its first gate is then
    complete.

    The callback next starts the sender with only `sender_ref`, its own pid, the
    guardian pid and the tracing capability. The sender returns exactly
    `{:sender_started, sender_ref, sender_pid}` to that expected callback. The
    callback installs a monitor on the exact sender as soon as either the
    matching proxy result or sender acknowledgement first discloses it; sender
    `DOWN` before adoption completes is `:unavailable`. The
    callback then sends exactly
    `{:authorize_sender, sender_ref, callback_owner_pid, guardian_pid}` only
    while both its scope and the guardian remain live. The sender checks both
    pids, links to the guardian and sends
    `{:sender_adopt, sender_ref, sender_pid}`. The guardian validates both
    fields, installs the sender monitor and returns exactly
    `{:sender_adopted_by_guardian, sender_ref, sender_pid, guardian_pid}`; only
    then does the sender drop and flush its callback-owner monitor and return
    exactly `{:sender_adopted, sender_ref, sender_pid}` to the callback.
    Receipt of that acknowledgement completes the second gate. The callback
    demonitor-flushes its sender monitor only then, because the guardian has
    already installed its own. The sender
    remains parked. Only now does the callback send the
    guardian the full initialize message, including the request/configuration,
    opaque token and registry handle but no credential bytes. Ordinary callback
    completion no longer governs either process: the retainer governs the
    guardian, the guardian's link and monitor govern the sender, and both remain
    direct temporary `owner_workers` children.

    Immediate guardian proxy/result, child acknowledgement, Core registration, guardian authorization, sender
    start or adoption failure is `:unavailable`; partial children are stopped in
    reverse order and managed mode never falls back to raw spawn. Raw spawn
    remains only for explicitly unmanaged calls. A live `owner_workers` that
    never answers either start is an owner-group/runtime liveness failure: the
    transfer is incomplete and the adapter's sender clock is not armed. The
    proxy may wait at `:infinity`; scope or owner-group teardown kills the
    authorization owner and proxy, and Core can stop an already registered
    guardian through its installed stop protocol. A queued child that
    materializes later sees callback-owner `DOWN` and exits inert. The contract
    does not misreport such a stall as adapter `:timeout`.

    Once both gates complete, the callback's initialize message carries the
    same absolute invocation deadline allocated before either start; no step
    resets it. The guardian checks it before launch and, if it has elapsed,
    performs reverse cleanup and reports `:timeout`. Otherwise the guardian
    launches ADR 0019's tree. Only exact provider-child readiness lets it send
    `{:begin_bootstrap, sender_ref, guardian_pid, sender_pid, absolute_deadline}` to the parked
    sender; any pre-ready refusal, deadline or guardian death releases nothing.
    The sender validates the reference, both pids and retained deadline,
    rechecks the instant before exclusion and again immediately before sink
    installation, and replies with the exact union
    `{:bootstrap_result, sender_ref, sender_pid, guardian_pid, result}`, where
    `result` is only `:ok` or `{:error, :unavailable}`. Only after the guardian
    validates exact success before the deadline may it send
    `{:credential_context, sender_ref, guardian_pid, sender_pid, token,
    registry_handle, accepted_socket, invocation_nonce}`. The sender validates
    all three binding fields and its retained deadline on receipt, then
    rechecks the instant immediately before it routes the token. Registry
    lookup, custody resolution and credential-frame write are
    three separately parked phases. After each, the sender sends the exact
    non-secret `{:credential_phase_result, sender_ref, guardian_pid,
    sender_pid, phase, result}` tuple. The result union is producer-scoped as
    fixed above, and an error never receives a continuation. Only the
    guardian's exact matching `{:credential_phase_continue, sender_ref,
    guardian_pid, sender_pid, phase, absolute_deadline}`, issued after its own
    deadline check, permits the next phase. The sender validates the unchanged
    instant, rechecks it on receipt and again immediately before the permitted
    operation. The `:custody` result and continuation carry no custody
    reference or credential bytes. After a successful credential-frame write,
    the sender drops all credential-bearing logical references and tail-calls a
    non-secret final wait before sending its `:credential_frame` result. The
    final continuation permits only normal sender exit; only exact normal sender `DOWN` and a
    fresh guardian deadline check permit the guardian's generic helper to send
    the invocation frame. A wrong reference, pid, phase or deadline, or a stale
    replay, is ignored and then refused by the unchanged deadline. A matching
    current-phase tuple with a malformed result or a producer-forbidden atom is
    immediate `:unavailable`. If the sender consumes credential context or a
    continuation at or after the retained instant, it starts no next operation,
    scrubs any custody bytes it still holds and exits with fixed non-secret reason
    `:credential_deadline`; the guardian does not classify `:timeout` until its
    own clock confirms expiry. Only the expected normal sender `DOWN` in the
    final-exit state may advance to the invocation helper. Any other sender
    `DOWN` observed before the guardian's clock reaches the deadline — abnormal,
    killed, `:credential_deadline`, or normal in any earlier state — maps to
    `:unavailable`, tears down the sink and provider tree, and starts no
    invocation helper. A `DOWN` observed after the guardian confirms expiry
    maps to `:timeout` regardless of its process reason; no raw sender reason
    crosses the adapter boundary. The sender
    explicitly keeps
    `trap_exit` false for its lifetime; the guardian traps exits and separately
    monitors the sender for classification. A monitor in
    the sender would be insufficient because `DOWN` could wait in its mailbox
    behind the infinite call, while an abnormal guardian exit propagates through
    the link and terminates the non-trapping sender immediately. `:kill` reaches
    the sender as `:killed`, which would be trappable, so the false flag is the
    required invariant rather than the exit reason. Normal linked exit would be
    ignored; every normal guardian cleanup therefore explicitly stops and awaits
    the sender before the guardian returns. Guardian abnormal death ends a
    parked sender or one blocked in sink installation, clears its exclusions
    through Control's sender monitor and writes no frame. The sink is
    non-trapping and linked to the sender for abnormal or kill propagation; it
    also monitors the exact sender and exits on `DOWN`, so ordinary sender
    success cannot leave it alive. Direct supervisor siblings
    alone would not provide that relation. Explicit stop destroys each strong
    trace-session handle and acknowledges its absence, and no credential-bearing sender
    can cross the loss while `Control`'s retained set is empty. A later sender
    excludes itself anew. A
    sender whose `exclude_self/2` call finds the capability or `Control`
    immediately unreachable fails `:unavailable` before it receives the token;
    one whose call remains unanswered is killed by the guardian at the
    invocation deadline and reports `:timeout`.

  **It fails closed under one deadline per mode.** `exclude_self/2`
  returns only once both exclusions are installed. Its call has no independent
  timeout and uses no hidden `GenServer.call/2` default. The absolute invocation
  deadline allocated before managed start is never reset. Once the managed
  guardian is registered, the sender adopted and the guardian initialized,
  that same instant bounds provider launch and readiness, sender release,
  exclusion, registry routing, custody resolution and frame write together.
  Direct mode has no Core registration or adoption gate: its raw guardian
  carries the request's same pre-launch absolute instant through inherited
  session clearing, sink installation, registry routing, custody resolution
  and frame write. In either mode, a timer only prompts evaluation: before the
  guardian accepts a provider-ready frame, bootstrap result or phase result,
  and before it emits credential context or the next continuation, it rechecks
  monotonic `now < deadline`. The sender independently rechecks the carried
  unchanged instant when it consumes `:begin_bootstrap`, credential context or
  any continuation and again immediately before the permitted operation. A
  result or continuation queued before the timer but consumed at or after the
  instant loses to `:timeout`; mailbox order and sender suspension cannot extend
  the call.
  If the capability or `Control` is immediately unreachable,
  the sender refuses `:unavailable` before it receives the token. If exclusion
  is merely slow or remains unanswered, the guardian kills the sender at the
  invocation deadline and reports `:timeout`. A tracer restart deletes its
  owner-only private table and therefore drops its sole retained strong
  handles; the production replacement confirms Control's weak old identities
  absent before publishing new sessions. The defensive destroy branch exists
  for a present identity and is exercised only by the explicit
  forbidden-extra-strong-handle fault fixture described below. While Trace is absent,
  `Control` can record the sender and MFA set for the replacement session. The
  sender never proceeds on an unconfirmed exclusion.

  **The capability is mandatory wherever a credential token is configured,
  and an absent one refuses.** An earlier revision of this pair let an
  explicitly absent capability proceed, on the reasoning that a host which
  composed no tracing capability has no tracer and no session, so nothing can
  trace. That reasoning does not hold against the tree. **Every runtime starts
  its own tracer**: it is the runtime supervisor's last child, started
  unconditionally (`runtime/supervisor.ex:86-89`), and **any holder of the
  runtime reference can start a session on it** through
  `Loopex.Runtime.trace/2`, which resolves the tracer dynamically on every
  call (`runtime.ex:343-348`). So "the host composed no capability" proves
  nothing about whether a session is running; it proves only that the sender
  has no way to exclude itself from one. Omission was safety made optional,
  and the thing it protects is present in every runtime there is.

  So the rule is one rule, and there is no absent branch: **a model
  configuration that carries a `:credential_token` must carry a tracing
  capability**. A missing, malformed or unbound capability is refused at
  **composition**, where every other malformed option is, so it cannot reach a
  call. A capability or `Control` found immediately unreachable during a call
  produces `:unavailable` **before the token is routed** — before any lookup,
  before custody is reached, before a byte exists in the parent. An exclusion
  call that remains unanswered ends at the guardian's invocation deadline as
  `:timeout`. This reverses
  the earlier decision, and the earlier decision is recorded here as what it
  was: a case in which the credential would have been resolved in a process a
  session may have been tracing.

  **The accepted direct `complete_prompt/3` path is a separate no-runtime
  mode.** The helper constructs a private `%TraceCapability.Direct{}` itself;
  a caller cannot select that tag in runtime model options. It carries no
  runtime reference and is accepted only with `ProviderLifetime.unmanaged`.
  Its raw sender may inherit a Loopex session's `set_on_spawn` flags from a
  traced caller even though it is outside the supervisor tree, so ancestry is
  not treated as safety. The token-free sender's first phase enumerates
  `:trace.session_info(:all)`, skips its `{:legacy, :default}` row, clears
  itself in every non-legacy `{name, id}` with
  `:trace.process(session, self(), false, [:all])`, clears the legacy tracer
  separately with `:erlang.trace(self(), false, [:all])`, and verifies through
  `:trace.info(session, self(), :flags)` that every still-live enumerated named
  session reports no call flag and that the legacy flags are clear. A named
  session destroyed between enumeration, clear and verification is safe only
  after its absence is confirmed; any still-live session whose clear or
  verification fails refuses the invocation before token delivery. Using only
  `:erlang.trace/3` is explicitly insufficient for
  named OTP trace sessions. The Direct guardian starts that sender with
  `:erlang.spawn_opt(..., [:link, :monitor])`; the sender keeps `trap_exit`
  false. An abnormal or `:kill` guardian exit therefore ends a sender blocked
  in clear, custody or frame write, while normal guardian cleanup explicitly
  stops and awaits the sender. For every still-live named session it also requests
  and awaits the matching `:trace.delivered(session, self())` marker, and for
  legacy tracing it awaits `:erlang.trace_delivered(self())`; sessions destroyed
  during that interval must be confirmed absent. Those waits remain inside the
  Direct request's pre-launch absolute deadline. From the now-untraced sender
  it then spawns and
  installs the group-leader sink, so the sink inherits no named-session or
  legacy call flags; it verifies that fact for both pids. It then acknowledges
  that local exclusion and sink installation to the guardian; only then may the guardian send the
  token, handle and channel context. A later Loopex session enumerates only its
  runtime-owned processes and cannot newly select this direct sender. The
  bootstrap calls themselves may be traced, but their closure carries no token
  or credential. A session already capable of being inherited is in that
  enumeration; a session created later cannot select the raw sender because it
  is outside the runtime tree. This mode does not claim protection against an unrelated host
  using raw `:erlang.trace` outside Loopex's contract after the acknowledgement.
  Direct mode neither clears nor restores the three adapter MFAs in a runtime
  trace session: it has no `Control` capability and lies outside ADR 0030's
  runtime-owned process domain. Failure to clear or verify any still-live
  inherited session maps to private `:unavailable`; a session confirmed
  destroyed during the clear is the successful absence case. Host-owned
  custody tracing is outside the adapter boundary in this mode. The Direct
  sender has no authenticated path back into a runtime Trace process to purge
  state while it is alive; the generic pending-call monitor above therefore
  purges its rows on sender `DOWN`, and the Direct witness reads that state back
  at baseline after exit. Its linked-and-monitoring sink has the same sender
  lifetime relation as managed mode, so neither normal completion nor guardian
  failure can leave a sink behind.
  Any capability bound to
  a runtime requires the managed starter and may never use the raw fallback.
  A witness invokes the existing real-provider `complete_prompt/3` case from a
  runtime process carrying a live session's `set_on_spawn` flags, names the
  adapter and `:gen_tcp`, proves the token-free bootstrap may be observed but
  no message after the clear from either sender or sink carries the token or
  canary, and proves a forged
  Direct tag in runtime composition is refused. The probe runs on both
  toolchain pairs and includes a named session for which `:erlang.trace/3`
  alone leaves `:trace.info(..., :flags) == [:call]`.

  **The MFAs this adapter supplies, exactly three.** They are the functions
  that hold the resolved bytes or the token, and the list is passed to
  `exclude_self/2` by the adapter itself:

  | MFA | What it holds |
  | --- | --- |
  | `Loopex.LLM.ReqLLM.ProviderBridge.route_credential/2` | The registry handle and the token — received **by message** after the exclusion, never carried into the process |
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

  **The keyed credential map is a validation and dataflow shape, not a trace
  control.** `receive_custody_reply/2` returns
  `{:ok, %{credential: bytes}}` and never `{:ok, bytes}`;
  `write_credential_frame/2` takes that exact map. Exact means
  `map_size(value) == 1` and `Map.keys(value) == [:credential]`; a success map
  with any extra key is malformed and becomes `:unavailable` before a frame is
  written. It makes malformed host
  replies decidable and keeps the byte-bearing path closed, but it is not a
  fallback if exclusion fails. ADR 0030 placeholders retain a value-derived
  encoded size and SHA-256 digest; a one-byte credential is recoverable by 256
  guesses even when the literal byte is absent. Therefore **no credential byte
  may reach `Entry.render/2` at all**. Keyword-key placeholdering protects only
  the opaque 128-bit token while model options cross core before the sender
  exists; MFA and process exclusion protect the credential.

  **The trace proof is three cases, and the first one is the one that would have
  caught the old design.** A trace session is configured to name
  **`:gen_tcp`** explicitly, alongside `ProviderBridge` — including its private
  `sink_loop/1` — and `ProviderCodec`,
  and a real invocation runs with a **one-byte canary** as the credential. The
  case backlogs the Trace process, captures the sender's expected token-free
  start entry and asserts its arguments contain only `sender_ref`, callback
  owner, guardian and capability — no token, registry handle, socket, nonce,
  request or credential. It observes only non-secret authorization, adoption
  and exact `:begin_bootstrap` tuple before the exclusion. After the exclusion
  acknowledgement, the tracer receives **no further raw message from that
  sender pid** — including none for `:gen_tcp.send/2` — while a non-excluded
  control process performing the same `:gen_tcp.send/2` in the same session
  **does** produce one, so the post-exclusion negative cannot pass by tracing
  nothing. A pre-clear bootstrap call held in the backlog is consumed before
  the acknowledgement, no raw message arrives after it, and the sender has no
  pending-call key then or after exit. During the real invocation the case captures every IO request and proves none
  carries the credential. After token delivery it separately sends a clearly
  non-secret IO canary through the sender's installed group leader. That proves
  the sink path is live, both sender and sink pids have no inherited trace flags,
  neither produces a raw trace message for the IO canary, and no host Logger
  output receives it. Outside the one permitted custody reply, the credential
  canary appears in no captured raw trace message, rendered entry or IO request.

  The second is the default configuration: no module naming, and no entry or
  raw message names any of the three bridge MFAs, while no credential byte
  appears in any captured raw trace message, rendered entry or IO request
  outside the one permitted custody reply. The token may traverse
  core in model options before a sender exists; the existing structured
  redaction is what keeps that credential-adjacent value out of rendered
  entries. The adapter itself is in no namespace wildcard, because `modules/1`
  expands `:loopex` and `:loopex_protocol` through
  `:application.get_key(application, :modules)` and
  `Loopex.LLM.ReqLLM.ProviderBridge` lives in `loopex_llm_reqllm`.

  The third is the ordering: under inherited `set_on_spawn` tracing, the
  sender's entry call proves its exact four token-free arguments. The callback
  waits for adoption completion; the parked sender does nothing until exact
  child readiness supplies its bound `:begin_bootstrap` tuple carrying the
  retained deadline. `exclude_self/2` and its delivery marker complete before
  the sender spawns the sink; the sink is proved to inherit no trace flags, and
  both exclusions plus sink installation and the exact successful
  `{:bootstrap_result, sender_ref, sender_pid, guardian_pid, :ok}` finish
  **before** the guardian sends the bound
  `:credential_context` tuple carrying the token, registry handle, accepted
  socket and invocation nonce. A
  session started concurrently with exclusion is asserted to produce no
  credential-adjacent message from the sender in either order.

  The same ordering case injects `:begin_bootstrap`, `:bootstrap_result`,
  credential context, every phase result and every continuation with a wrong
  `sender_ref`, guardian pid or sender pid, one field at a time; phase messages
  also carry a wrong phase, and continuations carry a changed deadline. It
  injects malformed current-binding `:begin_bootstrap` and credential-context
  tuples, a malformed current-binding bootstrap result, a proper
  `{:error, :unavailable}` bootstrap result, a malformed current-phase result,
  every closed atom from the wrong producer and every producer-permitted error
  result. The parked sender never clears on a malformed or mismatched release,
  bootstrap error never releases credential context, and a phase error never
  receives a continuation. No route, custody call, frame write or invocation
  helper occurs after a mismatch or error. The unchanged deadline performs
  cleanup where the tuple is stale; a matching malformed or
  producer-forbidden result fails immediately as `:unavailable`. Replaying
  every once-valid tuple after its phase has advanced is likewise inert. This
  makes the private messages part of the operation binding rather than
  descriptive tags.

  **The application-message proof is a separate mailbox census, not a trace
  inference.** The named `credential_plane_test.exs` case `custody reply is the
  sole credential-bearing BEAM message` pauses the real registry, custody,
  guardian and raw Task sender at every documented handoff. For each send it
  suspends the intended receiver before releasing the preceding sender, then
  uses a short-lived, unlinked inspector to read that receiver's actual
  `Process.info(pid, :messages)` after enqueue and before receipt. For the
  custody call it observes the complete two-tuple whose first field is that
  live `GenServer.call`'s generated reply tag and whose second field is
  `{:ok, %{credential: canary}}`; seeing the payload outside its real OTP reply
  envelope does not satisfy the case. The inspector reports only a fixed
  non-secret verdict, is killed and awaited before the receiver resumes, and
  cannot leave its copied canary in the test process. The case positively
  confirms the host-owned custody state contains the canary before resolution.
  It enumerates the actual registry request and reply, `:begin_bootstrap`,
  `:bootstrap_result`, `:credential_context`, every phase result and
  continuation, monitor and ownership message, and every gated mailbox. During
  this invocation census, every application message from the adapter edge
  inward except the custody reply is canary-free, and registry and guardian
  state are canary-free. After the frame write, the sender
  tail-calls the non-secret final wait; the case proves its
  `current_function` is the named final-wait MFA, then refutes the canary in
  its current stack, mailbox, process dictionary and forced-crash material
  before `:credential_frame`. It makes no `:sys.get_state`
  claim about a raw Task. Neither call tracing nor the absence of a trace event
  is accepted as evidence that an application message was observed.

  The managed liveness half delays the delivery marker and therefore the Trace
  acknowledgement beyond 5,000 ms under a
  later guardian deadline. Releasing it after that point still succeeds, which
  rules out a hidden default `GenServer.call/2` timeout; holding it through the
  guardian deadline yields `:timeout`. In both cases an ordinary coordinator
  operation through `Control` completes while Trace is delayed and again after
  the sender is killed, proving the asynchronous handshake did not wedge the
  runtime. A companion Direct pair backlogs both named-session and legacy
  traffic under the request's pre-launch absolute deadline. Releasing the
  markers after 5,000 ms but before that instant succeeds; holding them through
  it makes the raw guardian kill and reap sender and sink and report `:timeout`.
  Both observe every required delivery marker before token delivery and return
  Trace pending-call state, monitors and process populations to baseline.

  Four more cover what the capability is for, and each names the surface it
  reads and the two answers that must differ on it.

  **A tracer restart reconstructs the exclusion for a new session.** Surface:
  the tracer's own message stream, private handle table,
  `:trace.session_info(:all)` and the weak old identity. The test first proves
  that `:sys.get_state/1` and an OTP status request expose the table identifier
  and weak identity but no full handle. It retains only `{name, id}`, kills
  Trace, observes the owner-only table disappear and proves that weak identity
  absent. The supervisor restarts the
  tracer, a new session starts, and a long-lived sender retained in `Control`
  from before the restart is asserted to produce **no** message under the new
  session while a
  non-excluded control process in the same session produces one. That production
  fixture proves the ordinary absent path: the sole retained strong-handle
  table died with its owner, so membership is absent and destroy is skipped. A
  separate fault-injection
  fixture deliberately retains one forbidden extra strong handle outside
  `Control` — a state production must never create — so the exact old weak
  identity remains present and destroy returns `true`. Releasing that fixture
  races destroy: `false` or `:badarg` is accepted only when a follow-up
  all-session query proves the exact weak identity absent. Both fixtures confirm
  absence before create and never give Control the strong handle. A design holding a tracer pid in options fails the first half; a case without the
  control process could pass by tracing nothing.

  **A `Control` restart destroys the old tracing state and its managed provider
  children together.** Surface: process monitors and the tracer's session list.
  The adapter integration case pauses the sender after the custody reply, while
  it holds a one-byte canary and before it writes the frame, then kills
  `Control`. Both guardian and sender are direct temporary children of the
  existing owner-workers supervisor. Their monitors must deliver `DOWN` before
  the replacement tracer pid appears, proving owner-group teardown supplied the
  barrier rather than process scheduling luck. The old session and sender both
  terminate and the tracer captures no raw message carrying the canary. After
  the runtime tree recovers, a new trace session and new sender establish a
  fresh exclusion and complete normally. The case does not assert that a
  destroyed session's process flags persist.

  Companion cases assert `Process.info(sender, :trap_exit) ==
  {:trap_exit, false}`, then kill the managed guardian abnormally while its linked sender is held in
  the registry call and in the custody call. A third holds the sender inside
  group-leader-sink spawn or installation after the link and guardian-monitor
  acknowledgement, then kills the guardian before its deadline. Link
  propagation to that non-trapping sender ends the sender and sink even though the sender has not reached
  its receive loop. Control's excluded-pid/MFA state and Trace pending-call and
  monitor state return to baseline. No token, registry handle, channel context,
  credential frame or raw trace canary is delivered, and no sender or sink
  remains. This preserves ADR 0019's abrupt-guardian cleanup even though the two
  processes are direct siblings under `owner_workers`.
  A normal-cleanup companion proves the guardian explicitly stops and awaits the
  sender, since a normal linked exit alone would leave it alive.

  **The set returns to baseline and restores selected patterns.** Surface:
  `Control`'s excluded-pid set and the live session's selected MFA pattern, read
  **in-VM** — no wire method reports either and none is added. The set is
  asserted non-empty while a sender is alive and empty after it exits. While
  excluded, the named MFA produces no raw message; after the last owner exits,
  the same live session again traces it according to its original selection. A
  second sender keeps it excluded until that sender exits. A paired session
  that did not select the MFA remains clear after the last sender exits. Those
  observations separate working monitors and reference counts from a set that
  was never populated, a global restore, or a clear that permanently overwrote
  the host's trace pattern.

  **It fails closed, on every way the capability can be missing.** Surface: the
  invocation's own result, plus the child's record of what it received. With
  the capability or `Control` made immediately unreachable when
  `exclude_self/2` is called, the invocation is asserted to refuse
  `:unavailable`; with the exclusion call held unanswered until the invocation
  deadline, the guardian kills the sender and reports `:timeout`. In both cases
  the child receives **no** credential frame. A composition given a token and
  no capability is asserted to refuse at **composition**, so no call reaches
  the per-invocation branch. A capability that dies after a successful bind is
  asserted to refuse the later invocation as `:unavailable`. Each refusal is
  paired with an ordinary success from a complete, live configuration, and
  every path asserts that the child receives no credential before exclusion is
  confirmed.

  The bind witness uses two live runtimes. Binding a fresh handle to runtime A
  succeeds and the same bind is idempotent. Binding that handle to runtime B
  refuses `:capability_already_bound` before runtime use, child creation, token
  routing or custody access; runtime A remains the stored binding and a later A
  invocation succeeds. The CLI, app-server and daemon composition suites each
  assert the same exact-runtime behavior at their own owner boundary.
- Everywhere else the earlier absolutes stand unchanged: not in guardian
  state, not in an exit reason, not in a crash report, not in an IO request,
  not in a file, not in the environment, not in argv, and in no durable or
  public plane.

**When it is resolved.** Exactly once per invocation, inside the sender
process, between the child's `ready` frame and the credential frame — step 9
above and nowhere else. A resolved value is never cached, never reused for a
second invocation, and never returned to the guardian.

**Rotation.** Per resolution, by construction: the custody process may answer
different bytes for the same token on any later custody reply, and no layer
holds a previous answer to contradict it. Repointing the token's registry row
linearizes at the sender's registry lookup: an invocation whose lookup has not
occurred may follow the new row even if its child is already running; one whose
lookup and custody reply completed keeps that reply for its one frame. Rotating
inside a custody process linearizes at that process's reply. Nothing is
invalidated and no invocation is restarted.

**The guardian owns the deadline outcome; the resolver receives no clock.**
Resolution is bounded by the invocation's existing absolute deadline and by
nothing else; this decision adds no second clock and, after the maintainer's
decision of 2026-09-20, it does not ask the resolver to honour one. The custody
callback takes no deadline argument. Managed-start time consumes that deadline
and no start or ownership transfer resets it. A non-answering managed start
remains a Core owner-group liveness failure while transfer is incomplete. Once
Core has registered the guardian, the sender has been adopted and the guardian
receives its initialize message, the guardian checks the same instant
immediately. It then bounds provider launch and readiness, sender release, the
registry lookup, the custody call, the credential-frame write and the wait for
each result, killing the sender when the instant is reached and reporting
`:timeout` only after its own monotonic clock confirms expiry.

The sender is the enforcement participant at the operation boundary. The exact
`:begin_bootstrap` tuple carries the deadline; the sender retains it and checks
it on receipt and immediately before exclusion and sink installation. It
rechecks the same instant when it receives credential context and immediately
before registry routing. Every phase continuation carries that unchanged
instant, and the sender checks it on receipt and again immediately before the
one operation the continuation permits: custody resolution, credential-frame
write, or normal exit from the already non-secret final wait. A valid message queued before the deadline but
consumed at or after it therefore loses. The sender starts no next operation,
scrubs any custody bytes it still holds and exits with the fixed non-secret
`:credential_deadline` reason. That reason is not proof of time: the guardian
still consults its own clock before classifying `:timeout`, and starts the
generic invocation helper only after exact normal sender `DOWN` and a final
pre-deadline check.

An earlier draft passed an absolute monotonic instant to the resolver and
relied on it to answer in time. That is withdrawn: it made every host's
resolver responsible for a safety property the adapter must have whatever the
host wrote, and a resolver that simply blocked would have hung the invocation
past its deadline. Enforcement belongs to the guardian that can kill the
blocked sender and to the sender that can refuse a late release before crossing
a phase boundary. The resolver's only obligation is to answer or not.

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
| `:unavailable` | The managed starter, credential sender or guardian, tracing capability, direct exclusion, registry, custody process or frame writer | Immediate guardian start, registration, authorization, sender start or adoption refusal; an unexpected sender `DOWN` before expiry, including normal exit outside the final-exit state; immediate sink spawn or installation failure before token delivery; a capability or `Control` immediately unreachable; a still-live Direct session that cannot be cleared or verified; a missing registry row, gone registry, dead custody process or custody `:unavailable`; a malformed successful reply; or an immediate codec/socket write failure. None falls back to raw spawning or another transport. A start that never answers remains a Core owner-group liveness failure outside this private set |
| `:timeout` | The guardian | Managed mode's unchanged deadline was already elapsed at initialize, reached during provider launch/readiness, sender release, sink installation, exclusion, registry lookup, custody resolution or frame write, or confirmed when any sender `DOWN` is consumed; or Direct mode's pre-launch absolute instant was reached during inherited-session clearing or a later step |

An earlier draft left the first two unnamed and folded a malformed successful
reply nowhere at all, which meant three real failures had no atom to carry.
Anything returned outside this set is treated as `:unavailable`, because a
host-authored term is exactly where a secret could be smuggled into a reason.
The set is also producer-scoped. The registry may originate only
`:unavailable`; every other registry reply, including another in-set atom, is
normalized to `:unavailable`. Custody may originate only `:missing`,
`:expired`, or `:unavailable`; if it returns another in-set atom such as
`:timeout`, `:oversized`, `:no_token`, or `:invalid_token`, the sender
normalizes it to `:unavailable`. Those atoms remain reserved for the guardian,
sender bound check, or adapter preflight named in the table.
All seven atoms carry no content. They form a private adapter classification
set and remain observable in adapter tests; only post-spawn classes travel the
sender-to-guardian protocol. They are not put in an exit reason,
ADR 0029 child terminal, public event or operator diagnostic.

**They are private adapter classes, not a new result or diagnostic shape.**
`ProviderBridge.complete` maps preflight `:no_token` and `:invalid_token`
before it spawns anything; the guardian maps the post-spawn classes. Every one
becomes the existing generic `Loopex.Model` refusal;
`complete/3` keeps that released shape unchanged. ADR 0029's child terminal is
also unchanged: credential resolution precedes the frame and may precede a
child terminal entirely, so this decision does not pretend its `{stage, class}`
allowlist carries these atoms. Tests observe the private guardian result under
the adapter harness before the generic mapping. Widening either public result
or accepted diagnostic would require a separate decision.

**What the private adapter path reports.** It returns `:ok` or
`{:error, reason}` from that same closed set, never a bare `:error`. Preflight
handles `:no_token` and `:invalid_token` before spawning. An immediate managed
gate refusal reports `:unavailable`; a never-answering start remains Core's
liveness failure. After spawn, the sender
can report `:missing` or `:expired` from custody, `:oversized` from its bound
check, and `:unavailable` from immediate exclusion or Direct clearing,
registry/custody refusal, malformed replies or immediate frame-write failure.
The guardian also reports `:unavailable` for any unexpected sender `DOWN`
before the deadline; it never forwards the process reason.
The guardian owns `:timeout`: in managed mode for an elapsed initialize or
unfinished provider readiness, sender release, exclusion, registry lookup,
custody resolution or frame write; in Direct mode for inherited-session clear
or any later step that crosses the request's pre-launch absolute instant. This accounting lets the guardian
distinguish a refusal from silence without accepting a host-authored reason.
No result carries the resolved value, token or a host-authored string.

**Failures.** Each has a bounded non-secret private reason before the guardian
maps it to the existing generic model refusal, and each
leaves no retained copy of anything the resolver may have produced:

| Condition | Outcome |
| --- | --- |
| No `:credential_token` in the configuration | `:no_token`, refused before the namespace is created and before any child is spawned |
| Malformed token — anything that is not the exact `%CredentialToken{}` map with only `__struct__` and a 16-byte `id`, a bare binary or an extra-key struct-shaped map included | `:invalid_token`, refused before any lookup and before any child is spawned. The exact struct is what makes this decidable: a credential is a bare binary, and no content test separates one from a token |
| A token is configured without an exact `%CredentialRegistry.Handle{}` map that passes field validation, including a forged extra key | Refused at composition; no invocation, namespace or child starts |
| A token is configured without an exact capability handle bound to the returned runtime, or a handle already bound to another runtime | Refused at composition; a cross-runtime bind returns `:capability_already_bound`, preserves the original binding, and starts no invocation or child and routes no token |
| The managed path refuses guardian start, Core registration, guardian authorization, sender start or sender adoption | `:unavailable`; partial children are stopped in reverse order, no provider action starts, and the adapter never falls back to raw spawning. A start that never answers is instead the owner-group/runtime liveness failure described above, outside the seven adapter atoms |
| The absolute invocation deadline has elapsed when the adopted pair is initialized, or expires before exact provider readiness | The guardian performs reverse cleanup and reports `{:error, :timeout}`; the parked sender receives no `begin_bootstrap`, token, registry handle, socket or nonce |
| The sender returns exact `{:bootstrap_result, sender_ref, sender_pid, guardian_pid, {:error, :unavailable}}` | `:unavailable`; the guardian sends no credential context and tears down the provider tree, sender and sink |
| A bootstrap or phase tuple has a wrong or stale reference, pid, phase or deadline | It is ignored and cannot advance the current operation; the unchanged deadline eventually performs cleanup. A matching current-binding result with a malformed shape or producer-forbidden atom is immediate `:unavailable` |
| A producer returns an allowed phase error | The sender reports that error in the exact bound phase-result tuple; the guardian sends no continuation and maps the normalized closed atom. No later custody call, frame write or invocation helper starts |
| The sender consumes `:begin_bootstrap`, credential context or any phase continuation at or after the retained instant | It starts no newly permitted operation, scrubs any custody bytes and exits with fixed non-secret reason `:credential_deadline`; the guardian reports `:timeout` only after its own clock confirms expiry. At the custody-to-frame cut no credential frame is written; at the final cut no invocation helper starts |
| The guardian observes any sender `DOWN` other than the exact normal `DOWN` expected in final-exit state | Before the deadline it reports `:unavailable`; at or after the deadline it reports `:timeout` only after checking its own clock. It tears down the sink and provider tree, starts no invocation helper and never exposes the sender's raw reason |
| The capability or `Control` is immediately unreachable when the sender asks for exclusion | `:unavailable`, before the guardian sends the token or registry handle and before custody is reached |
| Exclusion remains unanswered when the invocation deadline is reached | The guardian kills the sender and reports `{:error, :timeout}`, before sending the token or registry handle |
| Direct mode cannot clear or verify a still-live inherited named or legacy trace session | `:unavailable`, before token delivery. A session confirmed destroyed during the operation is absent and does not cause refusal |
| Direct mode reaches its pre-launch absolute deadline while clearing an inherited session, resolving custody or writing the frame | The raw guardian kills and reaps its linked-and-monitored sender and sink and reports `:timeout`; no later frame can be written |
| The Direct guardian exits abnormally or is killed while its sender is blocked in clear, custody or frame write | The link kills the non-trapping sender, the sender's link/monitor relation ends its sink, and no late frame is written. Normal guardian cleanup instead stops and awaits both before returning |
| A successful custody reply that is malformed — not `{:ok, %{credential: binary}}` with exactly that one map key, a bare binary or extra-key success map included | `:unavailable`; malformed content is refused rather than widening the one exact byte-bearing dataflow shape. Trace exclusion, not that shape, protects the bytes |
| The registry holds no row for the token, a valid handle's process is gone, the route returns anything except `{:error, :unavailable}` or one exact valid `{:ok, custody_ref}` — including another in-set error atom, an arbitrary term, or a malformed or extra-key successful reference — or the custody process is dead | `:unavailable`. The host recomposes; nothing is reconstructed, because the registry holds no bytes to reconstruct from |
| Custody answers `{:error, :missing}` or `{:error, :expired}` | The sender reports `{:error, that_atom}` privately; the guardian maps it to ADR 0019's existing generic credential-send failure and tears the child down. No ADR 0029 terminal or public diagnostic gains the atom |
| Custody answers `{:error, :unavailable}`, anything outside the closed set, or an in-set atom reserved for another producer (`:timeout`, `:oversized`, `:no_token`, or `:invalid_token`) | The same path, reported as `:unavailable` |
| Registry lookup or custody resolution has not completed when the guardian's invocation deadline is reached | The **guardian** kills the sender and reports `{:error, :timeout}`, distinct from every refusal; the sender's stack goes with it. A registry or custody process that simply blocks cannot hang the invocation, because nothing depends on it noticing the time |
| Resolved value outside 1 to 65,536 bytes | Refused in the sender before the frame is written, exactly as the size check refuses today, reported as `{:error, :oversized}` |
| `ProviderCodec.send/3` or the socket fails immediately while writing the credential frame | The sender scrubs its local reference, reports `{:error, :unavailable}` and the guardian tears the child down; no raw socket or codec reason crosses the boundary |
| The credential-frame write remains pending at the invocation deadline | The guardian kills the sender and reports `{:error, :timeout}`; the one deadline covers the write as well as exclusion and resolution |
| Two resolutions in flight at once | Independent **successes**. Each invocation has its own sender and resolves for itself; the adapter serialises nothing and shares nothing between them, and two answers for the same token may differ. Concurrency is not a refusal condition, and a custody process that refused concurrent callers would reintroduce exactly the serialisation this decision exists to remove |

No failure is retried inside the adapter. Whether to attempt again is the
coordinator's durable decision under ADR 0018, unchanged.

### Scrub points

- **In the sender.** The sender is started with a token-free argument containing
  only `sender_ref`, the callback-owner pid, guardian pid and tracing
  capability. It completes exact authorization and guardian adoption, drops its
  callback monitor and parks. Exact provider readiness delivers the bound
  `:begin_bootstrap` tuple carrying the retained absolute deadline; only then
  does it call `exclude_self/2` and drain the
  delivery barrier. From that untraced process it then
  spawns and installs its group-leader sink; the sink inherits no trace flags,
  and the sender verifies both itself and the sink clear before returning the
  exact `{:bootstrap_result, sender_ref, sender_pid, guardian_pid, :ok}` tuple.
  Immediate exclusion or sink failure instead returns the same tuple with
  `{:error, :unavailable}`; a malformed result with the current binding fails
  closed, while a wrong or stale binding cannot release anything. Only exact
  success before the deadline lets the guardian send the bound
  `:credential_context` tuple with the token, registry handle, accepted socket
  and invocation nonce. It looks the token up in that registry and parks until
  the guardian accepts its exact non-secret `:registry` phase result and replies
  with the exact continuation carrying the unchanged deadline. The sender
  rechecks that instant on receipt and immediately before it calls the custody
  process, receives the
  one permitted credential-bearing reply, validates the size bound and parks
  again; the `:custody` result/continuation exchange carries no bytes. It
  rechecks the unchanged instant on receipt and immediately before writing the
  frame. On successful return it drops every credential-bearing logical
  reference and tail-calls a non-secret final wait, which sends the exact
  `:credential_frame` phase result and parks. Only the matching final
  continuation permits normal sender exit. The guardian consumes that exact
  normal sender monitor `DOWN`, rechecks
  the deadline and only then starts the generic invocation-frame helper. An
  immediate refusal sends the producer-scoped `{:error, reason}` in the exact
  phase-result tuple; no error receives a continuation. If a continuation is
  consumed at or after the instant, the sender starts no next operation, scrubs
  any custody bytes it still holds and exits with the fixed non-secret
  `:credential_deadline` reason. Neither the initial argument nor any
  sender message before exclusion holds the token, registry handle, channel
  context or credential. The guardian's post-adoption initialize message may
  hold the opaque token and registry handle, but never credential bytes. In the
  parent the value exists in the custody process and,
  for the duration of one send, in this process's own mailbox and stack, and
  nowhere else — no guardian state, no exit reason and no crash report can
  hold it.
- **In the parent's environment.** The adapter performs no *credential*
  environment read by any route. That is the property this decision owns, and
  it is narrower than "no environment read at all" on purpose.
  `Loopex.LLM.ReqLLM.credential_variable/0` remains the common configured name
  that the reference CLI, app-server host, daemon and direct real-provider
  caller read and delete at their own composition boundary; those hosts may
  also reuse the name in failure text. `ProviderBridge`, which
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

The new managed sender gets its own crash-report proof rather than borrowing
the provider child's cases below. The case pauses the sender after the custody
reply and forces raise, exit and kill cuts. It captures Logger output, the
Task/supervisor report and guardian result, and refutes the canary in the
initial child argument, exception/exit reason, stack, message and metadata.
For each cut, a sender `DOWN` consumed before the absolute instant maps exactly
to `:unavailable`, starts no invocation helper, tears down the sink and provider
tree, and returns their populations plus trace membership to the sampled
baselines. Paired cases hold the same `DOWN` until the instant has passed; the
guardian checks its own clock and reports `:timeout`, again with no invocation
helper and the same baselines. No case exposes the raw sender reason. A
companion assertion fixes the guardian's initial argument at exactly
`{guardian_ref, callback_owner_pid, stop_reference}`; the sender's contains only
`sender_ref`, callback owner, guardian and capability. Credential bytes arrive only after adoption,
readiness and exclusion. Companion cases force each immediate managed-gate
failure, immediate group-leader-sink installation failure, a blocked sink
installation through the guardian deadline, a still-live Direct session whose
clear/verification fails, immediate frame write failure and a blocked frame
write at the guardian deadline. They assert the closed classes above and no
token delivery before exclusion. A Direct session destroyed during clear is
the paired success case.

Direct lifetime evidence holds the raw sender separately at inherited-session
clear, custody resolution and frame write. At each cut, abnormal guardian exit
and `:kill` promptly reap sender and sink, write no late frame and return process
and Trace bookkeeping to baseline; normal cleanup explicitly stops and awaits
both. The paired deadline case releases a clear after 5,000 ms but before the
request's pre-launch absolute instant and succeeds, then holds the same clear
through that instant and observes `:timeout` with the same baselines.

Managed-start evidence exercises the two gates separately. First it suspends
the exact `owner_workers` before the guardian materializes, ends the calling
scope, then resumes the supervisor. A late guardian observes callback-owner
`DOWN` and exits inert; guardian, sender, start-proxy, receiver, generic
phase-send-helper, sink, Port, carrier, guard and provider-BEAM populations all
return to baseline. A second case pauses the guardian's start
acknowledgement before Core registration and kills the callback; the guardian
exits inert, with no retainer registration or provider action. A third pauses
the exact guardian-authorization acknowledgement after retainer-monitor
installation and proves the callback cannot start a sender or send initialize
until that acknowledgement arrives. Separate sender
cases pause before materialization and after start acknowledgement but before
guardian adoption, and after the guardian's adoption reply but before the
sender's adoption-complete acknowledgement to the callback, then end the scope
or kill the guardian. A late or unadopted sender exits inert; initialize is not
sent before adoption completion, and the registered guardian is stopped through
Core's exact stop protocol. No case produces a `:begin_bootstrap` tuple, exclusion,
sink, route, custody or frame work.

Proxy evidence forces supervised-start refusal, a caught starter exit, proxy
result before child acknowledgement, child acknowledgement before proxy result,
and the three legal cross-sender orders around proxy termination:
child acknowledgement then result then proxy `DOWN`; result then child
acknowledgement then proxy `DOWN`; and result then proxy `DOWN` then child
acknowledgement. Same-sender ordering forbids proxy `DOWN` before its result.
Only matching success plus matching child acknowledgement proceeds; refusal or
proxy loss without a result maps to `:unavailable`, reverse-cleans the child,
and no second proxy starts. Separate guardian and sender cases kill the child
after each possible first disclosure and before ownership transfer; the
callback's child monitor wins `:unavailable`, so neither wait can hang before
the invocation deadline is active. Population sampling asserts at most one
proxy live, and no proxy remains before Core registration or sender
authorization.

The paired authorized case proves ordering at each ownership cut: guardian
authorization follows `ProviderLifetime.register/2` and retainer-monitor
installation; sender authorization finishes only after guardian link, exact
adoption and sender-monitor acknowledgement. It then lets the callback return
its normal model result. The guardian remains retained through ADR 0019's
post-result cleanup wait and sender/provider cleanup remains governed by Core's
retainer path. Ordinary callback completion therefore cannot mimic
pre-authorization cancellation. Immediate refusal at any gate returns
`:unavailable`, reverses partial children and never falls back to raw spawn; a
non-answering start remains the owner-group liveness class.

After both transfers, one case holds the sender parked and kills the guardian;
another refuses provider bootstrap before exact readiness. Both prove no
`:begin_bootstrap` tuple, exclusion, sink, token, registry, socket, nonce, custody or
frame and return every process population to baseline. Post-readiness cases
block sink installation until the unchanged absolute deadline and kill the
guardian abnormally. The first reports `:timeout`; the second promptly reaps
sender and sink and restores trace baselines. Releasing the same held operation
after 5,000 ms but before the real deadline succeeds, proving that neither
managed setup nor a hidden call timeout reset or shortened the one clock.
For provider readiness, the exact `:bootstrap_result` and every credential phase
result, paired guardian-side cases queue the bound success immediately before
the absolute instant and force both result/timer mailbox orders. A result
consumed before the instant advances once; the same result consumed at or after
it is cleanup-only and the guardian reports `:timeout`. A queued timer never
defeats a result the guardian validated before the instant, and a queued result
never extends the deadline.

Separate sender-side pairs queue valid `:begin_bootstrap`, credential context
and each exact phase continuation before the instant. One suspends the sender
before receipt; the other lets it pass the receipt-time check and suspends it at
a test barrier immediately before the permitted operation. Both resume at or
after the instant. The sender therefore starts no exclusion, sink, registry
lookup, custody call, credential-frame write or normal final exit transition
after expiry. The `:begin_bootstrap` pre-operation form runs once immediately
before exclusion and again immediately before sink installation. In the
custody-to-frame pair it already holds the one permitted
credential-bearing reply; the pre-write suspension proves the second check
scrubs those bytes, writes no frame and exits with the fixed non-secret
`:credential_deadline` reason. At the final-continuation
cut the credential frame may already exist, but the sender is already in its
non-secret final wait. The case proves that exact current function and refutes
the canary in its mailbox, process dictionary and forced-crash material before
the continuation, then
proves the sender's deadline exit and the guardian's own clock check prevent
the invocation helper from starting.
Every case proves that the unchanged deadline, rather than send time, governs
acceptance and that the guardian reports `:timeout` only after its own clock
confirms expiry. Each awaits cleanup and returns the sender, sink, generic
phase-send-helper and provider-tree populations plus trace membership to their
sampled baselines.

Sink lifetime has a separate two-way witness. Ordinary sender success produces
the sender-monitor `DOWN` and returns the sink population to baseline; abnormal
or kill sender exit reaches the non-trapping sink through its link and does so
promptly. This prevents the false inference that a normal linked exit alone
would stop the sink.

The guardian receives the valid token and registry handle in its initialize
message after its token-free supervised start; the accepted socket and nonce
remain later channel context. A case crashes it immediately after initialize,
before readiness or channel context, and captures the complete
Task/supervisor report and the owner-observed `EXIT`, and refutes fixed token
and registry-incarnation canaries in the initial argument, exception or exit
reason, stack, queued and last messages, state, metadata and log. The crash
trigger carries a fixed non-secret reason. That proof prevents the supervised
child specification from being safe while the later message path is not.

Every case below exists today in
`apps/loopex_llm_reqllm/test/credential_plane_test.exs`. Each is re-pointed at
per-invocation token resolution through the composition-bound token — the module's `setup` and the two rotation cases
stop writing the process-wide variable, and each fixture composes its own
custody process and registry row — and each must hold with its assertion unchanged in meaning:

| Claim | Case |
| --- | --- |
| Version refusal before any credential | `actual version two companion refuses version one bootstrap before readiness or credential` |
| Bootstrap refusal before any credential | `invalid protected bootstrap cannot receive a credential or dispatch` |
| Late delivery after expiry is impossible | `expired bootstrap cannot deliver a credential later or relaunch` |
| Rotation between invocations | `a child transport raise after environment rotation cannot expose its request credential` |
| Two live credentials in one VM, held by two composed runtimes | `one child diagnostic containing two concurrently live synthetic keys cannot escape` |
| Sink loss | `loss of child diagnostic protection cannot leak its credential` |
| One child's loss does not poison another | `losing one credential-bearing child does not poison another invocation or host logs` |
| Nothing in ordinary host messages | `ordinary guardian messages and results never carry its credential` |
| Returned reasons | `a provider error echoing the key is substituted before it is returned` |
| Child Logger forms and metadata | `ordinary and split actual child Logger messages cannot expose the credential`, `all actual child Logger message forms and metadata stay private`, `repeated credential bytes in actual child metadata cannot reach host channels`, `credential-bearing child metadata keys cannot reach host channels` |
| Crash reports | `a provider request adapter that throws cannot put the credential in a stream-server crash report`, `a provider request adapter that exits cannot put the credential in a stream-server crash report`, `an actual child report containing its own request credential stays private`, `an actual child StreamServer termination cannot forward its credential` |

The launch-boundary witness in
`apps/loopex_llm_reqllm/test/provider_startup_boundaries_test.exs` is re-pointed
more deeply than replacing a fixture. Its observer counts custody-resolution
requests, because observing `System.get_env` after this change would make both
branches report zero and prove nothing. A child that reaches exact readiness
causes exactly one custody resolution. An actual child crash before readiness
causes zero resolutions, zero provider dispatches and no canary in diagnostics.
The case kills the real pre-entry process rather than asking a fake to return an
error.

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

Six proof groups are new:

- **Parent environment**, stated as two checkable things rather than one
  unfalsifiable one. From the completion of composition onward — before,
  during and after a call — **the configured credential name is absent from
  the parent VM's environment**, and **no function in the adapter's call path
  reads the environment for a credential**. "During" is observed from inside
  the call, at the point the child reports readiness. The case composes the
  runtime the way a reference host does, with the variable set, and asserts
  that composition returns having deleted it. Each host suite traces only the
  exact composition owner pid at call level for the chosen
  `System.get_env/1` call whose argument is
  `Loopex.LLM.ReqLLM.credential_variable/0`; return tracing is disabled, so the
  trace contains the configured name and never the returned bytes. Between the
  composition entry and successful return it observes exactly one such call,
  then proves the synthetic canary is in that host's custody through the
  test-only custody fixture and the configured name is absent from the VM
  environment. Explicit zero-read and two-read variants fail the count. The
  exact-owner filter prevents another concurrent process's read from satisfying
  the proof.

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
  carry the same token. A separate same-runtime case proves the property that
  does exist there: concurrent invocations resolve independently, each exact
  custody reply remains bound to its own sender and private frame, rotation
  between resolutions is visible only to the invocation that receives the new
  reply, and no stale or wrong reply can cross-route. It does not claim
  distinct-credential isolation inside one runtime.
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
- **Adapter preflight and invocation failures.** One case for every private
  adapter row of the failure table above: absent token, malformed token,
  managed guardian/sender start failure, an immediately
  unreachable capability or `Control`, an exclusion held past the invocation
  deadline, a still-live Direct session that cannot be cleared or verified and
  a destroyed Direct session that clears successfully, a token with no
  registry row, a gone registry, a malformed successful route reply, a dead
  custody process, each of the three custody refusal atoms — `:missing`,
  `:expired` and `:unavailable` — every wrong-producer in-set custody atom —
  `:timeout`, `:oversized`, `:no_token` and `:invalid_token` — and a custody
  process returning a term outside the closed set, all normalized to
  `:unavailable`; a registry process that
  blocks past the invocation deadline, and a custody process that blocks past
  that deadline (the **guardian**
  kills the sender and reports `:timeout`, asserted **distinct** from every
  refusal so the guardian can tell them apart, and asserted to bound the
  invocation whatever either process does), a value outside the size bound, an
  immediate credential-frame write failure and a credential-frame write held
  through the guardian deadline. Each
  asserts the outcome, its closed-set atom, that no child was spawned where
  the contract says none is, and that no message but the permitted reply, no
  exit reason and no crash report carries the resolved value. The
  two-resolutions-at-once case is a **success** case, not a refusal: two
  same-runtime invocations complete with independently obtained replies bound
  to their own senders and frames. The distinct-credential case composes two
  runtimes, registries and custodians in the same VM and proves that each child
  receives only its own runtime's credential. Paired bootstrap cases make
  the sender's group-leader sink fail immediately and block past the guardian
  deadline: they return `:unavailable` and `:timeout` respectively, deliver no
  token and leave no sink or sender behind.

  Exact-protocol cases mutate one binding field at a time in
  `:begin_bootstrap`, `:bootstrap_result`, credential context, every phase
  result and every continuation; inject malformed releases and current results,
  producer-forbidden atoms, every allowed error and stale once-valid messages;
  and assert that only the exact current success can advance. Error results
  receive no continuation. Separate forced-clock pairs queue each release
  before the deadline, then suspend the sender before receipt and after its
  receipt-time check but before the permitted operation; both resume at or
  after expiry. The `:begin_bootstrap` pair places the pre-operation barrier
  separately before exclusion and before sink installation. They assert both
  checks independently, the fixed
  `:credential_deadline` sender exit, and the guardian's independent clock
  confirmation. The custody-to-frame case pauses with bytes held and proves
  scrub without a credential frame. The final-continuation case pauses in the
  non-secret final wait, proves its exact current function, and refutes the
  canary in its mailbox, process dictionary, current stack and forced-crash
  material before proving no invocation helper starts. Every case awaits
  cleanup and restores the sampled
  sender, sink, helper, provider-tree and trace-membership baselines.

  Malformed-shape cases forge every private struct with a canary-bearing extra
  key: token, registry handle, custody reference and tracing capability handle.
  Each is refused by its exact key-set check before routing or child creation as
  applicable, with no canary in raw traces, rendered entries, diagnostics or
  results. A custody success map with an extra canary-bearing key is likewise
  `:unavailable` before frame writing.

  A missing or malformed registry handle, or a missing, malformed or unbound
  tracing capability, is a composition failure and is proved in each host's
  composition suite below, before runtime use or child creation and with
  reverse cleanup. A live registry with no row for the supplied token is an
  invocation-time `:unavailable`. The composition failures do not map to one
  of the seven private adapter atoms because no adapter invocation exists.

  The exclusion, blocked-registry and blocked-custody witnesses each set the
  guardian deadline beyond 5,000 ms. Releasing the held operation after the
  hidden default but before that deadline succeeds; holding it through the
  later deadline yields the guardian's `:timeout`. Thus an implementation that
  leaves any one of the three waits on `GenServer.call/2`'s default cannot pass.
- **Tracing, in three cases matching the two tiers above.** Under the
  **default** trace configuration, a session at the `arguments` level over a
  real invocation produces no entry naming `route_credential/2`,
  `receive_custody_reply/2` or `write_credential_frame/2`, no raw trace
  message for them, and no credential bytes in any captured raw trace message,
  rendered entry or IO request outside the one permitted custody reply. The
  token can traverse core in model options before the sender exists;
  the structured-entry redaction proof above, rather than sender exclusion,
  keeps it out of rendered entries. The bridge calls stay absent because the
  adapter is in no namespace wildcard. Under a configuration that
  **explicitly names `:gen_tcp`**, `Loopex.LLM.ReqLLM.ProviderBridge` and
  `Loopex.LLM.ReqLLM.ProviderCodec`, the tracer captures the expected token-free
  bootstrap entry, then is asserted to receive **no further raw trace message
  from the sender process after the exclusion acknowledgement**, while a non-excluded
  control process making the same `:gen_tcp.send/2` call in the same session
  is asserted to produce one — the pre-delivery property read where it holds,
  and a case that cannot pass by tracing nothing. A third case asserts all
  three functions exist with their exact identities and separately proves that
  the 128-bit token is placeholdered under `:credential_token` before the
  sender exists. It does not render credential bytes as a safety proof: the
  first case must show the one-byte canary never reaches any captured raw
  message or rendered entry, so neither of the first two cases can pass
  vacuously or against the wrong signatures.
- **Credential-bearing application messages, by mailbox rather than trace.**
  `apps/loopex_llm_reqllm/test/credential_plane_test.exs` contains the exact
  case `custody reply is the sole credential-bearing BEAM message`. At
  deterministic phase pauses it positively finds the one-byte canary in the
  complete `GenServer.call` reply envelope queued in the suspended sender's
  mailbox, with that live call's generated reply tag and the exact custody
  success as its payload, and enumerates
  the registry, custody, guardian and sender application-message sequence, and
  refutes that canary in every other adapter-edge-inward application-message
  payload during that invocation census. Each mailbox
  read occurs in an unlinked one-use inspector that reports a fixed non-secret
  verdict, is killed and awaited, and never copies the canary into the test
  process. It then proves the raw Task has tail-called its non-secret final
  wait by its exact current function and refutes the canary in its mailbox,
  process dictionary, current stack and forced-crash material before
  `:credential_frame`. The host-owned custody
  process remains the expected authoritative holder between invocations. Call-only tracing and trace
  absence cannot satisfy this case.
- **The host-owned processes, proved at each host rather than in the adapter.** The
  adapter's test tree cannot prove a claim about the CLI's or the daemon's
  composition, and an earlier draft filed all three there. Each case lives
  where its subject lives, named to the file and the case so the closure
  matrix can be checked against a list rather than a directory:

  | Host | File | Cases | Lane |
  | --- | --- | --- | --- |
  | Reference CLI | `apps/loopex_cli/test/credential_custody_test.exs` | `reads the credential variable exactly once at composition`; `deletes the credential variable from the VM environment`; `custody and registry redact complete forced-crash reports`; `starts the tracing capability before the runtime and binds it before reporting composition success`; `binding the same handle to a different runtime refuses before runtime use or child creation and preserves the first binding`; `missing, malformed or extra-key registry handle refuses before runtime use or child creation`; `missing, malformed, extra-key or unbound capability refuses before runtime use or child creation`; `every such refusal reverses already-started registry, custody and capability edges`; `registry, custody and capability stop on normal stop, failed start and owner loss` | fast |
  | App-server host | `apps/loopex_app_server/test/credential_custody_test.exs` | the same nine | fast |
  | Daemon | `apps/loopex_daemon/test/credential_custody_test.exs` | the same nine | fast |

  Each proves that composition reads the variable exactly once using the
  call-only exact-owner trace above, transfers the synthetic canary into
  custody, and deletes the name from the VM's environment. It then forces custody to crash while handling a
  canary-bearing rotation request and the registry to crash while handling a
  canary-bearing install request. For each process it captures the whole OTP
  report and owner-observed `EXIT`, and refutes the canary in the initial call,
  last message, state, reason, metadata and log. The test asserts that
  `format_status/1` replaced `state`, `message` and `reason` and emptied `log`,
  rather than passing because no report was emitted. Each host also proves that the capability's
  start-bind-stop lifecycle follows its host owner. Each also proves malformed
  or missing registry handles and malformed, missing or unbound tracing
  capabilities refuse before runtime use or child creation and unwind any edge
  already started. Each also binds one handle to runtime A, refuses its reuse
  for runtime B, proves the A binding unchanged, and completes a later A call.
  The adapter's own tree keeps only what is the adapter's
  to prove: that it reads no environment variable for a credential and that
  the token and resolution contract behaves.

The parent-environment, cross-runtime credential-isolation and same-runtime
independent-resolution proofs and the resolution failure cases belong in
`credential_plane_test.exs` beside the cases they
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
that the sender's exact initial argument is token-free, its managed ownership
and guardian adoption complete before initialize, it remains parked until
exact child readiness, and it receives the token and registry handle only
after synchronous exclusion; that `:begin_bootstrap` carries the retained
deadline, the exact bootstrap result union alone can release credential
context, and each producer-scoped phase result advances only through its exact
continuation carrying that unchanged instant; that the sender checks the clock
on receipt and immediately before each permitted operation, an error never
gets a continuation, and wrong, stale or malformed tuples cannot advance; that
the custody-to-frame deadline cut scrubs held bytes without a frame and the
post-write final wait retains no credential before its result or continuation;
that the final deadline cut starts no invocation helper; that an unexpected
sender `DOWN` consumed before expiry maps to `:unavailable`, the same signal
consumed after expiry maps to `:timeout` only after the guardian checks its
clock, and neither exposes the process reason; that the mandatory tracing capability
starts before the runtime, binds before composition reports success and stops
with its host owner on every exit path; that immediate capability loss refuses
`:unavailable` while a delayed exclusion ends only at the guardian's invocation
deadline as `:timeout`; that trace-session destruction removes its process
flags, a tracer restart reconstructs exclusions from `Control`, a `Control`
restart tears down owner-workers and awaits their managed guardians and senders
before the replacement tracer starts, the full handles live only in Trace's
private owner-only table and never in callback state or an exported status,
Trace status redaction keeps raw token and registry-handle material in its last
message out of the complete crash report, and the last MFA owner restores every live session's
selected pattern;
that the resolved value has no path into guardian state, an adapter-edge-inward
BEAM message during the invocation other than the one permitted reply, an exit
reason, a crash report, an IO request, a file
or the environment; that every row of the failure table refuses without
retaining a copy; that managed mode allocates its absolute invocation deadline
before either start, never resets it and, after guardian registration, exact
sender adoption and initialize, applies it to provider launch/readiness, sender
release, exclusion, registry routing, custody resolution and the
credential-frame write, with `:timeout` reported only after the guardian's own
clock confirms expiry; that Direct mode carries its request's same pre-launch
absolute instant through inherited-session clearing, sink installation,
routing, custody and frame write; that an
immediate managed-gate refusal is `:unavailable` while a non-answering
`owner_workers` start is an owner-group/runtime liveness
failure outside that clock; that the cleanup and abandonment paths do not
resurrect a value; that immediate loss of custody, registry or capability
answers `:unavailable` rather than reconstructing or bypassing anything; that a
host supplying no token is refused
rather than falling back to an ambient read; and, on the host side of the
boundary, that each reference implementation reads the operator's variable
once, deletes it, gives custody and registry complete `format_status/1`
redaction for state, message, reason and log, and registers a token that carries
no bytes; and that a guardian crashing after its initialize message exposes no
token or registry-incarnation canary in the complete Task/supervisor report or
owner-observed exit. Its record is retained with the milestone's evidence.

### Concurrency, as a measurement

With the process-wide read gone, the **eleven** `loopex_llm_reqllm` modules
that declare `async: false` for that reason may declare `async: true` one at a
time — the other two of the thirteen stay serial on reasons of their own, a
process-wide environment sentinel and a shared build artifact — each kept only after the application's suite stays green across several
seeds, exactly as the M4 speed work converted the other twenty-one modules.
The result is recorded against the baseline in the
[verification companion](../developer/verification-technical.md#technical-verification-speed):
that application was the fast check's critical path at M4 closure, with 96% of
its time in those thirteen modules. Any module that stays serial keeps its
reason recorded beside it.

<a id="technical-adr-0034-serial-modules"></a>
**The thirteen, by name, because the count has been wrong three times.** Every
one of those corrections came from reading a glob instead of running the
suite, so the list is written out once here and every other passage in this
repository cites it rather than recounting.

| # | Module | Serial because |
| --- | --- | --- |
| 1 | `test/adapter_test.exs` | credential variable |
| 2 | `test/credential_plane_test.exs` | credential variable |
| 3 | `test/m0_child_environment_conformance_test.exs` | **not the credential variable** — it writes a process-wide environment sentinel of its own (`LOOPEX_M0_CHILDENV_PARENT_ONLY`) and mutates `PATH` |
| 4 | `test/provider_attempt_adapter_contract_test.exs` | credential variable |
| 5 | `test/provider_backpressure_observer_test.exs` | credential variable |
| 6 | `test/provider_backpressure_test.exs` | credential variable |
| 7 | `test/provider_bridge_test.exs` | credential variable |
| 8 | `test/provider_build_test.exs` | **not the credential variable** — it builds a shared artifact (the provider build identity `.beam`) against the application's own `mix.exs` |
| 9 | `test/provider_retainer_boundaries_test.exs` | credential variable |
| 10 | `test/provider_startup_boundaries_test.exs` | credential variable |
| 11 | `test/provider_test.exs` | credential variable |
| 12 | `test/real_model_lane_test.exs` | credential variable |
| 13 | `test/support/provider_entry_test.exs` | credential variable — and the module the count kept losing, for living under `test/support/` |

**Eleven** reference the credential variable, directly or through
`Adapter.credential_variable()`; **two** do not and would stay serial whatever
this decision does. Removing the process-wide read therefore frees eleven, not
thirteen.

**The derivation is executed, not globbed**, which is what row 13 costs when
it is skipped. `apps/loopex_llm_reqllm` sets no `test_paths`, no
`test_pattern` and no `elixirc_paths`, so Mix's default pattern applies
**recursively** under `test/`, and its `test_ignore_filters` name three
non-`_test` fixture and diagnostic files and nothing else
(`apps/loopex_llm_reqllm/mix.exs:16-22`). Measured in that application:
`mix test --only <an unused tag>` reports **179 excluded**; the eighteen
`test/*_test.exs` files alone report **164**; the difference of **15** is
exactly what `mix test test/support/provider_entry_test.exs` runs. A
non-recursive scan finds twelve serial modules and misses the thirteenth under
`test/support/`; it is wrong every time. The measurement is evidence about the change, never
a condition a test may be weakened to meet.

<a id="technical-adr-0034-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0034-provider-credential-handoff-over-bootstrap-channel.md#concept-adr-0034-consequences).

The `Loopex.Model` callbacks, the public protocol and its generations, public
events, snapshots, artifacts, the executor protocol and every durable record
are untouched, so no vector, schema or migration is affected. The experimental
public `complete_prompt/3` helper keeps its arity and result union but changes
its accepted options: callers compose ephemeral custody and a routing registry
and pass their token and handle; an old environment-only call refuses before
launch. The private codec's version and frame kinds are unchanged, and a
child built from the same manifest digest behaves identically; the build
manifest is not revised by this decision.

The one visible change is host composition: a host that starts a runtime with
this adapter puts a credential token, registry handle and tracing capability in
the model options and owns the registry, custody process and capability behind
them. It starts those three before the runtime, binds the capability to the
runtime reference before reporting composition success, and stops them on
normal stop, failed start and owner loss. The reference CLI, app-server host,
M5 daemon and
real-provider lane keep reading `LOOPEX_PROVIDER_API_KEY` where they compose,
and delete it there, so an operator's setup is unchanged and the release
check's credential frame is unchanged. The lane's accepted direct
`complete_prompt/3` call uses the adapter-created no-runtime Direct capability,
ephemeral registry/custody and unmanaged lifetime just defined; runtime model
options cannot select that mode. The direct caller/host layer in
`provider_test.exs` reads and deletes the environment value, starts that
ephemeral custody and registry, and passes only token plus handles into
`complete_prompt/3`; the helper never reads the environment or receives
credential bytes. An embedder that relied on the adapter reading the
environment for it must pass a token and registry handle instead; omission
refuses with `:no_token` before launch and never falls back. The migration is
stated in `docs/operator/runtime.md`,
`docs/developer/runtime-and-embedding.md`, and
`docs/developer/compatibility-surfaces.md`.

Rollback is a coordinated code rollback of the adapter, the core
trace-exclusion support and the CLI, app-server and daemon composition changes.
Hosts resume supplying the credential by the pre-M5 mechanism in the same
change; no host may keep passing a token to an adapter that no longer resolves
one. Nothing durable, no root and no protocol generation records which
mechanism delivered a credential to a process that has since exited, so a
rollback needs no data migration and leaves no retained trace state to repair.

Acceptance binds this complete pair at the exact candidate the maintainer
names in the governance record. Its claims remain unproved until the tests the
M5 plan maps to Outcome 6 exist and pass, the security review is recorded, and
Outcome 5 closes against those same bytes.
