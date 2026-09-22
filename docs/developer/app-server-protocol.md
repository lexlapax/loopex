# App Server Protocol

<a id="concept"></a>
## Concept

Technical depth: [Protocol contract, records and limits](app-server-protocol-technical.md#technical-depth).

M4 adds the first surface that is not an Elixir API: a foreground process
speaking one JSON object per line over standard input and output. This document
is the normative reference for what that surface is, what it is not, and which
constraints a change to it must respect.

The founding decision is accepted
[ADR 0023](../adr/0023-experimental-public-session-protocol.md#concept). The
generation is named `loopex.experimental/1`.

<a id="concept-protocol-one-contract"></a>
## One Contract, Not a Second Loop

The non-negotiable is **session before surface**. The runtime is headless; CLI,
IDE, daemon, web and embedded callers are peers over one semantic contract, and
no surface owns an alternate loop or an alternate durable truth.

So the app server maps wire requests onto the same facade a host already calls.
`Loopex.AppServer.Mapping` translates and validates; it does not decide, does
not hold session state the coordinator owns, and does not reach past the facade
into a coordinator or a Store. A method that needed to would be a design error,
not a mapping problem.

This is why the protocol has no method for configuring a runtime. Store, model,
executor, tools, policy and skill manifest are launch inputs chosen by the host.
A client drives a session; it does not compose one, and no frame can replace an
immutable launch input.

<a id="concept-protocol-experimental"></a>
## Experimental Is in the Name on Purpose

The word `experimental` is part of the generation string. A client cannot read
it as a released contract and no version comparison can round it up to one.

Generation selection is exact. A client offers an ordered list, the server picks
one it knows, and there is no partial match and no nearest neighbour. A client
offering only an unknown generation is refused rather than served something
close.

Public compatibility in this repository is behavioural and requires schemas,
vectors, independent consumers, migrations and upgrade evidence. This generation
has schemas, vectors and an independent consumer; it has no migration path and
no freeze, and it may change in any later milestone.

<a id="concept-protocol-strict"></a>
## Strictness Is the Feature

Framing and decoding refuse where a lenient parser would repair:

- one JSON object per line, LF only — a carriage return is a protocol error, not
  something to strip
- duplicate object members are refused, not collapsed to the last
- a float where an integer belongs is refused, not rounded
- trailing bytes after a complete value are refused
- control characters inside strings are refused

A client that is lenient about framing will not notice a server that is. The
refusals are what an independent implementation checks itself against, and the
conformance vectors assert that their reasons are *distinct* — an implementation
collapsing a duplicate member, an unrepresentable integer, a trailing byte and a
lone surrogate into one error fails.

The decoder is dependency-free. It exists because core's dependency budget
admits one external dependency and it is not a JSON library.

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

<a id="concept-protocol-foreground"></a>
## Foreground, Not a Daemon

The process owns no session residency. Its loss is an ordinary host loss: the
durable session stays where it was. There is no socket, no background lifetime,
and no takeover — a second attachment to one session is refused as a conflict
rather than displacing the first.

Ending input is not cancelling. Clean EOF and abrupt death both leave a pending
interaction pending; `session.abort` is the only deliberate cancellation. A
transport that blurred those would make a client's disconnection into a silent
cancellation, which is precisely the failure mode durable interactions exist to
avoid.

## Related

- [Architecture](architecture.md#concept) — where this application sits and which way it depends.
- [Compatibility surfaces](compatibility-surfaces.md#concept) — what "experimental" commits to.
- [Observability](observability.md#concept) — the diagnostics plane this never writes to.
- [Operator app server runbook](../operator/app-server.md#concept).

Back to the [developer index](README.md).
