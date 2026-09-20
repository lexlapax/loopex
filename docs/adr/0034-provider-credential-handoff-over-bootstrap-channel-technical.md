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

### Resolution and scrub points

- **At the call.** The credential reaches the adapter as an opaque reference
  in the per-invocation configuration the host already supplies to
  `complete/3`. The reference is not the bytes: it is resolved exactly once,
  and only where the frame is written.
- **In the sender.** The minimal credential sender keeps the shape it has
  today: it is spawned for this one send, it installs its own group leader
  sink so no IO request can carry anything out of it, it resolves the
  reference, validates the size bound, writes the frame itself and reports a
  bare `:ok` or `:error` atom to the guardian. Its closure holds the
  reference, never the resolved value; the value exists only in that
  process's own stack for the duration of one send, so no guardian state, no
  message, no exit reason and no crash report can hold it.
- **In the parent's environment.** The adapter performs no `System.get_env/1`
  for the credential. `Loopex.LLM.ReqLLM.credential_variable/0` remains as the
  one name the *host* reads when it composes a runtime — the reference CLI at
  start, and the real-provider lane when it names the variable in its own
  failure message — and nothing in the adapter's call path reads it.
  `ProviderLauncher.spawn_environment/0` keeps removing that name, and every
  other known credential and loader name, from the first spawned image; the
  fixed `env -i` argument lists stay as they are.
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

- **Parent environment.** Before, during and after a call, the parent VM's
  environment holds no credential under the adapter's name or any value equal
  to the credential in use. "During" is observed from inside the call, at the
  point the child reports readiness.
- **Concurrent independence.** Two invocations with distinct credentials run
  at once and each child records only its own; neither child, nor either
  child's diagnostics, ever sees the other's.
- **No credential environment read in the adapter's lib tree.** The existing
  drift-protection case in `apps/loopex_llm_reqllm/test/adapter_test.exs` —
  `the adapter reads exactly one credential environment variable` — pins the
  exact `System.get_env` arguments per library file, including
  `"provider_bridge.ex" -> ["\"LOOPEX_PROVIDER_API_KEY\""]`. That case must
  survive, strengthened rather than deleted: the expected list for
  `provider_bridge.ex` becomes `[]`, so the case then proves that no file in
  the adapter's library tree reads any environment variable for a credential
  at all, which is a stronger claim than the one it makes today.

The first two belong in `credential_plane_test.exs` beside the cases they
generalise; the third stays where it is.

Two details of that case matter to whoever writes the change. The literal
`"LOOPEX_PROVIDER_API_KEY"` it pins today lives in
`provider_bridge.ex:401`, inside the credential sender, while
`credential_variable/0` and its module attribute live in `req_llm.ex:49` and
`:149-150`; only the first disappears. So `adapter_test.exs:50`'s
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
file or the environment; that a failed or partial send leaves no retained
copy; that the deadline, cleanup and abandonment paths do not resurrect one;
and that a host supplying no reference is refused rather than falling back to
an ambient read. Its record is retained with the milestone's evidence.

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
this adapter supplies a credential reference with the call. The reference CLI
and the real-provider lane keep reading `LOOPEX_PROVIDER_API_KEY` where they
compose, so an operator's setup is unchanged and the release check's
credential frame is unchanged. An embedder that relied on the adapter reading
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
