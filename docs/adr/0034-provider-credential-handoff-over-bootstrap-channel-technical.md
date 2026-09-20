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

### The reference, its resolver, and its failures

The per-invocation option is `:credential_reference`, one member of the
configuration map the host already supplies to `complete/3`. Its value is
`{resolver_module, reference_term}`:

- `resolver_module` is an atom naming a module that implements
  `Loopex.LLM.ReqLLM.CredentialResolver`, one callback,
  `resolve(reference_term, deadline) :: {:ok, binary()} | {:error, reason}`,
  where `deadline` is an **absolute monotonic instant** in native units, not a
  remaining duration — a duration is stale the moment it is computed, and the
  sender and the resolver are different processes. `reason` comes from the
  closed set below and never from the resolver's own vocabulary;
- `reference_term` is bounded plain boundary data — at most 256 bytes when
  encoded by the repository's canonical encoding, and never a PID, port,
  function, monitor or reference. It names which credential is wanted; it is
  not the credential and carries no authority of its own.

Any other shape, including a bare binary that could be the bytes themselves,
is refused as an invalid option before any child is spawned. The behaviour
exists rather than a closure because the reference travels in configuration
that is copied between processes and may be printed by a crash report, and
plain boundary data is what may travel there.

**Owner and custody.** The resolver is the host's. The adapter declares the
behaviour, calls it, and knows nothing about where the bytes live. Each
reference implementation states its own custody and proves it for itself:
the reference CLI, the app-server host and the M5 daemon read
`Loopex.LLM.ReqLLM.credential_variable/0` exactly once, where they compose the
runtime, delete that name from the VM's environment in the same step, and hold
the bytes in one host-owned custody process, registered under the runtime
reference rather than a global name, whose `format_status/1` redacts its state
and which answers `resolve/2` only for its own reference term. The
real-provider lane composes the same way. Nothing in the adapter depends on
that arrangement, and a different host may keep the bytes anywhere it can
defend.

**Exactly one credential-bearing transfer exists in the parent, and it is
named.** An earlier draft said the value never appears in a message while also
putting custody in a long-lived process the sender asks — which cannot both be
true, because answering is a message. The contract is a permission with a
boundary, not an absolute:

- The **only** permitted credential-bearing transfer in the parent is the
  custody process's reply to `resolve/2`, carrying `{:ok, bytes}` to the one
  sender process that asked. It is bounded by the same 1..65,536-byte rule as
  the frame, it is never logged, never forwarded, and never held after the
  frame is written.
- It is deliberately the same class of act as the credential frame write: one
  short-lived process receives the bytes, uses them once, and dies. ADR 0019
  already protects that process — the sender installs its own group-leader
  sink so no IO request can carry anything out of it, it is unregistered, and
  it reports only an atom or a `{:error, atom}` pair to the guardian.
- Observation of the sender is governed by the tracing rules rather than left
  to hope. ADR 0030's `arguments` level redacts "a credential reference, model
  content, tool arguments and artifact bytes to placeholders" and replaces
  "any value reachable through a credential reference". The sender is a
  `Loopex.*` module and, spawned beneath runtime-owned processes, is reachable
  by `set_on_spawn`, so M5 must **prove** that the reply and the resolved value
  fall inside that redaction class: a trace session at the `arguments` level
  over a real invocation shows placeholders and no credential bytes. That is a
  proof obligation on M5, not a change to ADR 0030, whose redaction class
  already names this category.
- Everywhere else the earlier absolutes stand unchanged: not in guardian
  state, not in an exit reason, not in a crash report, not in an IO request,
  not in a file, not in the environment, not in argv, and in no durable or
  public plane.

**When it is resolved.** Exactly once per invocation, inside the sender
process, between the child's `ready` frame and the credential frame — step 5
above and nowhere else. A resolved value is never cached, never reused for a
second invocation, and never returned to the guardian.

**Rotation.** Per invocation, by construction: the resolver may answer
different bytes for the same reference on a later call, and no layer holds a
previous answer to contradict it. A rotation that happens while an invocation
is in flight does not reach that invocation, which has already resolved; it
reaches the next one. Nothing is invalidated and no invocation is restarted.

**Timeout.** Resolution is bounded by the invocation's existing deadline and by
nothing else; this decision adds no second clock. The sender passes that
deadline as an absolute monotonic instant, and a resolver that has not answered
when it is reached is a failed resolution reported as `:timeout`.

**The closed reason set.** A resolver answers `{:error, reason}` only with
`:missing`, `:expired`, `:oversized` or `:unavailable`; the sender itself
produces `:timeout`. Nothing else is admitted — a resolver returning anything
outside the set is treated as `:unavailable`, because a host-authored term is
exactly where a secret could be smuggled into a reason. The five atoms carry no
content, so they are safe in a message, an exit reason and a bounded
diagnostic.

**What the sender reports.** `:ok` or `{:error, reason}` from that same closed
set, never a bare `:error`. The guardian has to distinguish a resolver that
refused from one that never answered: they are different operational faults and
ADR 0029's bounded status has to say which happened. The reported reason is one
of the five atoms and never the resolved value, the reference, or a
resolver-authored string.

**Failures.** Each is a refusal with a bounded non-secret reason, and each
leaves no retained copy of anything the resolver may have produced:

| Condition | Outcome |
| --- | --- |
| No `:credential_reference` in the configuration | Refused before the namespace is created and before any child is spawned, with the adapter's existing missing-credential reason |
| Malformed reference, or a `resolver_module` that does not export the callback | The same refusal, before any child is spawned |
| Resolver answers `{:error, :missing}` or `{:error, :expired}` | The sender reports `{:error, that_atom}`; the invocation fails through ADR 0019's existing credential-send failure path, the guard tears the child down, and the atom becomes the bounded non-secret status ADR 0029 fixes |
| Resolver answers `{:error, :unavailable}`, or anything outside the closed set | The same path, reported as `:unavailable` |
| Resolver has not answered when the deadline instant is reached | The sender reports `{:error, :timeout}`, distinct from every refusal, and is killed so its stack goes with it |
| Resolved value outside 1 to 65,536 bytes | Refused in the sender before the frame is written, exactly as the size check refuses today, reported as `{:error, :oversized}` |
| Two resolutions in flight at once | Independent **successes**. Each invocation has its own sender and resolves for itself; the adapter serialises nothing and shares nothing between them, and two answers for the same reference may differ. Concurrency is not a refusal condition, and a custody process that refused concurrent callers would reintroduce exactly the serialisation this decision exists to remove |

No failure is retried inside the adapter. Whether to attempt again is the
coordinator's durable decision under ADR 0018, unchanged.

### Scrub points

- **In the sender.** The minimal credential sender keeps the shape it has
  today: it is spawned for this one send, it installs its own group leader
  sink so no IO request can carry anything out of it, it calls `resolve/2`,
  receives the one permitted credential-bearing reply, validates the size
  bound, writes the frame itself and reports `:ok` or `{:error, reason}` from
  the closed set to the guardian. Its closure holds the reference, never the
  resolved value; in the parent the value exists in the custody process and,
  for the duration of one send, in this process's own mailbox and stack, and
  nowhere else — no guardian state, no exit reason and no crash report can
  hold it.
- **In the parent's environment.** The adapter performs no environment read
  for the credential by any route. `Loopex.LLM.ReqLLM.credential_variable/0`
  remains as the one name the *host* reads when it composes a runtime — the
  reference CLI at start, and the real-provider lane when it names the
  variable in its own failure message — and the host deletes that name once it
  has read it. `ProviderLauncher.spawn_environment/0`'s enumeration of the live
  environment — `System.get_env/0` on every launch — is **deleted**, and
  nothing replaces it: no enumeration at launch, and none at composition
  either. The launcher passes the Port a fixed, closed list instead — the
  `@excluded` names removed unconditionally, plus the explicit downstream
  names — which is a constant in the source, so no code path reads the
  environment to build it. The fixed `env -i` argument lists stay as they are.

  An earlier draft moved the snapshot to composition. That is withdrawn on
  2026-09-20, because it quietly weakened an accepted decision. ADR 0019's
  companion requires that the trusted host "must not mutate unrelated launch
  environment **during this operation**" — a constraint on one launch, not a
  promise of immutability for the runtime's lifetime. A snapshot taken at
  composition and reused would let a name introduced afterwards reach a later
  launch's first image, which is a property ADR 0019 never gave away. Deleting
  the enumeration rather than relocating it needs no amendment to ADR 0019.

  What the fixed list preserves exactly is ADR 0019's actual guarantee, which
  its companion states as "Explicit credential removals are unconditional": no
  credential name and no loader or startup-injection name reaches the first
  image, whether or not it was present. What it does not preserve — stated
  rather than implied — is the clearing of *unlisted* names from the
  `/usr/bin/env` image's own environment block in the microseconds before it
  execs. Three things bound that. `/usr/bin/env` acts on none of them; `env -i`
  clears every one of them for the exec'd child, so the M0 child-environment
  conformance case, which asserts about the worker and not the first image, is
  untouched; and the block is readable only by the same user who can already
  read the parent VM's own environment, which is the case ADR 0019 explicitly
  declines to defend — "This is not a new guarantee against hostile same-VM
  code". After this decision the credential is not in the parent's environment
  at all, so the enumeration's protective value against the credential is zero
  by then.

  One mechanical note for whoever writes the change, measured rather than
  assumed: `Port.open`'s `{:env, …}` option **merges** into the inherited
  environment; it does not replace it. A probe on this toolchain spawned
  `/usr/bin/env` with `{:env, [{~c"PATH", …}]}` and the first image still
  received all 67 of the parent's names, including a planted sentinel. So
  "pass an exact environment and receive exactly that set" is not reachable
  through the Port option, and the closed unconditional removal list above is
  what is actually implementable for the same purpose.
- **In the child.** Unchanged: the child receives the credential on the socket
  and nowhere else. Its environment at entry is the fixed `PATH`, `LANG`,
  `LC_ALL` and the two crash-dump suppressions, and ADR 0029's bounded
  non-secret status is still the only failure information that leaves it.

### Proofs

Every case below exists today in
`apps/loopex_llm_reqllm/test/credential_plane_test.exs`. Each is re-pointed at
the per-invocation reference — the module's `setup` and the two rotation cases
stop writing the process-wide variable, and each fixture carries its own
credential — and each must hold with its assertion unchanged in meaning:

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
own credential reference, and the case supplies the 65,536-byte value as that
invocation's reference rather than writing it into the VM. The ceiling it
proves, and the refusal above the ceiling, are unchanged.

Three proofs are new:

- **Parent environment.** From the completion of composition onward — before,
  during and after a call — the parent VM's environment holds no credential
  under the adapter's name and no value equal to the credential in use.
  "During" is observed from inside the call, at the point the child reports
  readiness. The case composes the runtime the way a reference host does, with
  the variable set, and asserts that composition returns having deleted it.
- **Concurrent independence.** Two invocations with distinct credentials run
  at once and each child records only its own; neither child, nor either
  child's diagnostics, ever sees the other's.
- **No credential environment read in the adapter's lib tree.** The existing
  drift-protection case in `apps/loopex_llm_reqllm/test/adapter_test.exs` —
  `the adapter reads exactly one credential environment variable` — pins the
  exact `System.get_env` arguments per library file, including
  `"provider_bridge.ex" -> ["\"LOOPEX_PROVIDER_API_KEY\""]` and
  `"provider_launcher.ex" -> [""]`, the arity-zero enumeration. That case must
  survive, strengthened rather than deleted, in two ways. Both of those
  expected lists become `[]`, leaving only `provider_worker.ex`'s two
  non-secret crash-dump names, so the case then proves that no file in the
  adapter's library tree reads any environment variable at all except those
  two. And its scan is widened from one regular expression over
  `System.get_env(...)` to every route by which an environment read can be
  written: `System.get_env/0` and `/1`, `System.fetch_env/1` and
  `fetch_env!/1`, `System.get_env/2`, `:os.getenv/0`, `/1` and `/2`,
  `:os.env/0`, and indirect application of any of them through `apply/3` or a
  captured function. Each route it does not pin is refuted outright. The
  narrower scan is what lets an environment read return by a name the current
  expression does not match, which is the drift the case exists to catch.
- **Resolution failures.** One case per row of the failure table above: absent
  reference, malformed reference, a resolver module without the callback, each
  of the four refusal atoms, a resolver returning a term outside the closed set
  (reported `:unavailable`), a resolver silent past the deadline instant
  (reported `:timeout`, and asserted **distinct** from every refusal so the
  guardian can tell them apart), and a value outside the size bound. Each
  asserts the outcome, its closed-set atom, that no child was spawned where
  the contract says none is, and that no message but the permitted reply, no
  exit reason and no crash report carries the resolved value. The
  two-resolutions-at-once case is a **success** case, not a refusal: both
  invocations complete with their own credentials.
- **The permitted reply is redacted.** A trace session at the `arguments`
  level over a real invocation shows placeholders where the reply and the
  resolved value would be, and no credential bytes anywhere in the captured
  entries.
- **Host custody.** For each reference host — the CLI, the app-server host and
  the daemon — composition reads the variable exactly once, deletes it, and
  the holding process's `format_status/1` redacts its state under a forced
  crash report.

The first two, the failure cases and the custody cases belong in
`credential_plane_test.exs` beside the cases they generalise; the drift case
stays where it is.

Two details of that case matter to whoever writes the change. The literal
`"LOOPEX_PROVIDER_API_KEY"` it pins today lives in
`provider_bridge.ex:401`, inside the credential sender, while
`credential_variable/0` and its module attribute live in `req_llm.ex:49` and
`:149-150`; only the first disappears. The arity-zero enumeration the case
also pins lives in `provider_launcher.ex:23-27`, and it does not disappear —
it moves to composition, so the file that holds it afterwards is a host
composition site rather than the adapter's call path. So `adapter_test.exs:50`'s
`assert variable == "LOOPEX_PROVIDER_API_KEY"` is, afterwards, a pin on the
host-facing accessor — the one name an operator configures — and that is what
it should say it is. The neighbouring case `a missing credential is reported
before any provider is called` proves the refusal today by deleting the
variable from the VM; under this decision it proves the same refusal by
supplying no credential reference with the call, which is the path that
replaces it.

### Security review

The review is an acceptance point of M5 Outcome 6, read by someone other than
the implementer, over the exact diff. It answers: where the reference is held
between the call and the send; that the resolved value has no path into
guardian state, a message, an exit reason, a crash report, an IO request, a
file or the environment; that every row of the failure table refuses without
retaining a copy; that the deadline, cleanup and abandonment paths do not
resurrect one; that a host supplying no reference is refused rather than
falling back to an ambient read; and, on the host side of the boundary, that
each reference implementation reads the operator's variable once, deletes it,
redacts the holding process's state, and hands the adapter a reference that
carries no bytes. Its record is retained with the milestone's evidence.

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
this adapter supplies a credential reference with the call and owns the bytes
behind it. The reference CLI, the app-server host, the M5 daemon and the
real-provider lane keep reading `LOOPEX_PROVIDER_API_KEY` where they compose,
and delete it there, so an operator's setup is unchanged and the release
check's credential frame is unchanged. An embedder that relied on the adapter reading
the environment for it must pass the reference instead; that is the refusal
path, not a silent fallback, and it is stated in the operator and developer
documentation the milestone updates.

Rollback is reverting the adapter change. Nothing durable, no root and no
protocol generation records which mechanism delivered a credential to a
process that has since exited, so a rollback needs no migration and leaves no
trace to repair.

Acceptance binds this complete pair at the exact candidate the maintainer
names in the governance record. Its claims remain unproved until the tests the
M5 plan maps to Outcome 6 exist and pass and the security review is recorded.
