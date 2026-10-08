<a id="concept"></a>
## Concept

Technical depth: [Bounded progress delivery](0058-bounded-progress-delivery-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-10-06
- **Decision owner:** Maintainer
- **Completes:** M7's live ordinary progress and ADR 0054 activity delivery under the existing transport limits.

<a id="concept-adr-0058-context"></a>
### Purpose and observed gap

Technical depth: [Source and authority](0058-bounded-progress-delivery-technical.md#technical-adr-0058-context).

An attached caller should receive live model, tool and compaction progress while
durable work continues. Slow output must consume bounded resources and leave a
truthful cursor for reconnect. A queue limit alone does not establish this.

The current native path sends payloads into Control, StreamRelay and configured
PID mailboxes before a transport applies its queue limit. A 65,536-byte chunk
limit bounds one chunk, while neither chunk count nor active session count is
capped. The foreground transport also writes through shared standard IO without
the writer acknowledgement or five-second bound ADR 0023 requires.

This proposal amends native progress admission and delivery ownership. It keeps
durable results, provider permits, session authority and the accepted six-field
compaction item unchanged. It supplies no generation activation or completed
platform proof.

<a id="concept-adr-0058-admission"></a>
### Proposed native admission decision

Technical depth: [Capability, credit and pressure](0058-bounded-progress-delivery-technical.md#technical-adr-0058-admission).

Replace runtime `progress_to` PID delivery with one optional Core-owned
`Loopex.ProgressSink` capability. Its shared native ingress holds at most 32
items and 512 KiB across that runtime's sessions. Admission is an atomic,
finite local operation before the first payload mailbox. A charged item keeps
its credit while any delivery holder retains it. Control still serializes the
current-owner fence; it receives a charged reference rather than an unbounded
payload. No arbitrary host callback executes there.
The new trusted API opens a sink, tries an already projected offer, takes a
leased item, releases proved custody and closes the sink.

Keep existing Model and Executor progress functions returning `:ok`. Pressure
changes their transient delivery only. For an ordinary domain, the first
capacity refusal or exhausted finite admission attempt seals its payload
ingress for the rest of that attempt. Already admitted items form its retained
prefix. Later offers do not enter the stateful executor validator and cannot
be mistaken for bad sequences or offsets. This tail-loss rule is an explicit
observable amendment to ADR 0011. A later attempt opens a fresh domain.
Private validation-refusal counters describe only that observed prefix;
the producer's original complete totals remain unchanged.

Keep terminal closures truthful and separate from sealing. A complete closure
states the producer's original count; an abandoned closure states the relay's
actual projected count. Capacity loss never declares an attempt abandoned,
changes a receipt or creates a run failure. A closure may itself be lost.
Compaction activity remains independently droppable, with no tail state,
closing notice or synthetic replay. Durable state remains the outcome source.

Notifications and retirement controls are coalesced and bounded. Native
handles and credit evidence remain trusted in-VM configuration and custody,
outside public DTOs, jobs, journals and the wire. This is a capacity mechanism,
not host policy or effect authority.

<a id="concept-adr-0058-writer"></a>
### Proposed foreground writer decision

Technical depth: [Owned output and exact completion](0058-bounded-progress-delivery-technical.md#technical-adr-0058-writer).

Make executable `/bin/bash` an explicit prerequisite for the Stdio adapter,
including hosts that choose another executor. Core and other transports acquire
no Bash requirement. ADR 0022 previously required Bash only for Local executor
supervision; it does not authorize this extension.

Stdio owns one private proxy process group and one frame worker at a time.
The worker acknowledges a full write to the actual inherited stdout. The
proxy then joins that exact worker before acknowledging release. Only this
joined acknowledgement releases capacity or advances a durable cursor.
The five-second writer interval includes full write and join. On expiry the
connection detaches immediately and starts a separately bounded 5,000-ms
cleanup observation. That new cleanup bound is an explicit part of this
proposal; it cannot extend delivery or the existing 30-second request waits.
Unproved cleanup is failure, never a successful release or permission to start
another writer on the same output.

Snapshots, replies and durable events share a bounded FIFO. Progress runs only
when durable output permits it. Count the active frame in the unchanged limits
of 64 durable records / 4 MiB and 32 progress records / 512 KiB. Reserve reply
capacity before a mutation; pressure after admission yields detach or unknown
delivery, never a fabricated mutation refusal. EOF retires attachment holders,
input port, proxy and workers without recording abort or cancellation.

<a id="concept-adr-0058-alternatives"></a>
### Options and consequences

Technical depth: [Alternative costs and feasibility](0058-bounded-progress-delivery-technical.md#technical-adr-0058-alternatives).

1. **Select the bounded sink, tail-loss rule and Stdio Bash prerequisite above.**
   This keeps the existing executor validator owner and adds one concrete
   output mechanism. Under pressure an attempt may become quiet until its
   terminal closure; durable work continues. Every Stdio user must supply Bash.
2. **Resume ordinary progress within the same attempt after pressure.** This
   needs a new finite local owner for executor validation before dropping any
   raw event. Its atomic ordering, offsets, refusal accounting and contention
   behavior must be specified and proved before revising the pair. Moving the
   current payload to another asynchronous broker does not solve the problem.
3. **Scope Bash to the reference host only.** Generic Stdio would instead
   require a host-supplied owned-writer capability with full-write, join and
   cleanup conformance. This avoids a general Bash prerequisite but adds a
   public host/transport contract. Revise and review that exact interface before
   selecting this option.

Receiver-only queue limits, a timed task around `IO.binwrite`, and a raw stdout
fd port are insufficient. They leave an earlier payload mailbox or a shared
blocking write outside the claimed cleanup owner.

<a id="concept-adr-0058-rollout"></a>
### Compatibility, rollout and required proof

Technical depth: [Migration and qualification](0058-bounded-progress-delivery-technical.md#technical-adr-0058-rollout).

Migrate all current embedded, composition, command, foreground and daemon
callers to the capability, then delete PID delivery and superseded paths in the
same integration. Before 1.0, retain one current contract. No persistent record
or wire payload changes here; current-format replay and backup/restore remain
required. The daemon must apply credit before every fanout copy and preserve
its existing socket writer ownership and per-connection limits.

Required proof includes actual producers, concurrent admission and death at
every custody transition, pressure with truthful count/closure interpretation,
real blocked stdout and broken pipes, EOF cleanup, and independent clients.
Darwin and Linux process/group/descriptor proofs remain required on both
supported toolchain pairs. Source inspection is feasibility evidence only.
Unactivated source rollback must stop and join current delivery owners first;
it does not qualify the previously unbounded implementation. A different
activated current contract requires a governed coordinated decision.

Acceptance binds this exact pair and authorizes only its named implementation.
It waives no required check, live-progress outcome, milestone review or closure.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-bounded-progress-delivery-2026-10-07) | candidate `3c97b6a1ca0cd73350cfe0f1b55c05fff316e655`; concept `sha256:292a45cec72a9011e1bb6eb48eebccdd24a325c11f43b083089f8008db781762`; technical `sha256:57fd78afae837af50c2cc51123083413a519b06f75cb656b101b6f36c6c39f12` |
