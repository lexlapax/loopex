<a id="concept"></a>
## Concept

Technical depth: [Credential handoff mechanics](0034-provider-credential-handoff-over-bootstrap-channel-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-19
- **Decision owner:** Maintainer
- **Supersedes:** ADR 0019 only where it says the environment variable is the
  invocation's credential source, the ready sender resolves that variable, and
  the sender must be raw-spawned and owned only by the guardian; managed calls
  instead make the guardian and sender direct temporary `owner_workers`
  children, while the supervised sender's initial call and closure are
  token-free and Direct mode retains a raw linked-and-monitored sender;
  ADR 0019's private-channel, first-image scrubbing, failure-teardown and
  forensic-memory rules remain unchanged
- **Prerequisite for:** M5 outcomes 5 and 6

<a id="concept-adr-0034-decision"></a>
### Context and Decision

ADR 0019 gave the reference provider adapter a private, one-invocation child
process: a namespace of its own, a nonce, a private Unix-domain socket, a
build manifest digest the child must echo before it is trusted, and an
environment scrubbed down to a fixed `PATH` so the child inherits no ambient
secret. The credential already crosses that private channel as its own frame
rather than through the child's environment.

One thing was left on the process-wide plane. The adapter resolves the
credential by reading the operating-system environment variable
`LOOPEX_PROVIDER_API_KEY` from the parent VM, inside the call, at the moment
it is about to send the frame. The parent VM's environment is a single global
slot, so the credential of whichever invocation wrote it last is the
credential every concurrent invocation sends. That has two costs. It is a
weaker property than the rest of the plane: a secret that has to sit in a
process-wide slot for the duration of every call is reachable by anything in
the VM that can read the environment, and it is exactly the kind of ambient
authority the runtime refuses everywhere else. And it forces serialisation:
**eleven of the thirteen** heavy `loopex_llm_reqllm` test modules install
their own canary in that slot, so two of *those* running at once would hand
each other's canary to each other's child. The other two of the thirteen are
serial for reasons of their own, which this decision does not touch. The
thirteen are listed by name, with the two marked and the derivation executed
rather than globbed, in the
[technical companion](0034-provider-credential-handoff-over-bootstrap-channel-technical.md#technical-adr-0034-serial-modules);
every passage that states this count cites that list rather than recounting,
because recounting has been wrong three times. The
[verification companion](../developer/verification-technical.md#technical-verification-speed)
measured the result at M4 closure — that application is the critical path of
the fast check, 96% of its time sits in those thirteen modules, and no further
test change shortens the check while the slot is shared.

**Decide that the credential is named by an opaque token bound at
composition, whose resolution is per invocation and happens only inside the
process that writes it to the child's private channel.** The host gives the adapter a *credential token* where it
composes the runtime: an opaque identifier that carries no credential, no
routing and no authority of its own. **"Per-invocation" qualifies the
resolution, not the token's arrival** — the token is bound once, per runtime,
and resolved afresh on every call. There is nowhere else it could arrive:
`complete/3` receives a request and the composition-time options and nothing
per-call from the host, so a token "supplied with each call" would have no
seam to arrive through. Behind it the host owns three things the
adapter does not: a **routing registry** that maps a token to a custody
process and holds routing only — never bytes, never anything a secret could be
derived from — the **custody process** that holds the bytes, and a mandatory
**tracing capability** through which the sender excludes itself before it can
receive either the token or the registry handle. The host starts all three
before the runtime, puts the token, registry handle and tracing capability in
the model options, and binds the capability to the runtime reference after the
runtime starts but before composition reports success to its caller. A missing,
malformed or unbound capability refuses composition and unwinds the started
edges; an immediately unreachable capability refuses an
invocation before the token is routed. The capability holds no credential,
registry membership or policy. It only bridges composition order to the
runtime-owned exclusion state. The adapter
resolves the token exactly once per invocation, inside the minimal sender
process that writes the credential frame, and only after the child has proved
its nonce, codec version and build manifest digest. The adapter reads no
environment variable for the credential. A call that carries no token is
refused before any child is spawned, which is the refusal a missing
environment variable produces today.

The token replaces a `{module, term}` reference an earlier draft used; the
maintainer decided that on 2026-09-20 and the companion records why. A value
that named the resolving module carried the host's arrangement through every
copy of the adapter's configuration, and a second provider would have widened
the value rather than added a registry row. An opaque token discloses nothing
and stays the same shape however many credentials sit behind it.

**The guardian enforces the deadline, and the resolver is not asked to.** The
custody callback takes no deadline. The invocation's absolute deadline exists
before either managed start and setup never resets it. A start call that never
answers remains an owner-group/runtime liveness failure because the transfer is
incomplete and no private adapter clock can safely own it. Once Core has
registered the inert guardian, the guardian has installed the returned
retainer monitor, and the guardian has adopted the inert sender through an
exact link-and-monitor handshake, initialization begins under that same
deadline. If its instant has already passed, the guardian cleans up and reports
`:timeout` immediately. Otherwise it bounds provider launch and readiness,
sender release, trace exclusion, token routing, custody resolution and the
credential-frame write, killing the sender at expiry. Immediate guardian
start, registration, authorization, sender start or adoption refusal is
`:unavailable`. Exact child readiness releases the parked sender with
`{:begin_bootstrap, sender_ref, guardian_pid, sender_pid, absolute_deadline}`;
the sender validates and retains that instant on receipt, rechecks it
immediately before installing trace exclusion and again immediately before
installing its sink, and acknowledges only with the exact
`{:bootstrap_result, sender_ref, sender_pid, guardian_pid, result}` union, where
`result` is `:ok` or `{:error, :unavailable}`. Registry lookup, custody
resolution and credential-frame write are three parked sender phases. Each
sends the guardian exactly `{:credential_phase_result, sender_ref,
guardian_pid, sender_pid, phase, result}` and advances only on
`{:credential_phase_continue, sender_ref, guardian_pid, sender_pid, phase,
absolute_deadline}` after the guardian rechecks that same instant. The result
union is phase-scoped: registry and credential-frame phases admit only `:ok`
or `{:error, :unavailable}`. The custody phase admits `:ok`, the custody
process's `:missing`, `:expired` or `:unavailable`, and `:oversized` produced
only by the sender's byte-bound check after an otherwise successful custody
reply; custody itself may not originate `:oversized`. Every other current
result fails closed. An error result never
gets a continuation. The sender rechecks the retained instant when it receives each
continuation and immediately before the one operation that continuation
permits. It makes the same two checks on credential context before registry
routing. The custody gate carries no bytes. After a successful credential-frame
write, the sender tail-calls a named final-wait function whose arguments are
non-secret. That function emits the `:credential_frame` result and waits for
the final continuation; the credential-bearing stack frame is no longer live.
The final continuation therefore permits only normal exit; after consuming that
exact normal sender `DOWN`, the guardian checks the deadline again and starts
the generic helper that sends the invocation frame. Any other sender `DOWN`
before expiry is `:unavailable` and starts no invocation helper; a deadline
exit maps to `:timeout` only after the guardian's own clock confirms expiry.
Direct mode uses the same phase gates. An earlier draft handed the
resolver an absolute instant and relied on it to honour one; that is withdrawn
by the same decision, because it made a safety property depend on code the
adapter does not write, and a custody process that simply blocked would have
hung the invocation past its deadline.

**Losing custody or the registry is a refusal, never a reconstruction.** If
the custody process is gone, the registry has no row, or the registry itself
is gone, resolution answers `:unavailable` and every invocation on that token
refuses the same way until the host recomposes. Nothing rebuilds the secret,
and nothing could: the registry holds no bytes to rebuild it from.

**Exactly one credential-bearing BEAM message exists from the adapter edge
inward, followed by one private-channel frame to the child, and this pair names
both.** The narrower wording is deliberate: the host puts the
bytes into custody when it composes, and may replace them there when it
rotates, and both are transfers in the parent that this pair does not govern —
they are the host's, before the adapter is involved at all. What this pair
governs is everything from the adapter's edge inward.

**Within that boundary the parent-VM transfer is one, and this pair names it.** A host that keeps the bytes and answers a resolver call has to send
them to the process that asked; a contract saying the value is never in a
message could never be implemented alongside one. So the rule is a permission
with a boundary: the custody process's reply to the sender is the one
credential-bearing BEAM message — bounded, unlogged, never forwarded, never
retained after the frame is written. The sender then performs the one required
credential-bearing write on the child's private socket, protected the same way
ADR 0019 already protects that sender. The registry
lookup before it carries no credential, so routing adds no second place a
secret can be seen. What keeps those bytes out of a trace is stated against
the implementation rather than against an assumption about it, and ADR 0030's
match-specification exclusion is **implemented by M5 rather than assumed
present**: the adapter is in no
default trace namespace, so the credential work is untraced under every
default configuration; and where a host explicitly names the adapter module,
the credential-bearing functions are **excluded before a post-bootstrap trace
message is delivered at all**, which is what ADR 0030 already requires and what M5 adds
to `Loopex.Trace` to honour. Redaction at the sink cannot protect credential
bytes: the raw call reaches the tracer first, and ADR 0030's placeholder keeps
a value-derived size and digest from which a one-byte secret is recoverable by
enumeration. Process and function exclusion are therefore the sole credential
trace control. The keyword-key redaction M5 adds is only for the opaque 128-bit
token while it crosses core before a sender exists. For a runtime-managed call the exclusion is **by function and by
process together**, in one call: the
match specification ADR 0030 names, for the functions that hold the bytes, and
a process-level exclusion the sender installs on itself before it resolves
anything — because a function that carries the credential calls functions it
does not own, and a traced `:gen_tcp.send/2` shows the frame whatever this
adapter's own functions are patterned. M5 proves both at the tracer rather
than at the sink, in a case that names `:gen_tcp` on purpose. ADR 0030 is not edited: its prose is honoured
once this lands.

The start ordering is part of that decision. Before provider launch, Core's
managed starter first creates an inert guardian with exactly its start
reference, callback owner and stop reference, then registers it as the exact
provider resource. The guardian installs Core's returned retainer monitor,
drops its callback monitor and returns an exact authorization acknowledgement.
The callback receives that acknowledgement before starting further work, and
the guardian can already service a stop request. A second start
creates an inert sender whose initial argument contains only its start
reference, callback owner, guardian pid and tracing capability — no token,
registry handle, socket, nonce, request or credential. The sender links to the
guardian; the guardian validates its reference and pid, installs a monitor and
acknowledges adoption. Only then may the sender drop its temporary callback
monitor and acknowledge adoption completion to the callback. The callback
waits for that acknowledgement; the sender remains parked. The guardian has already dropped its own
temporary monitor after Core registration and retainer-monitor installation.
The callback then gives the guardian
its initialize message, including the request/configuration, opaque token and
registry handle but no credential bytes; the sender receives none of them. The
guardian starts ADR 0019's provider tree. Exact child readiness releases the
sender with the bound, non-secret `:begin_bootstrap` tuple and the retained
absolute deadline; a refusal before readiness releases nothing. The sender then
installs both exclusions, drains every pre-clear trace signal through OTP's
delivery barrier and, from the now-untraced sender, spawns and installs its
group-leader sink. The sink links for abnormal termination and monitors the
sender for normal exit. The sender acknowledges only after both pids are
verified clear, using the exact closed `:bootstrap_result` union above. A wrong
binding cannot release context, and a malformed current result fails closed.
Only exact success lets the guardian send the token, registry handle and
non-secret channel context — the accepted socket and invocation nonce — to it.
When the last sender using an excluded function exits,
core restores each live trace session's selected pattern for that function.
Trace-session start and stop route through `Control`, using a deadlock-free
snapshot handshake, so they serialize with exclusion. Trace stores each full
strong OTP session handle in a private ETS table owned by the Trace process.
Only that process reads the table. Its GenServer state carries the private table
identifier, weak `{name, id}` identities and non-secret selection/configuration,
never a full handle; `Control` retains the same weak material. Trace returns a
fixed redacted `format_status/1` view for message, state, reason and log
contexts and never reads table contents into that view. Explicit stop retrieves
and destroys the full handle before deleting its row. Tracer death deletes the
table and drops the last ordinary strong holder; the replacement confirms the
weak old identity is absent before it creates and publishes a new session. A
replacement hello may reach Control before or after the predecessor monitor
`DOWN`; Control resolves that exact predecessor first and keeps the replacement
idle until it has received and applied the retained snapshot. `Control` retains live
sender membership and the ref-counted function set so a replacement trace
session reapplies the same exclusion. The tracer retains pending return timing
only at levels that request returns, monitors every pid represented there and
purges that pid's rows when it exits; managed exclusion also purges the sender's
rows after the delivery barrier. Thus clearing a flag cannot strand one call
row, and the Direct path returns to baseline when its sender exits. A `Control`
restart stops the private-table owner and, through `:rest_for_one`, the owner
groups beneath it. M5's
managed provider-lifetime starter makes both guardian and sender temporary
children of the existing per-owner worker supervisor; owner-group teardown
kills and awaits them before the supervisor may start the replacement tracer.
Each managed start is authorized by an exact operation handshake: a child that
materializes after its calling scope died remains inert and token-free,
observes owner loss and exits before starting any helper or provider action.
The guardian drops and flushes its temporary callback monitor only after Core
registration succeeds and it has installed the returned retainer monitor. The
sender does so only after the guardian has acknowledged its exact adoption and
installed the sender monitor. Lifetime then passes to Core's retainer, the
guardian-sender relation and their `owner_workers` parent, so ordinary callback
completion does not end retained post-result cleanup.
The callback also monitors each child from the first matching start message
that discloses its pid until that transfer completes; a child death in the gap
is `:unavailable`, not an unbounded wait.
No credential-bearing sender therefore crosses that loss with an unremembered
exclusion.

The same absolute invocation deadline allocated before managed start is the
only clock for the initialized guardian sequence; neither start nor adoption
resets it. Once both transfers complete, it covers provider launch and
readiness, sender release, exclusion, routing, custody resolution and the
credential-frame write. A capability or `Control` that is immediately
unreachable produces `:unavailable`; any of those steps that has not completed
when the deadline arrives causes the guardian to kill the sender and report
`:timeout`. There is no separate sub-operation timeout and no hidden
`GenServer.call/2` timeout. At the three dataflow boundaries the sender parks.
The exact result/continuation exchange above makes both processes apply the same
clock before the next phase begins.

**The existing direct `complete_prompt/3` helper remains a separate no-runtime
path, with an explicit option migration.** Its arity and result shape stay the
same, but an old environment-only options list no longer works and refuses
before launch with the adapter's ordinary missing-token result. Its caller
performs the same host work as the
reference compositions: it reads and deletes the environment input, creates
ephemeral custody and routing-registry processes, and passes only the opaque
token and handles. The adapter mints a private Direct marker for this helper;
runtime model options cannot select it, and every runtime-bound call requires
the managed starter above. Because the unmanaged sender can inherit named or
legacy trace flags from a traced caller, its token-free phase clears and
verifies every inherited live trace session before the guardian may deliver
the token. Its raw guardian starts the sender linked and monitored; abnormal
guardian loss ends it, while normal cleanup explicitly stops and awaits it.
The request's absolute deadline is allocated before Direct launch and carried
unchanged through inherited-session clearing, sink installation, routing,
custody resolution and the frame write. It does not alter or restore
runtime-owned MFA patterns: the helper
is outside ADR 0030's runtime process domain and this inherited-process clear is
defensive compatibility. This protects the direct helper's adapter sender from
Loopex tracing that already selected its ancestry; host custody and unrelated
host tracing remain the direct caller's responsibility, and no claim is made
against raw tracing started after the acknowledgement.

**Everywhere else the boundary is where the adapter's claims stop.** Inside it
— the token, the sender, the frame, the child — the adapter proves what it
says: the value is never in the child's environment, in argv, in the journal,
in a public event, a snapshot, a progress item or a diagnostic, in guardian,
coordinator, registry or other long-lived adapter state, in any message but the
one custody reply, in an exit reason, a crash report
or an IO request, and never written to a file. Outside it, custody belongs to the host and the adapter
proves nothing about it beyond the structural rules it does impose: the
registry holds routing only; the mandatory capability confirms exclusion before
the sender receives the token or registry handle; and losing custody, the
registry or the capability answers `:unavailable` rather than reconstructing or
bypassing anything. This pair therefore states
the reference implementations' custody as their own obligation rather than
claiming a property of every host that might compose a registry.

The operator still names the credential once, through the same environment
variable, and the reference implementations — the CLI, the app-server host and
the M5 daemon — read it exactly once where they compose the runtime and delete
it from the VM's environment in the same step, holding the bytes in their
custody process and registering its token from then on. The variable is a configuration input consumed at
composition, not a live transport for every call, and from the moment
composition completes the parent VM's environment carries no credential. M5
Outcome 6's claim is stated at that boundary: a claim that the variable is
never set at all would contradict the way an operator supplies a secret to a
process they start.

**One environment read stays, and this pair says why.** The launcher reads the
whole parent environment on every launch, so the Port can clear it name by
name from the first spawned image — `/usr/bin/env` itself, whose environment
`env -i` does not clear. That read is ADR 0019's scrubbing, not part of the
credential plane, and the maintainer decided on 2026-09-20 that it stays
exactly where it is.

Two earlier drafts of this pair touched it and both are withdrawn. Moving the
snapshot to composition was withdrawn because ADR 0019 constrains the host
only *during one launch*, so a snapshot reused across launches would claim an
immutability that decision never gave. Replacing it with a fixed closed
removal list was withdrawn because a fixed list cannot remove a name nobody
knew was there: the set present at a launch is not knowable before it, which
is precisely why ADR 0019 reads it then. Neither weakening is worth taking,
and leaving the read alone needs no amendment to ADR 0019.

So the prohibition this decision makes is narrower and exact: no **credential**
environment read in the adapter's call path. `ProviderBridge`, which holds the
sender and the whole credential path, reads no environment variable at all.
The launcher's read remains and is proved never to be consulted for a
credential — every name it yields is used only to remove that name.

**Alternatives rejected.** Keeping the environment variable and buying the
speed by sharding the provider suite across test VMs was rejected: it is
cheaper for speed alone and buys nothing for the credential plane, and it
answers a defect in the product with an arrangement of the tests. A credential
file in the invocation's namespace was rejected because it makes the secret
observable to anything that can read the directory, adds a removal step whose
failure is a leak, and survives a crash that the channel does not. Passing an
already-open file descriptor to the child over the socket was rejected because
it adds a platform-specific mechanism to a channel that already carries bounded
frames, without removing a single place the credential can be observed. Widening
the existing bootstrap frame to carry the credential alongside the manifest
digest was rejected because the child must prove its identity before it is
handed a secret, and that frame is sent before the child has proved anything.
Carrying the credential bytes in the per-invocation configuration, rather than
a token, was rejected because the bytes would then sit in adapter state,
in the messages that configuration travels in, and in any crash report that
prints it — the retention this decision exists to remove. Caching a resolved
credential in adapter-level state at composition was rejected for the same
retention reason and because a later rotation would not be resolved afresh by
each invocation. The selected token remains composition-bound, so two calls in
one runtime do not imply two different credentials. Two composed runtimes can
instead carry distinct tokens and custody processes without sharing a
credential slot. A resolver supplied as a function was rejected because a
closure is not plain boundary data and its captured environment is exactly the
retention the security review has to exclude.

**Implementation and milestone-closure evidence.** Outcome 5's integrated
real-provider daemon workflow waits on this decision as well as Outcome 6.
This is a trust claim, so its class is
negative tests plus a security review, with a real-provider proof for the path
the release check already runs. Every credential-plane negative that M0 to M2
established is re-pointed at the new handoff and must hold with its assertion
unchanged in meaning; the parent VM's environment is proved empty of the
credential from the completion of composition onward — before, during and
after a call; two runtimes with distinct registries, custody processes, tokens
and canaries run invocations at once, and each child and its diagnostics see
only its own runtime's credential; the two adapter preflight failures — absent
and malformed token — and every remaining invocation-private failure the
contract names —
immediate guardian start, Core registration, guardian authorization, sender
start or adoption refusal; sender raise, exit or kill before expiry and the
same `DOWN` consumed after expiry; an expired initialized deadline; immediate or blocked
provider readiness and group-leader sink installation; immediate and delayed exclusion failure; Direct-session
clearing failure, no registry row, a gone registry, a dead or refusing custody
process, malformed successful route or custody replies, registry or custody
silence, immediate or blocked frame write, and a value outside the size bound —
are proved to map to the seven closed reason atoms and to leave no retained
copy. The registry accepts only one exact valid custody reference or
`{:error, :unavailable}`; every other answer, including another in-set atom, is
normalized to `:unavailable`, while custody may originate only `:missing`,
`:expired` or `:unavailable`. Host composition separately proves refusal of a missing or malformed
registry handle, or a missing, malformed or unbound tracing capability, before
runtime use or child creation, with reverse cleanup of anything already
started. A live registry with no row for the token is instead an
invocation-time `:unavailable`. A non-answering managed start is proved to stay
in the Core owner-group liveness class rather than impersonate an adapter
timeout. The guardian's timeout is proved distinguishable from every refusal;
the same absolute deadline is proved not to reset across managed setup and,
after registration, adoption and initialize, to bound provider launch and
readiness, sender release, exclusion, routing, custody and frame writing
whatever the blocked operation does. Protocol witnesses inject wrong, stale
and malformed bootstrap and phase tuples, every result atom from the wrong
producer, and explicit error results; none can release context, receive a
continuation or start the next operation. At every sender release cut, paired
cases queue a valid message before the deadline and suspend the sender first
before receipt, then after receipt-time validation but before the permitted
operation, until the instant has passed. On resume it starts no next operation,
scrubs any credential bytes it still holds and exits with the fixed non-secret
`:credential_deadline` reason. The custody-to-frame cut specifically proves
that held bytes never reach a frame. A separate final-gate witness pauses after
the frame write and `:credential_frame` result but before the final
continuation. It proves the raw Task has tail-called the named non-secret
final-wait MFA through `Process.info/2` current-function and stacktrace evidence,
then refutes the canary in its mailbox, process dictionary and complete
forced-crash material; expiry there starts no invocation helper. The
guardian reports `:timeout` only after its own clock confirms expiry. Direct
mode separately proves that its
request's pre-launch absolute instant survives a delay beyond 5 seconds,
expires a clear held through that instant, and bounds custody and frame write;
at each of those cuts guardian loss reaps the raw linked-and-monitored sender
and sink with no late frame, while normal cleanup stops and awaits both. Two
same-runtime resolutions in flight at once are proved to be independent
successes rather than a refusal. A rotation fixture returns distinguishable
credentials to the two calls and binds each exact custody reply to that
invocation's sender and frame; a stale, wrong or cross-routed reply cannot
advance. Without a rotation, this same-runtime case makes no
distinct-credential claim. The tracer captures the expected token-free sender
start entry, deliberately backlogs
pre-clear traffic, and after the delivery-barrier-backed exclusion
acknowledgement receives no further raw trace event from that sender — including
no `:gen_tcp.send/2` event — while an unexcluded control produces one. An
isolated inspector proves token delivery follows the acknowledgement and that
the one custody reply is the only credential-bearing BEAM message. At each
handoff a fresh inspector suspends the intended receiver and reads that
receiver's actual `Process.info(pid, :messages)` after enqueue and before
receipt. At the credential-bearing handoff it matches the exact call-reference
reply wrapper containing the custody success. The inspector returns only a
fixed canary-free assertion outcome and terminates after each secret-bearing
observation because the read copies the canary into that process. It makes no
raw-Task state-inspection claim, and call-only tracing is not used to claim
application messages were observed. The last owner restores every live
session's selected MFA pattern; managed and Direct sender exit restore the
tracer's pending-call state
to baseline. Trace-session state, status and forced-crash witnesses prove that
`:sys.get_state/1` exposes the private table identifier and only weak or
non-secret metadata, never a full handle; a non-owner cannot read that table.
`format_status/1` keeps full handles and arbitrary message, state, reason and
log terms out of status and crash output while exact Trace operations still
work. Its forced-crash case makes a raw `complete/3` tuple carrying distinct
token and registry-handle canaries the actual last message, asserts the fixed
redacted fields, and refutes both canaries in the complete report and observed
exit. The ordinary restart case retains only the weak identity and proves that
predecessor death deletes the private table and makes that identity absent.

A deliberate fault fixture retains one extra strong handle to exercise the
still-present identity and defensive destroy branch. The restart cases also
prove that destroyed-session flags are not treated as persistent and retained
membership protects a replacement session; missing or malformed registry
handles and missing, malformed or unbound tracing capabilities,
immediate capability loss and delayed exclusion distinguish composition
refusal, `:unavailable` and the guardian's `:timeout`; the adapter's library
tree is proved to read
no environment variable for a credential by any route, with the launcher's
ADR 0019 scrubbing read proved never to be consulted for one; and a named
reviewer reads
the handoff — the token's opacity, the registry's routing-only contents,
resolution point, frame ordering, failure paths, the host implementations'
custody, and every place a value could be retained
— and records the reading with the milestone.
The real-provider lane in `bash scripts/check-release.sh` proves the path
still reaches a real provider. Every credential-consuming case runs in its own
fresh child BEAM inherited from the release shell, because reference
composition consumes and deletes the variable and never restores it; each run
must execute exactly one named case. The concurrency result is a measurement
recorded beside the M4-closure baseline, not a pass condition.

Technical depth: [Contract and evidence](0034-provider-credential-handoff-over-bootstrap-channel-technical.md#technical-adr-0034-decision).

<a id="concept-adr-0034-consequences"></a>
### Consequences, Compatibility and Rollback

The credential plane gets the property the rest of ADR 0019's design already
has. For the reference hosts after composition, the live logical copies in the
parent are the host's custody process, which holds and answers for the secret,
and the short-lived sender, which receives it once, writes it and dies; the
child also receives the value it needs. Composition necessarily handles the
input transiently, and another host may choose a different defensible custody
mechanism. This is a dataflow and logical-custody claim, not a claim of erased
memory or forensic inaccessibility; ADR 0019's disclaimer remains. The secret
is not retained in guardian, coordinator, registry or other long-lived adapter
state, the environment after reference-host composition, a
durable or public plane, or any message except the one custody reply this pair
permits. Two separately composed runtimes in one VM can carry distinct tokens,
custody processes and credentials. Reference runtime hosts and Direct callers
each compose their own registry, custody and token, so the **eleven** provider
test modules serial for this reason can run concurrently and the fast check
stops being pinned by that application. Within one runtime, concurrent calls
still resolve the composition-bound token independently; a custody rotation
binds the reply it returned to that invocation's sender and frame. Calls in one
runtime do not otherwise claim distinct credentials. The other two modules
stay serial on their own reasons, which is why the claim is eleven rather than
thirteen. Host composition gains three explicit model inputs — the credential
token, registry handle and tracing capability —
and owns the registry, custody process and capability behind them. It starts
those processes before the runtime, binds the capability after runtime start
but before reporting composition success, and stops all three on normal stop,
failed start and owner loss. A host that supplies no token gets the adapter's
ordinary
refusal to dispatch, which is what a missing environment variable produces
today.

The public `complete_prompt/3` helper keeps its arity and result union, but its
accepted options change: callers must compose ephemeral custody and a routing
registry and pass their token and handle. An environment-only call now refuses
instead of making the adapter read the environment. The `Loopex.Model`
callback, public events, snapshots, artifacts, wire methods and protocol
generations, durable records, and what the child may receive remain unchanged. The
credential-size bound and the refusal behaviour ADR 0019 fixed stay as they
are. Rollback reverts the adapter, trace-exclusion support and the CLI,
app-server and daemon composition changes together. No data, root or protocol
depends on which mechanism delivered a credential to a process that has since
exited, so rollback needs no data migration or repair.

Technical depth: [Compatibility mechanics](0034-provider-credential-handoff-over-bootstrap-channel-technical.md#technical-adr-0034-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
