<a id="concept"></a>
## Concept

Technical depth: [Attached conversation mapping, service configuration and evidence](0050-daemon-attached-conversation-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** nothing; it applies [ADR 0032](0032-daemon-attachment-residency-and-replay.md#concept) and [ADR 0033](0033-collaboration-controller-lease-and-takeover.md#concept) to the conversation command, and extends the daemon's startup inputs with [ADR 0049](0049-explicit-host-configuration.md#concept)'s file
- **Depends on:** [ADR 0049](0049-explicit-host-configuration.md#concept) and the daemon generation [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept) introduces, both conditional on the delivered M7 baseline; [ADR 0037](0037-host-configuration-and-path-discovery.md#concept) for the installed socket and file locations
- **Prerequisite for:** M8 outcomes 4 and 5

<a id="concept-adr-0050-decision"></a>
### Context and Decision

Technical depth: [Contract](0050-daemon-attached-conversation-technical.md#technical-adr-0050-decision).

M7's `loopex chat` owns one foreground durable runtime. The conversation ends
when its terminal does, and while it runs no daemon can hold the same root.
ADR 0049 names the missing piece as successor work: a conversational terminal
attached to the running service. An installed operator expects exactly that.
They start a task, close the laptop lid or the terminal, and come back to it.

M7 also leaves the daemon's startup grammar unchanged except for trace
controls, so a daemon started under M7 reads no configuration file. The daemon
protocol can already carry model changes, compaction and questions, but the
host that serves it has no file-supplied roles, limits, instructions or
summarizer.

**The decision.**

1. **The conversation can be a client of the service.** When the command asks
   for the service, `loopex chat` opens no runtime. It connects to the daemon's
   socket, creates or reaches a session, acquires control, attaches and holds
   the same line-oriented conversation as the foreground command: prompt,
   watch, steer, follow up, answer or decline a question, configure, compact,
   abort, status and wait.
2. **The service is the host.** It alone chooses workspace, state root, policy,
   provider bindings, credentials, instructions, roles, limits and tracing,
   when it starts. A connected conversation names none of them and is refused
   if it tries. It may ask only for the per-session changes the daemon protocol
   already admits, within what the service's configuration allows.
3. **The service reads the configuration file at startup.** `loopex daemon`
   accepts the same explicitly selected file as chat, validated by the same
   reader, and uses it for every session it creates. Its existing startup
   flags keep their meaning. How those flags, the daemon's existing
   environment inputs and its legacy single credential combine with the file
   is fixed before acceptance, and a conflict is refused rather than resolved
   silently. A session keeps its committed settings; a changed file affects
   new sessions after a restart. There is no reload.
4. **Leaving the terminal never aborts.** This differs from the foreground
   conversation, where quitting, end of input and interrupt abort active work
   because the runtime dies with the terminal. Attached, all three detach: the
   command releases control and exits, and the session and any active run
   continue in the service. This is what every existing daemon command already
   does on a signal. Only the explicit abort action ends a run. A client that
   is killed sends nothing, and its lease expires under ADR 0033.
5. **Reconnecting restores the conversation.** Attaching to an existing
   session shows its committed state, replays what was missed without gaps,
   and presents a question that is still pending. Control is acquired, or
   taken from a holder whose lease has lapsed, under ADR 0033's existing rules.
6. **A conversation needs control.** When another connection holds an
   unexpired lease, the attached conversation is refused and told to watch
   with the existing `attach --observe` command. The conversation command
   offers no observer mode of its own.
7. **Attachment is asked for, never implied.** The foreground conversation
   remains and keeps its grammar. It refuses a root a service holds, as every
   offline command does today. A home's existence does not switch a command to
   the service.
8. **One workspace per service.** An attached conversation works in the
   workspace the service was started with, not the terminal's current
   directory. A second workspace is a second service on a second root.

The alternatives considered are in the companion. The main one, a daemon that
chat starts privately and owns, was rejected because it creates a second
session lifetime owner and makes two terminals on one root impossible.

<a id="concept-adr-0050-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0050-daemon-attached-conversation-technical.md#technical-adr-0050-evidence).

An operator can start a long task, detach, and reconnect from another terminal
to the same run with nothing lost and nothing run twice. A pending question
waits for whichever terminal next holds control, until it expires under M7's
rule.

A detach exits successfully whether or not a run is active, and prints the
session identifier to reconnect with. A script that needs a run's result waits
for it before its input ends. A piped script whose line is refused stops,
detaches and exits with a failure status. If the service stops, the
conversation exits with a failure status and says how to reconnect.

The attached conversation reports the session's committed values at startup on
standard error, best-effort. Its status action shows the committed
configuration the service projects to clients. That is narrower than the
foreground status: host policy and trace state belong to the service and are
not shown to a client.

Starting a conversation in a directory other than the service's workspace is
not an error and changes nothing. Showing the service's workspace to the
client is intended, and no delivered daemon record carries it today; it is the
one known candidate for a protocol addition.

The service's existing residency limits are unchanged. In particular a daemon
activates at most 64 sessions in its lifetime, so a service left running
eventually refuses a new or resumed conversation until it is restarted.

Host and trace flags are refused before any connection is opened, with a
message naming the service as their owner.

<a id="concept-adr-0050-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0050-daemon-attached-conversation-technical.md#technical-adr-0050-compatibility).

The foreground conversation keeps its grammar and exit semantics. `run`,
`resume`, `attach` and `sessions` keep theirs against a running service;
whether any of them starts a service on demand is ADR 0037's decision. A
daemon started without a file behaves as M7 delivers it. Core gains no command
and no record.

The conversation's actions use members of the delivered M7 daemon generation.
Three places may need a named, versioned addition with vectors, settled in the
companion before acceptance: a workspace identity for the client, the source
of compaction bounds, and the readiness record ADR 0037 reports. Nothing is
added by improvisation in the command.

Removing this capability removes a client and one startup input. No durable
session fact depends on which kind of terminal admitted a command.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
