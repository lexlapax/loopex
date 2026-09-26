# App Server Protocol

<a id="concept"></a>
## Concept

Technical depth: [Protocol contract, records and limits](app-server-protocol-technical.md#technical-depth).

The experimental session protocol lets a program in any language drive a Loopex
session over a byte stream: create or resume a session, attach at a durable
cursor, submit prompts and other commands, answer a host policy's questions,
select project skills, read artifacts back in verified chunks, and receive
committed events and transient progress. It is one JSON object per line, spoken
by two servers:

- **The app server** (`loopex_app_server`) is a foreground process that serves
  one connection over its standard input and output and speaks generation
  `loopex.experimental/1`.
- **The daemon** (`loopex_daemon`) is a long-lived host that serves many
  connections over a Unix-domain socket and speaks generation
  `loopex.experimental/2`: everything in generation 1 plus session listing,
  daemon status, and controller leases. See [the daemon](daemon.md#concept).

This pair is the normative reference for what the protocol is, what it is not,
and which constraints a change to it must respect. The founding decision is
accepted [ADR 0023](../adr/0023-experimental-public-session-protocol.md#concept);
the daemon's additions rest on
[ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept) and
[ADR 0033](../adr/0033-collaboration-controller-lease-and-takeover.md#concept).
An independent consumer written in plain JavaScript lives in
[`clients/node`](../../clients/node/README.md), and the operator's view is in
[App server operations](../operator/app-server.md#concept).

<a id="concept-protocol-one-contract"></a>
## One Contract, Not a Second Loop

The non-negotiable is **session before surface**. The runtime is headless; the
command, IDE, daemon, web, and embedded callers are peers over one semantic
contract, and no surface owns an alternate loop or an alternate durable truth.

So a server maps wire requests onto the same runtime operations a host already
calls. The app server's `Loopex.AppServer.Mapping` and the daemon's connection
process translate and validate; they do not decide, do not hold session state
the coordinator owns, and do not reach a coordinator or a Store directly. A
method that needed to would be a design error, not a mapping problem.

This is why the protocol has no method for configuring a runtime. Store, model,
executor, tools, policy, and skill manifest are launch inputs chosen by the
host. A client drives a session; it does not compose one, and no frame can
replace an immutable launch input. An `admission` reply means a command was
accepted and journaled, never that the run has done anything; what the run then
does arrives as events.

Technical depth: [The methods](app-server-protocol-technical.md#technical-protocol-methods).

<a id="concept-protocol-experimental"></a>
## Experimental Is in the Name on Purpose

The word `experimental` is part of each generation string. A client cannot read
it as a released contract and no version comparison can round it up to one.

Generation selection is exact. A client offers an ordered list, the server picks
one it knows, and there is no partial match and no nearest neighbour. A client
offering only an unknown generation is refused rather than served something
close. The `initialized` reply reports the selected generation and a digest of
the exact schema, so a client verifies the contract it is about to speak rather
than assuming it.

Public compatibility in this repository is behavioural and requires schemas,
vectors, independent consumers, migrations, and upgrade evidence. Each
generation has schemas, vectors, and an independent consumer; none has a
migration path or a freeze, and any may change. See
[Compatibility surfaces](compatibility-surfaces.md#concept).

Technical depth: [Generation and negotiation](app-server-protocol-technical.md#technical-protocol-generation).

<a id="concept-protocol-strict"></a>
## Strictness Is the Feature

Framing and decoding refuse where a lenient parser would repair:

- one JSON object per line, LF only — a carriage return is a protocol error, not
  something to strip;
- duplicate object members are refused, not collapsed to the last;
- a float where an integer belongs is refused, not rounded;
- trailing bytes after a complete value are refused; and
- control characters inside strings are refused.

A client that is lenient about framing will not notice a server that is. The
refusals are what an independent implementation checks itself against, and the
conformance vectors assert that their reasons are *distinct* — an implementation
collapsing a duplicate member, an unrepresentable integer, a trailing byte, and
a lone surrogate into one error fails.

The decoder is written without a JSON library, because the contract application
that holds it carries no dependency at all, and because a general decoder does
not refuse duplicates, bound depth while parsing, or keep keys from being
interned.

Technical depth: [Framing and decoding](app-server-protocol-technical.md#technical-protocol-framing).

<a id="concept-protocol-planes"></a>
## Two Delivery Planes, Bounded Separately

A client receives two kinds of unsolicited record, and conflating them would be
a correctness bug rather than a cosmetic one.

**Durable events** are history. They advance a client's cursor, and losing one
silently would leave that client's view permanently wrong. When the queue
overflows, the client is **detached at its cursor**, so it can reattach and
replay.

**Progress** is a rendering aid. It advances nothing, and when its queue
overflows it is **dropped**, because losing it costs only smoothness.

That difference is why the two have separate, differently sized queues rather
than one shared budget.

Technical depth: [Exact limits](app-server-protocol-technical.md#technical-protocol-limits).

<a id="concept-protocol-foreground"></a>
## Foreground, Not a Daemon

The app server owns no session residency. Its loss is an ordinary host loss: the
durable session stays where it was. There is no socket, no background lifetime,
and no takeover between clients. A connection holds at most one attachment: a
second `session.attach` on it is refused `attachment_conflict` unless it sets
`replace`, which replaces the connection's own attachment.

Ending input is not cancelling. Clean EOF and abrupt death both leave a pending
interaction pending; `session.abort` is the only deliberate cancellation. A
transport that blurred those would make a client's disconnection into a silent
cancellation, which is precisely the failure mode durable interactions exist to
avoid.

Technical depth: [The transport process](app-server-protocol-technical.md#technical-protocol-transport).

<a id="concept-protocol-daemon"></a>
## What the Daemon's Generation Adds

Generation 2 keeps generation 1's framing, records, codes, and limits, and adds
what several clients sharing one daemon need. A client can list the sessions a
root holds and ask for the daemon's status. Any number of connections may observe
a session, but only the connection holding the session's controller lease may
change it: a client acquires control, receives a writer epoch, presents that
epoch on every mutation of an existing session, and renews the lease before its
term lapses. Takeover waits for the holder to release or for the lease to
lapse; nothing forces a live holder off. The daemon can also tell every client
it is stopping, and why.

Technical depth: [The daemon's generation](app-server-protocol-technical.md#technical-protocol-generation-two).

## Related

- [Architecture](architecture.md#concept) — where these applications sit and which way they depend.
- [The daemon](daemon.md#concept) — the host that serves generation 2.
- [Compatibility surfaces](compatibility-surfaces.md#concept) — what "experimental" commits to.
- [Observability](observability.md#concept) — the diagnostics plane this never writes to.
- [Getting started](getting-started.md#concept) — a first protocol client.
- [Operator app server runbook](../operator/app-server.md#concept).

Back to the [developer index](README.md).
