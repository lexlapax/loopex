# The Daemon

<a id="concept"></a>
## Concept

Technical depth: [Processes, orders, bounds and evidence](daemon-technical.md#technical-depth).

`loopex_daemon` is the host application that keeps one state root's sessions
alive between separate operating-system processes. It composes the reference
runtime once, listens on a Unix-domain socket inside that root, and serves the
generation-2 session protocol to any number of clients. The
[operator page](../operator/daemon.md#concept) says how to run it; this page is
for changing it.

The daemon is not a second loop. Every session still has one serial
coordinator in core, which is the only writer of its durable truth, and every
client request reaches core through the same facade an embedding host calls.
The daemon adds three things core deliberately does not own: a socket
transport, a controller lease that decides which connection may mutate a
session, and a lifecycle that acquires and releases a root's exclusive
resources in one order.

<a id="concept-daemon-host-role"></a>
## A Host, Not a Surface Over a Host

The daemon has the host role, beside the app server and the reference CLI. It
alone chooses the workspace, the provider launch, the policy and the
credential, when it starts; a client can name none of them. That is what keeps
a connection from replacing host authority: the socket carries session
commands, never composition. The reference CLI starts the daemon and is also
one of its clients, but its live forms own no loop and no durable state — they
render what the daemon sends and reconnect when the socket drops.

<a id="concept-daemon-authority"></a>
## Controller Authority Lives Outside the Journal

Any number of connections may observe a session; one at a time may control it.
Control is a lease the daemon grants under a writer epoch, renewed every ten
seconds against a thirty-second term, and never written to the journal. A lease
is a daemon-lifetime fact about which connection may speak for a session right
now; the journal records what the session did. Keeping the two apart means a
restarted daemon starts with no leases and no stale holder, and a lease loss
can never rewrite history.

Takeover waits for the holder to release or for the lease to lapse on the
daemon's monotonic clock. Nothing forces a live holder off.

<a id="concept-daemon-accounting"></a>
## Nothing Admitted Is Forgotten

The daemon's hardest obligations are about loss. A socket can close, a client
can be killed, a component can die, and the operator can stop the daemon while
work is in flight. The design answers each with one rule: once a request has
entered service, its origin is retained until its worker and its disposition
are accounted for. The admission relay holds that account; the connection
registry holds the matching account for sockets, charging a slot from the
kernel's accept until every process and socket owner of that connection is
gone. A lost socket therefore never turns unfinished work into forgotten work,
and a freed slot never hides a live process.

<a id="concept-daemon-delivery"></a>
## Durable First, Transient Behind It

A connection writes two kinds of record. Durable events come from the session's
journal through one pump per attachment, which pulls the next event only when
the connection is ready for it, so a slow client never becomes an unbounded
queue and never delays a journal transaction. Transient progress — model text
as it streams — reaches the connection through core's per-session progress
sink and waits in a small bounded queue that is written only behind durable
output. Progress is never truth: it may be dropped under pressure, and a client
that reconnects recovers from the durable cursor, not from progress.

Every connection's output is bounded. A client that stops reading is detached
at its last completely written cursor rather than allowed to hold memory, and a
fixed part of each attached connection's allowance is reserved so the notice
that a session changed owner can always be delivered.

<a id="concept-daemon-lifecycle"></a>
## One Order In, the Reverse Order Out

A daemon lifetime acquires its resources in one order — the root's placement
lock, the credential plane, the Store and runtime, the session index, the
collaboration processes, the socket, the listener — and releases them in the
reverse order with the Store last. The command process is a sentinel that
survives every way the owner can end and turns the outcome into one exit
status, so an operator always learns exactly which class failed.

An orderly stop is a sequence of barriers: cut the transport, stop admitting
lease operations, let admitted work reach core, drain the sessions through
core, tell every client, then tear down. Each barrier has a fixed clock, so the
stop has a bound an operator can plan a service-manager timeout around.

<a id="concept-daemon-credential"></a>
## The Credential Is Read Once

The daemon reads the provider credential from its environment once, at the
entry to the command, into private custody, and removes it from its own
environment and from every child it starts. Each composition gets a fresh
capability to the custody rather than the value, and a second composition in
the same operating-system process refuses rather than finding the variable
again. See [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept).

<a id="concept-daemon-discovery"></a>
## Discovery Is Not Existence

`session.list` reads a daemon-owned, bounded index of the sessions the root
holds. The index is for finding sessions only: whether a session exists is
always asked of core, and adding or failing to add an index row never creates
or reverses a session. A root written by an earlier release has no index, and
the daemon refuses it until the operator runs the strict one-time import.

## Related

- [Operator guide to the daemon](../operator/daemon.md#concept).
- [Architecture](architecture.md#concept) — where the host role sits.
- [App server protocol](app-server-protocol.md#concept) — generation 1, which
  generation 2 extends.
- [ADR 0031](../adr/0031-daemon-grade-store-selection-and-migration.md#concept),
  [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept) and
  [ADR 0033](../adr/0033-collaboration-controller-lease-and-takeover.md#concept).
- [Developer documentation](README.md).
