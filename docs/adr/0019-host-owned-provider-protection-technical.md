# 0019. Host-owned provider protection — Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Host-owned provider protection](0019-host-owned-provider-protection.md#concept).

<a id="technical-adr-0019-context"></a>
## Evidence and Constraints

Concept: [Context](0019-host-owned-provider-protection.md#concept-adr-0019-context).

Source inspection at `497eada62a0f6264e77ff2eeace5bdf0268b18e9` establishes:

- `ReqLLM.Application` in the reference adapter starts the credential facility
  and IO sink. The facility installs a primary Logger filter, changes shared
  dependency group leaders, and retains poisoned protection on registry loss.
- The pinned dependency's `ReqLLM.Streaming.FinchClient` starts asynchronous
  work under `ReqLLM.TaskSupervisor` and contains inspected error logging.
- `ProviderLifetime.register/2` delegates to the callback's registrar and returns
  Core's parent-local retaining guard or unmanaged status.
  The recent guardian repair observes that guard across active and post-result
  work; ordinary callback completion is not lifetime completion.
- `ProviderAttempt.canonical_reply/2` admits the raw callback body before usage
  projection, excludes the independently bounded request echo from that size,
  and leaves full-settlement admission to Core.
- The Model configuration already carries adapter-specific `options`. The
  reference composition currently supplies an empty list; explicit worker
  configuration must therefore reach the real command path, not just a test.

These are source facts, not a demonstration of the proposed launch mechanism.
ADR 0001 permits the existing adapter edge and forbids Core depending on it.
ADR 0002 retains the accepted floor/current toolchain pairs and platform lanes.
ADR 0003's extension activation and package-publication decisions are not
exercised by this private source-built worker.

<a id="technical-adr-0019-decision"></a>
## Launch, Protocol, and Lifetime

Concept: [Decision](0019-host-owned-provider-protection.md#concept-adr-0019-decision).

### Placement and bootstrap

Keep launcher, bridge, codec, and worker entry in `:loopex_llm_reqllm`. Keep
reference wiring in `:loopex_composition`; Core and protocol gain no concrete
adapter reference. Do not import Local executor private helpers or route a
provider call through tool jobs, grants, receipts, or artifact storage. A narrow
provider-owned launch guard may follow the existing ownership technique without
creating a cross-app process framework or ninth application.

Build a dedicated `loopex_provider` escript from the adapter project, with
`app: nil` and an explicit worker entry. Mix still starts Elixir and loads its
embedded configuration before that entry; all pre-entry configuration must be
credential-free. The entry establishes its private channel and child diagnostic
policy before explicitly starting ReqLLM and its runtime dependencies. It does
not start Core's runtime, composition, CLI, or the adapter's old protection
application callback. Bundling existing dependency modules does not mean
starting their applications.

Use the same source revision, version train, dependency lock, and declared
toolchain identity for bridge and worker. A generated build manifest binds the
clean source revision, version, dependency-lock digest, packaged-input digest,
and exact Elixir/OTP build pair. The input digest excludes the generated manifest
and final executable, avoiding a self-reference. The host launch configuration
also names the worker artifact digest and expected manifest digest. Compute the artifact
digest externally after building; do not require it to contain its own hash.
Refuse dirty builds for retained evidence. A matching self-reported SHA alone
does not bind the executed bytes. Preserve the existing embedded model
snapshot; do not depend on ordinary filesystem access to `priv` inside an
escript archive. Launch scripts are repository-owned build inputs, not material
fetched or compiled at runtime. Neither an external native helper nor a new
Hex dependency is introduced by this design.

The host supplies trusted absolute interpreter and worker paths through
adapter options. Reference command build/launch wiring supplies the canonical
paths of the pair it built; embedders supply theirs explicitly. Do not add a
CLI command, hidden worker mode, flag, or public framing protocol. Do not search
`PATH`, a user home, cwd, project resources, or the coding workspace for code.
Paths are host authority; matching a handshake is not authentication of an
untrusted executable. An explicit host-owned deployment may relocate the pair
and provide its new paths without recompiling Core.

The adapter-specific option names are `worker_path` and `interpreter_path`
(absolute binary paths), `worker_sha256` and `build_manifest_sha256` (lowercase
64-hex digests), and, for unmanaged calls, `cleanup_grace_ms` (the existing
validated cleanup-period domain). Reject missing required, duplicate, unknown,
or malformed configuration before credential resolution. The build emits this
non-secret launch configuration; the command passes it opaquely to composition,
which alone selects the concrete adapter and fills its Model options. Command
source does not name a `Loopex.LLM` module or construct provider options.
Add `complete_prompt(model_spec, prompt, options)` for two binaries and a
keyword list, distinct from `complete(request, options, progress)`. The old
bare-model `complete/2` returns the bounded pre-transport refusal because it
has no explicit host configuration. It does not discover a worker through
application environment or a hidden process-dictionary setting. Migrate direct
callers, including `apps/loopex_llm_reqllm/test/provider_test.exs`, to the
options-taking helper without changing its real-provider selector or assertion
strength. If a holder locks the old invocation bytes, that holder's additive
generation must settle the change before it can be offered as green evidence.

At the first spawn, unset the ambient snapshot plus unconditional known
credential and loader/startup-injection names, regardless of their presence
in that snapshot. Then construct an exact downstream environment containing
only approved non-secret runtime inputs. Downstream `env -i` alone does not
protect the first image. Port environment updates are not atomic replacement
against concurrently introduced arbitrary names: the trusted host must not
mutate unrelated launch environment during this operation. This is not a
new guarantee against hostile same-VM code. Explicit credential removals are
unconditional; dotenv discovery and development activation such as
`TIDEWAVE_REPL` stay disabled. Select BEAM crash-dump suppression and the OS
core-dump policy
before loading credential-bearing code; refuse bootstrap if the selected
platform cannot establish the declared containment.

The process topology is exact: the registered parent BEAM guardian owns a Port
whose direct OS image is a disposable carrier. That carrier starts an
independent OS guard in the Port-created group. The guard retains the control
descriptors and birth-derived group authority and starts the provider escript.
The carrier and guard are not the same process. Destroying the carrier must
leave the guard able to observe parent-channel loss and clean its owned group.

The Port's inherited pipes carry only guard control and acknowledgements.
Erlang's `nouse_stdio` gives these descriptors 3 and 4, distinct from ordinary
stdio. The worker closes its copies before credential-bearing code executes;
only the guard reads control input. Raw stdout and stderr are redirected at
launch, including failures before the worker entry runs, never merged with
protocol output. The implementation must prove these descriptor lifetimes.

A separate AF_UNIX socket carries the private data protocol. The parent creates
a fresh short pathname in a host-owned mode-0700 temporary directory and sets
socket mode 0600 before readiness. It accepts one connection and closes the
listener; no endpoint is reused for another invocation. The nonce/build exchange
binds that connection, not authentication against malicious same-account code.
The invocation cleanup owner receives the exact temporary namespace before
launch and owns its removal, including failed connection and parent-loss paths.
A failure before the guard starts creates no provider child or credential
delivery; the host removes only its exact abandoned namespace, never an active
or foreign socket. Path-length/platform refusal is pre-transport unavailability.
No TCP listener, distributed node, cookie, general service, or `:peer` RPC is
introduced. AF_UNIX support comes from the accepted OTP standard library.

### Credential handoff

Register the parent-local lifetime guardian before launch. Bootstrap exchanges
only non-secret protocol/build identity and a fresh invocation correlation.
Readiness proves channel setup, worker diagnostic policy, dependency readiness,
and a cleanup owner; it does not permit transport by itself.

After exact readiness, a minimal private host sender resolves only
`LOOPEX_PROVIDER_API_KEY`. Reject absent, empty, or greater-than-65,536-byte
values categorically before sending any credential. The upper bound is newly
proposed here; the evidence harness's separate credential bound is not product
authority. Do not forward the host's general options, environment, callbacks,
process identifiers, or exception terms to the worker.

Send the key over the bounded private channel, not argv, environment, ordinary
GenServer request/state, logs, or files. The sender runs no provider library,
returns no secret-bearing failure, and has no ordinary crash-reporting path
that can print its inputs. Use a raw monitored sender owned by the registered
guardian, not a supervised Task carrying the key in its crash-reportable call.
Set only that sender's group leader to a sink, catch and normalize raises,
throws, and exits, and read and write the credential in that same process.
Neither its result nor its `DOWN` reason carries secret material. Its temporary
memory and the trusted host's own credential environment are not claimed
inaccessible to that host or forensic
inspection. The child constructs credential-bearing ReqLLM options only after
handoff. It serves no second invocation and retains no key for reuse.

### One invocation, existing authority

Control still sends its one-use permit to the exact Core BEAM worker. That
worker invokes `Model.complete/3` once; the adapter then starts this bridge.
The child receives no Control reference, ownership token, permit authority,
retry allowance, Store handle, or session capability.

The private protocol has one version and closed per-kind fields. A fresh
invocation nonce binds both channels; it is not a session authority token.

| Channel and kind | Required binding and payload |
| --- | --- |
| Guard bootstrap / ready | Nonce, exact owned namespace, configured cleanup period, and launch identity; guard confirms ownership before data readiness |
| Data bootstrap / ready | Nonce, protocol version, generated build-manifest digest; exact echo before credential delivery |
| Data credential | Nonce and the bounded credential bytes; accepted once after readiness |
| Data invocation | Nonce, complete semantic request, exact committed request bytes, and staged digest; accepted once |
| Data dispatch_started | Nonce and staged digest; observation only, never retry or no-dispatch proof |
| Data delta | Nonce, staged digest, and bounded raw progress payload |
| Data terminal | Nonce, staged digest, and one closed result variant: raw reply, proved pre-transport refusal, ambiguous failure, or raw-admission unreadable |
| Guard stop / cleanup_complete | Nonce and one fresh plain stop ID; stop carries remaining cleanup duration; parent maps the ID to the exact Core stop reference without serializing a BEAM capability |

The guard, not the worker, answers cleanup-complete after proved cessation;
the parent guardian then acknowledges Core's exact request and exits. The
worker alone sends provider result/data frames and cannot write guard replies.
The child calls `Model.validate_request/1` on the semantic request and its bytes
and digest before transport. Those bytes have no general decoder contract; do
not recover semantics through unrestricted external-term decoding.
Duplicate starts, wrong identities, unknown kinds or fields, invalid ordering,
partial frames, and contradictory terminal messages fail closed.
Control/cleanup and result delivery cannot sit behind an unbounded delta queue.

The worker consumes its invocation once. Immediately before invoking ReqLLM,
it irreversibly enters its transport-started state; any acknowledgement reports
only that state. It does not prove network delivery or provider acceptance and
does not replace Control's dispatch linearization. Preserve `max_retries: 0`
and the receive timeout derived from the remaining committed deadline. Startup
and framing consume that deadline; neither creates a fresh request budget.

Only an unequivocal parent refusal before transport can exist, or an exact
child result proving no invocation or request handoff to provider transport,
can produce `{:error, {:not_dispatched, "model_call_failed"}}`. Once the child
enters the invocation path, dependency errors cannot regain that tag. Lost
acknowledgements, child/channel loss, malformed frames, and observation timeouts
after possible delivery are `dispatched_or_unknown`. Do not replace a child,
resend an invocation, or retry the network request to resolve uncertainty.

### Bounds, replies, and progress

Use a private versioned length-prefixed plain-data codec with bounded
fragmentation and reassembly. Do not decode arbitrary external Erlang terms,
create atoms from input, or serialize executable values. Validate declared
length and kind before allocating their payload. Derive finite encoded caps
from each existing semantic bound plus the codec's worst-case expansion and
fixed envelope; retain that derivation and boundary vectors with the codec.
A chosen wire encoding is an internal same-build mechanism, not a new public
Model budget or separately supported protocol.

The staged request and its echo share the staged request's existing 65,536-byte
ceiling; the raw newly supplied reply body has its separate Store admission.
Raw admission checks both atom and binary echo spellings separately before Core
rejects their collision. Reassembly must accommodate both bounded echoes on
that malformed path, not erase one or derive its cap from valid replies only.
Store structural bounds remain depth 12, collection cardinality 1,024, and
normalized keys at most 256 bytes. Each progress item separately retains its
65,536-byte semantic payload bound, with codec overhead separate. Do not impose
a single 65,536-byte combined request/reply
frame or charge encoding overhead against semantic admission.

For a raw-admitted callback reply, transport every supplied member faithfully,
including raw usage, the returned request echo, identity, tool calls, stream
evidence, and response identifier. Atom key spellings may be encoded as exact
known tags, but collisions with binary spellings cannot be erased. The parent
passes the decoded raw candidate to Core's unchanged validation, not a
child-normalized accounting claim. Unknown or malformed raw values cannot be
silently dropped to manufacture an admissible reply.

Extract today's private `ProviderAttempt.admitted_raw_reply/1` as one internal
`@doc false` pure admission entry used by Core and worker. Preserve the checks
and their order exactly; this is a small Core helper refactor, not duplicated
admission logic or a new Model callback. It starts no application or process
in the worker. Canonical validation and settlement remain exclusively Core's.

A recognized `unreadable` terminal frame is narrower than a transport error:
the child obtained a final raw callback answer and the unchanged shared raw
admission refused it before request/usage validation. It carries no answer or
usage. The bridge maps it to `{:ok, %{}}`, an explicitly invalid candidate that
Core rejects as `unreadable_model_answer`; it is not a reconstructed provider
answer. This avoids transporting an arbitrarily large or non-plain refused
term without changing its terminal/accounting classification. Incomplete
streams, codec failures, missing frames, and timeouts may not use this path.

Never substitute that sentinel for a raw-admitted reply. In particular, a reply
whose full settlement exceeds the Store ceiling must still reach Core intact
for ADR 0018 combination 5 and preserve validated reported usage. The wire
limit must admit that case. No receipt, accounting source, durable reply,
conversation, or terminal is committed in the child. ADR 0021's separate
versioned-provenance proposal is not required to change this division of labor.

The child progress callback uses bounded nonblocking queue admission. Merely
sending to another process leaves an unbounded mailbox and does not satisfy
this rule. It may drop transient deltas under backpressure, not block provider
work on a consumer. Preserve the producer's final `delta_count` rather than
replace it with the number forwarded across the data channel; Core owns domains,
sequences, closure, and durable fallback. Terminal/control messages have a
bounded path independent of progress backlog and are never silently dropped.

### Cleanup and replacement

The bridge guardian monitors the actual retainer returned by
`ProviderLifetime.register/2`. It survives normal callback completion and
retains ownership until Core's correlated cleanup request. An unmanaged direct
adapter call instead owns and confirms its own child cleanup before returning
success; it cannot leave a guardian waiting for a Core request that will never arrive.

Extend the private registration result to carry the session's already committed
`cleanup_grace_ms` alongside its retaining guard, and the private stop request
to carry Core's current parent-VM monotonic cooperative and observation deadlines.
The later observation deadline is not additional cooperative cleanup grace.
This changes private lifetime plumbing, not Model's callback or cleanup authority.
The bridge passes only the remaining duration to OS-side helpers; time already spent is
not granted again at each step. The guard receives the configured period during
non-secret bootstrap for autonomous parent-channel-loss cleanup. Core alone
decides whether semantic cleanup and subsequent guardian exit satisfy their
respective existing deadlines, including its forced-stop rules.

An unmanaged caller must supply `cleanup_grace_ms` in adapter options, validated
by the same existing period rule before launch; omission refuses rather than
selecting a private default. Managed callers use the registered session value,
not an option that can override it. An unmanaged call starts one cleanup window
when cleanup becomes necessary and waits for proof only within that window.
Failure to prove cleanup returns the existing ambiguous error rather than the
successful reply, leaves the OS cleanup owner active, and does not retry. The
caller receives no claim of confirmed cleanup or permission to reuse the child.

Retainer loss, cancellation, deadline, or failed invocation stops the owned
child and descendants under the existing configured cleanup period. Cleanup
does not release ownership before cessation is proved. Registering, booting,
credential delivery, result delivery, and the post-result wait all remain
covered; neither a once-sampled lease nor callback liveness is sufficient.

The OS-side guard must survive abrupt death of the direct Port image and
detect loss of its parent channel independently. A bare Port or an EOF handler
inside that direct image is insufficient: the existing executor's carrier
documents why the VM can terminate that image before it observes EOF. Keep
birth-derived process-group authority until cleanup; do not act on an unrelated
reused numeric PID or group inferred from a late process listing. Any process
inspection and signal helpers are bounded and fail closed on unavailable or
ambiguous results. This does not claim containment of deliberately escaped
processes or arbitrary code under the host account.

Successful cleanup acknowledges the exact request only after proved cessation;
Core still observes guardian termination separately. Port exit, EOF, process
absence, child self-report, and elapsed time alone are insufficient. Unproved
cleanup cannot become a successful terminal merely because a reply arrived.
Loss of the host VM permits no durable verdict from the guard; subsequent
session recovery follows ADR 0018's conservative non-redispatching rule.

Concurrent independent invocations remain allowed, each with its own guardian,
OS group, namespace, and channels. Replacement here means retiring a launcher
or changing its configured worker-build identity, not serializing all calls.
Retire its resources through the same cleanup proof or refuse admission through
that affected launcher. There is no node-global lock or automatic restart of an
old provider attempt. Unrelated launchers and runtimes remain operational.

<a id="technical-adr-0019-alternatives"></a>
## Alternative Costs

Concept: [Alternatives](0019-host-owned-provider-protection.md#concept-adr-0019-alternatives).

Per-invocation isolation adds startup and memory overhead and exact packaged
process proof. A pool would amortize that cost but reintroduce credential reuse,
retired diagnostic origin, and cross-attempt cleanup; it is not selected.
`:peer` standard-IO forwarding and generic RPC are not the private restricted
boundary specified here. A single pipe shared by guard and worker creates
competing readers or requires a new multiplexer. The selected separate local
socket pays namespace, permission, single-connection, and removal costs instead;
the inherited control pipe remains exclusively the cleanup guard's.

Same-VM protection needs complete origin classification through delayed generic
OTP reports and a deliberate restart policy. No finite wait establishes that
all such reports drained. Dependency replacement changes the external boundary
and its conformance/floor evidence. Both remain viable alternatives requiring
their own accepted design, not fallback branches of this implementation.

<a id="technical-adr-0019-consequences"></a>
## Delivery, Rollback, and Required Evidence

Concept: [Compatibility, delivery, and rollback](0019-host-owned-provider-protection.md#concept-adr-0019-consequences).

The worker is built offline from the existing admitted source/dependency closure
before runtime launch. It starts no Core session supervision and uses no new
app, dependency, native compiler, dynamic activation, public command, or runtime
floor. Preserve the unchanged composition test corpus and its 180-effective-line
ceiling; exceeding it requires a separately proposed holder transaction, not a
hidden budget increase. General extension isolation and published packaging
remain outside this decision.

Migration removes the parent-global filter/group-leader facility and its
startup effects, introduces the explicit worker configuration and private
build, and updates operator/developer guidance and compatibility inventory.
Record the new credential ceiling and refusal behavior. Do not weaken locked
checks or relabel an implementation-specific lock as irrelevant. If changing
one is required, enumerate its path, evidence replacement, and additive
Closed-gate transaction before proceeding.

Rollback stops admission, drains or contains children, then changes bridge,
worker, and configuration together. No durable schema changes, record rewrite,
accounting replacement, or recovered redispatch belongs here. If containment is
unproved, keep admission refused and follow the existing operator recovery
procedure; reverting code is not proof cleanup occurred. Restoring unsafe
shared-VM diagnostic handling requires a new decision, not an automatic fallback.

Before offering an implementation candidate for integration, independently
review behavior and require decisive cases and mutants covering:

1. Starting/stopping the adapter, registry/launcher loss, provider-supervisor
   restart, and concurrent runtime instances leave parent Logger settings,
   ordinary logs, and unrelated group leaders unchanged and usable.
2. Exact packaged worker execution outside the checkout, on floor/current and
   required platforms: embedded model data resolves; no Core/CLI/session app
   starts; ambient dotenv/development settings are ignored. Missing/wrong
   artifact and protocol/build mismatch refuse before credential resolution.
3. A synthetic credential canary at the first image, pre-entry crash, child
   Logger/stdio/dependency failure, active work, delayed post-result reports,
   and parent retainer loss. Assert absence from actual host and retained
   channels, not a configured option; prove child delivery on the real private
   path. Exercise empty, exact-limit, and over-limit credentials separately.
4. A real controlled transport counts one request. Kill before/after the local
   transport latch and lose its acknowledgement; no child restart, resend, or
   dependency retry may produce another request. Core alone grants a subsequent
   attempt. Deadline/abort winners keep existing late-usage behavior.
5. Codec length/shape/correlation/order faults, fragmentation, duplicate starts,
   near-limit independent request and reply, both bounded echo spellings before
   collision refusal, and reply-plus-settlement overflow.
   Compare every decoded member, including raw usage and echo. Prove refused
   raw answers and the unreadable sentinel have identical terminal/accounting
   classifications, and that the sentinel cannot swallow reported compaction.
   Prove socket permissions, one-connection admission, control-descriptor closure
   in the worker, and exact namespace removal on each startup/death boundary.
6. Saturated progress does not block provider work or terminal/control delivery;
   dropped deltas do not rewrite producer count. Partial streams never become
   successful short replies.
7. Retainer death during bootstrap, credential handoff, transport, result, and
   cleanup; unmanaged direct calls; Port-owner and whole-parent-VM death; child
   and helper survival; failed process inspection; cleanup acknowledgement
   ordering. A timeout is unavailable proof, not the expected successful result.
8. Actual live-provider execution and retained non-secret identifiers on the
   final source, fresh exact-SHA independent review, and measured startup/
   memory/deadline cost. Earlier same-VM evidence cannot certify this path.

Source feasibility does not discharge these process, package, credential, or
live evidence obligations. This proposal does not claim they have run.

Port semantics were checked through Context7 and the primary
[Erlang port reference](https://www.erlang.org/doc/apps/erts/erlang.html#open_port/2).
The installed floor/current Mix escript builders were inspected for `app: nil`,
embedded configuration, and dependency bundling. Those mechanisms do not by
themselves prove secrecy, process cleanup, or a supported binary distribution.
