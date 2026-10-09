<a id="technical-depth"></a>
## Technical depth

Concept: [CLI-owned output](0068-cli-owned-output.md#concept).

Proposed design. The 5,000-ms acquisition interval is
proposed here; no dependent implementation or acceptance is authorized.

<a id="technical-adr-0068-decision"></a>
### Private interface and custody

Concept: [Purpose and proposed decision](0068-cli-owned-output.md#concept-adr-0068-decision).

The [vision ownership map](../vision-technical.md#technical-vision-ownership-trust)
places delivery in the host. [M7 outcome 6](../plans/M7.md#concept-plan-outcomes)
requires useful terminal and piped conversation through the public session
contract. ADR 0058 supplies native custody; ADR 0049 supplies transcript
limits. This pair selects the missing physical CLI owner.

Today `ChatOutput` joins a worker calling `IO.binwrite`, while its borrowed
device can retain the request. `Render` consumes mailbox progress and retains
domain text beyond a write. A sink-option rename cannot repair either cut.

Use one private CLI output process per command, unlinked from the foreground
command and monitoring it. This process alone opens, takes, releases and closes
its `ProgressSink`. It owns rendering state and one combined stdout/stderr
queue with one active write. The target owns its pending-write subtree and
observes output-owner loss through its original control channel or monitor.
Neither process automatically restarts on the same target. Custom target
acquisition precedes any payload transfer; original identities and monitors
are captured before custody changes.

The private command-to-output interface is limited to:

| Operation | Meaning |
| --- | --- |
| `open(command, target_spec, acquisition)` | Acquire targets and open the native sink; return an opaque output handle and sink, or a fixed acquisition failure. `target_spec` is `:stdio` or an owned custom-target acquisition from trusted CLI host code. `acquisition` carries the command's original monotonic start/cutoff and fresh acquisition identity. |
| `reserve(output, kind, destination, byte_count, domain)` | Reserve transcript capacity using metadata only; return one-use ticket, `dropped` for progress, or a fixed error. Kinds are control/text/progress; destinations are stdout/stderr; domain is an existing progress identity or nil. No payload enters this request. |
| `submit(output, ticket, bytes)` | Transfer exactly the reserved byte count to that owner's queue. The ticket binds caller, output incarnation, destination, kind and domain. Return admission only. No second submission or size substitution. |
| `settle(output, domain)` / `status(output)` | Return bounded delivery counters or metadata, excluding payloads and raw errors. Settlement discards undelivered queued fragments and retires suppression evidence only when its copies are gone. |
| `finish(output, cutoff)` / `retire(output, cutoff)` | Seal admission, drain or discard as appropriate, and join original resources within the remaining existing cutoff. Return confirmed completion or fixed failure/cleanup-unproved. |

Immediately before the first CLI output-acquisition effect, the original
command captures monotonic A and D_acquire=A+5,000 ms once, together with a
fresh acquisition identity. The proposed private `open` receives that exact
context. Migrate ordinary, ask and chat callers to capture it rather than
refusing otherwise valid current callers for lacking a historical cutoff.
Target launch, original identity/monitor capture, custom ownership transfer,
native sink opening and publication all spend D_acquire. Check freshness
before each effect and before/after accepting its original acknowledgement;
publication requires the original caller's final check strictly before the
cutoff. Queueing, a late reply, recovery inspection or final-runtime binding
cannot renew it. Core's runtime creation and configuration preparation clocks
start at their own existing cuts and supply none of this acquisition time.

The original caller independently observes its acquisition cutoff. Issue
target acquisition as one finite metadata request to its original
target owner, not an arbitrary blocking constructor inside the custodian.
There is one acquisition identity and one outstanding ownership handshake;
acknowledgements bind creator, target incarnation and that identity. Waits use
only the remaining D_acquire, including the caller's open/publication wait.
No extra acquisition task, service or unbounded callback wait is introduced.
The target's existing retirement mechanism owns cancellation of pending
acquisition and acquired resources. Capture original resources before the
first failure window; an expired handshake does not prove nothing was created.

On failed acquisition or caller loss, seal payload/runtime admission and
retire/join acquired resources using only remaining D_acquire. A missed join
is acquisition failure with cleanup-unproved and nonzero exit, not permission
for a replacement target or renewed open. Keep the original custodian/target
custody for late reclamation. If an existing native close or original target
operation outlasts the cutoff, the caller still reports failure at that cut;
its tardy completion cannot count as timely cleanup or reopen admission.
Scheduling delay prevents a hard-real-time return guarantee. Do not write
through the failed target, instantiate a borrowed error writer or borrow a
session's cleanup grace before any runtime exists. Independently owned
diagnostics retain their own existing limits and unconfirmed-delivery meaning.

Only the original command may use these operations. At most one metadata
reservation per command is outstanding; no asynchronous reservation queue or
unbounded acknowledgement list is added. Empty output creates no queued item.
An outstanding reservation counts against the existing queue and retains the
control admission instant. Command loss invalidates it and retires the owner.
The custodian consumes native items directly; leases are not transferred to
the command through this interface.

Keep 32 native slots and 524,288 charged bytes. Keep 262,144 transcript bytes
across reservations, queued and active output, and the 65,536-byte control cap.
The two ceilings remain independent. Inventory simultaneous native backing,
rendered/escaped bytes, mailbox copies, proxy/control buffers, custom device
requests and suppression text. Prove each native representation fits its
original conservative reservation before materializing it; otherwise drop
before that copy. Add no credit-extension API or silent limit increase.
Preserve existing required-output overflow failure and progress-first pressure.

An item's full-write acknowledgement does not release its native lease while
domain text still exists. Retain that credit until domain settlement discards
all suppression copies. Preserve the existing exact-text suppression test;
counts or a source closure alone cannot replace it. Charge materialization
peaks too.

The stopped-output allocation/capacity proof remains an activation prerequisite,
not a consequence of these numbers. If it cannot pass without changed limits
or live-output behavior, stop for a separately reviewed decision.

<a id="technical-adr-0068-alternatives"></a>
### Target mechanisms and alternatives

Concept: [Alternatives and recommendation](0068-cli-owned-output.md#concept-adr-0068-alternatives).

For `:stdio`, require executable `/bin/bash` with Bash 3.2-compatible fixed
assets. Use an explicit credential-free environment, fixed executable/script,
actual inherited fd 1 and fd 2, and separate private control descriptors.
Output never supplies shell syntax, paths, environment or destination fds.
Raw length framing must preserve every rendered byte, including empty data,
NUL and LF, without shell-variable loss, inserted delimiters or destination
swaps. Do not import Stdio's strict-LF UTF-8 validator, 2 MiB frame cap, fd2
closure or separate cleanup allowance. Stdio is mechanism evidence only;
this pair introduces no shared writer contract or CLI-to-AppServer dependency.

The 5,000-ms choice allows startup/handshake scheduling on the same familiar
scale as existing CLI output waits, but those waits do not authorize it and
source arithmetic proves no supported-target fit. The coherent 1,000-ms
alternative replaces only the acquisition interval throughout this pair;
all acquisition stages and cleanup share that shorter original cutoff. It
would increase cold-start/load refusals. It is unrelated to StartupGate's
one-second read allowance. Neither choice changes subsequent delivery clocks.

Deferred writer launch is permitted only after real exclusive target custody
is acquired within D_acquire. Its later launch, first write and exact joins
must spend an already captured control/finish cutoff. If a text/progress path
has no such cutoff, finish writer readiness inside acquisition instead.
Do not capture a synthetic control deadline before provider preparation,
invent an empty control write, or move the same blocking acquisition into a
lazy factory. This conditional optimization adds no target kind or actor.

Each write ticket additionally binds the target incarnation, original worker
and monitor, item identity and acknowledgement nonce. Full completion requires
the actual successful full destination write, exact worker wait, original
proxy/port completion and proof that its pending copies are gone. Keep a live
identity anchor until process-group termination begins; a recycled OS PID
cannot authorize cleanup. Wrong actor/nonce, duplicate, out-of-order or trailing
acknowledgements retire the target. A raw fd port or sender DOWN alone is
insufficient.

For custom IO, trusted CLI host code supplies an acquisition that transfers
exclusive pending-write ownership to this output incarnation. It must identify
the original device root, every downstream pending-copy holder and their
original joins before accepting bytes. Acquisition succeeds only after both
creator and output owner acknowledge that same incarnation. A PID, group
leader, IO atom or asserted `owns_device` flag cannot substitute. The creator
must refuse if a downstream device is borrowed or its lifecycle cannot be
transferred. This private constructor is not model configuration or a Core
callback registry.

Success requires the original device's full-write response and joins or
verified discard of every remaining request holder. Failure requires stopping
and joining the owned subtree, or a matched cancellation/discard response
proving no pending copy can later emit. Root DOWN alone is insufficient when
a descendant or forwarded request survives. Target-side owner-loss retirement
must remain effective after the foreground command or custodian dies. Loss of
the proof holder yields cleanup-unproved and fences target reuse; native arena
destruction supplies no external cleanup proof. No VM-wide gate is introduced.

Diagnostics keep their existing independent redacted queues, loss counters and
delivery-unconfirmed meaning. They hold no native progress leases. Shared
stderr may interleave as today; routing Composition diagnostics through this
owner would require a separate cross-application acquisition decision.

<a id="technical-adr-0068-evidence"></a>
### Cutoffs and qualification

Concept: [Consequences and required proof](0068-cli-owned-output.md#concept-adr-0068-evidence).

| Cut | Required observation |
| --- | --- |
| Proposed acquisition starting at A | Capture D_acquire=A+5,000 ms once, before output effects and runtime/provider preparation. Setup, custody handshake and caller publication complete strictly before it. Failure cleanup uses its remaining time; no second grace. |
| Control admitted at A | Capture D=A+5,000 ms at reservation. Submission, queue transit, full write and positive joins all spend D. |
| Finish requested at F with supplied ceiling S | Capture min(S,F+5,000 ms), retaining earlier control cutoffs. |
| First stop/unknown at T with committed cleanup grace G | Keep ADR 0016's `B(G)=max(10000,G+2000)+(ceil(G/4)+2000)+max(10000,ceil(G/4)+2000)` and H=T+B(G), shortened by existing shutdown/output cutoffs. Default G=5,000 gives 23,250 ms. |
| Retirement/native close | Spend the remaining applicable captured cutoff; neither a native close wait nor a physical cleanup stage adds time. Missing joins remain unproved/nonzero. |
| Progress/text | Retain the absence of an independent enqueue deadline. Credit, queue pressure and existing control/finish/stop cutoffs govern; add no per-item timeout. |

Retirement may continue after a caller reports unknown, but cannot upgrade that
original verdict or authorize replacement output. Stdio's separate five-second
cleanup interval and the stalled-pipe fixture's observation grace do not amend
CLI production cutoffs. No D+G production extension is selected.

Advance durable output cursors and suppression only from joined delivery.
A full visible prefix with a lost acknowledgement remains unconfirmed. Do not
append an error to an unknown prefix or blindly retransmit it. Durable fallback
may repeat an incomplete transient answer; it must not suppress undelivered
text. Preserve original producer totals, abandoned projected counts, ordinary
tail sealing and independently droppable six-field compaction activity. Output
failure does not alter a committed run outcome or prove runtime cleanup.

Required tests retain all existing cases and cutoffs, with actual original
actors and unconditional cleanup joins. Exercise a device retaining a request
after sender DOWN; downstream-copy discard; full write with delayed join or
lost completion; wrong ticket/nonce/actor; owner/target/worker/port loss; and
resumption after cutoff. Prove suppression text and all simultaneous copies
remain charged under stopped-output pressure without increasing limits.
Add actual held/partial acquisition, caller loss during transfer, wrong or late
original acknowledgements, deadline exhaustion with pending descendants and
late original joins. Prove no payload/runtime/provider work before ownership,
no second acquisition on recovery, no replacement while cleanup is unproved,
and refusal without writing through the failed target. Exercise the original
cutoff at both owner and caller publication, including queued late replies.
Exercise settlement/cursor ordering, durable fallback, separate recovery and
final-runtime bindings, and ordinary/compaction progress. Qualify actual
stdout/stderr pipes, PTYs, broken output, raw-byte fidelity, fd separation,
process groups and descriptor retirement on Darwin and Linux under both
supported toolchain pairs. Custom-device fixtures do not replace OS proof.
Include credential/private-data canaries and Bash/prerequisite packaging checks.

<a id="technical-adr-0068-compatibility"></a>
### Migration and confinement

Concept: [Compatibility and rollout](0068-cli-owned-output.md#concept-adr-0068-compatibility).

Implementation belongs to CLI acquisition, `Render`, `ProgressConsumer`,
`ChatOutput`, `ChatDriver`, `Live` and their actual callers, plus the small
private owner/target assets and prerequisite documentation. Migrate all
current progress routes together; remove `progress_to`, payload-mailbox
bridges and borrowed-device fallback. Wire ingress retains its existing
validation and credit before an additional local copy. No public/executor DTO,
durable record, provider authority or session owner changes.

Recovery inspection uses nil progress or its own fully retired sink. Open a
fresh final sink for the serving runtime; never bind one sink to both runtime
incarnations or weaken Core's binding check. The output owner may outlive
inspection while those sink lifetimes remain distinct.
That owner is acquired once for the command. Runtime rebinding does not repeat
or renew the output acquisition interval.

Before rollback stop and join the exact current output resources. Preserve
durable history and uncertainty; do not reactivate an unsafe borrowed route
as a proved implementation. This Proposed pair supplies no acceptance,
native result, allocation measurement, activation or M7 closure. Exact-pair
acceptance must precede dependent implementation.
