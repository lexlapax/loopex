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

M7 also leaves the daemon's startup grammar unchanged, so a daemon started
under M7 reads no configuration file. The daemon protocol can already carry
model changes, compaction and questions, but the host that serves it has no
file-supplied roles, limits, instructions or summarizer.

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
   flags override file values under ADR 0049's precedence. A session keeps its
   committed settings; a changed file affects new sessions after a restart.
   There is no reload.
4. **Detaching is not aborting.** An explicit detach, end of input at an idle
   prompt, or the loss of the terminal leaves the session and any active run
   as they are. Interrupt while a run is active aborts that run, as it does in
   the foreground conversation. A client that vanishes without releasing
   control leaves its lease to expire under ADR 0033.
5. **Reconnecting restores the conversation.** Attaching to an existing
   session shows its committed state, replays what was missed without gaps,
   and presents a question that is still pending. Control is acquired, or
   taken over from an expired holder, under ADR 0033's existing rules.
6. **Attachment is asked for, never implied.** The foreground conversation
   remains and keeps its grammar. It refuses a root a service holds, as every
   offline command does today. A home's existence does not switch a command to
   the service.
7. **One workspace per service.** An attached conversation works in the
   workspace the service was started with, not the terminal's current
   directory. A second workspace is a second service on a second root.

The alternatives considered are in the companion. The main one, a daemon that
chat starts privately and owns, was rejected because it creates a second
session lifetime owner and makes two terminals on one root impossible.

<a id="concept-adr-0050-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0050-daemon-attached-conversation-technical.md#technical-adr-0050-evidence).

An operator can start a long task, detach, and reconnect from another terminal
to the same run with nothing lost and nothing run twice. Two terminals can
watch one session; only the one holding control can change it, and the other
is told so. A pending question waits for whichever terminal next holds
control, until it expires under M7's rule.

The attached conversation reports the session's committed values at startup on
standard error, best-effort, as the foreground conversation does. Its status
action shows the same closed record. Host and trace flags are refused before
any connection is opened, with a message naming the service as their owner.

A detach while a run is active exits successfully and prints the session
identifier to reconnect with. If the service stops, the conversation exits
with a failure status and says how to reconnect.

Starting a conversation in a directory other than the service's workspace is
not an error and changes nothing; the startup report states the workspace in
use so the difference is visible.

<a id="concept-adr-0050-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0050-daemon-attached-conversation-technical.md#technical-adr-0050-compatibility).

The foreground conversation, `run`, `resume`, `attach` and `sessions` keep
their grammar and exit semantics. The daemon's existing startup flags remain,
and a daemon started without a file behaves as M7 delivers it. Core gains no
command and no record. Any daemon protocol member the attached conversation
needs beyond the delivered M7 generation is named in the companion before
acceptance and versioned with vectors; none is proposed today.

Removing this capability removes a client and one startup input. No durable
session fact depends on which kind of terminal admitted a command.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
