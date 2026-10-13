<a id="concept"></a>
## Concept

Technical depth: [Attached conversation mapping, service configuration and evidence](0071-daemon-attached-conversation-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30; reconciled with the delivered M7 baseline on 2026-10-13; detailed for implementation on 2026-10-13
- **Decision owner:** Maintainer
- **Supersedes:** nothing; it applies [ADR 0032](0032-daemon-attachment-residency-and-replay.md#concept) and [ADR 0033](0033-collaboration-controller-lease-and-takeover.md#concept) to the conversation command, extends the daemon's startup inputs with [ADR 0049](0049-explicit-host-configuration.md#concept)'s file, and narrowly amends ADR 0049's conversation status record so a service-owned value can be absent
- **Depends on:** [ADR 0049](0049-explicit-host-configuration.md#concept) and `loopex.experimental/4`, the daemon generation [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept) introduced, both delivered by M7; [ADR 0037](0037-host-configuration-and-path-discovery.md#concept) for the home, the on-demand start and `daemon.readiness`
- **Prerequisite for:** M8 outcomes 4 and 5

<a id="concept-adr-0071-decision"></a>
### Context and Decision

Technical depth: [Contract](0071-daemon-attached-conversation-technical.md#technical-adr-0071-decision).

M7's `loopex chat` owns one foreground durable runtime. The conversation ends
when its terminal does, and while it runs no daemon can hold the same root.
ADR 0049 names the missing piece as successor work: a conversational terminal
attached to the running service. An installed operator expects exactly that.
They start a task, close the laptop lid or the terminal, and come back to it.

M7 left the daemon's startup grammar as six flags with environment fallbacks
and one credential from `LOOPEX_PROVIDER_API_KEY`. The daemon reads no
configuration file and has no trace controls. Its `loopex.experimental/4`
protocol already carries control, model changes, compaction and questions,
and its clients already detach and reattach at a cursor without cancelling the
run, as M7's `m7.daemon-detach` case proved.

The maintainer's 2026-10-13 decisions bind this record: proposals P1, P5, P7
and P8 of the [M8 plan](../plans/M8.md#concept-plan-decisions) are accepted as
written and recorded here as decided.

**The decision.**

1. **The conversation is a client of the service.** `loopex chat --service`
   attaches to the selected home's service, starting it on demand under ADR
   0037; `loopex chat --daemon SOCKET` attaches to a named socket and starts
   nothing. Either form opens no runtime. It creates or reaches a session,
   acquires control, attaches and holds the same line-oriented conversation as
   the foreground command: prompt, watch, steer, follow up, answer or decline a
   question, configure, compact, abort, status and wait, writing the same
   control records.
2. **The service is the host.** It alone chooses workspace, state root,
   policy, provider bindings, credentials, instructions, roles, limits and
   tracing, when it starts. A connected conversation names none of them and is
   refused before any connection if it tries. It may choose only a new
   session's model, reasoning and token limits, and each prompt's run bounds,
   which the daemon protocol already admits from a client.
3. **The service reads the configuration file at startup.** `loopex daemon
   --config FILE` uses ADR 0049's reader and resolver once, before it takes
   any lock, and applies the result to every session it creates. Its
   `--state-root`, `--workspace`, `--policy` and `--cleanup-grace-ms` flags
   keep their names and precede the file, as ADR 0049's flags do. Its other
   environment inputs are not read under a file, `LOOPEX_PROVIDER_API_KEY` is
   discarded unread exactly as the foreground conversation discards it, and
   the provider launch comes from the build. `--provider-launch` with a file,
   a missing credential reference, an unusable file, a trace that does not
   start and a file that enables helper delegation are refused by name, each
   with its own exit status.
   A session keeps its committed settings; a changed file affects new sessions
   after a restart. There is no reload.
4. **Leaving the terminal never aborts.** Attached, quitting, end of input
   and interrupt all detach: the command releases control and exits
   successfully, and the session and any active run continue in the service.
   Only the explicit abort action ends a run. A client that is killed sends
   nothing, and its lease expires under ADR 0033.
5. **Reconnecting restores the conversation.** Reaching an existing session
   replays its committed transcript, shows its committed state and presents a
   question that is still pending. A connection lost while the command runs is
   repaired at its cursor without repeating or skipping anything.
6. **A conversation needs control.** When another connection holds an
   unexpired lease, the attached conversation is refused at once and told to
   watch with `attach --observe`. A lease ends at most 30 seconds after its
   holder stops renewing. The conversation command has no observer mode.
7. **Attachment is asked for, never implied.** Without `--service` or
   `--daemon` the foreground conversation runs as it does today and refuses a
   root a service holds.
8. **One workspace per service.** An attached conversation works in the
   workspace the service was started with, which its startup report shows from
   `daemon.readiness`; the terminal's current directory is irrelevant.
9. **Compaction uses the foreground's fixed bounds.** The attached `/compact`
   sends the same four attempts, 60 seconds and 32,768 tokens the foreground
   command shows, so no protocol default is added.

The alternatives considered are in the companion. The main one, a daemon that
chat starts privately and owns, was rejected because it creates a second
session lifetime owner and makes two terminals on one root impossible.

<a id="concept-adr-0071-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0071-daemon-attached-conversation-technical.md#technical-adr-0071-evidence).

An operator can start a long task, detach, and reconnect from another terminal
to the same run with nothing lost and nothing run twice. A pending question
waits for whichever terminal next holds control, until it expires under M7's
rule.

A detach exits `0` whether or not a run is active and prints the command that
reconnects. A script that needs a run's result uses `/wait` before its input
ends. A piped script whose line is refused stops, detaches and exits `1`. If
the service stops or the connection cannot be repaired within 35 seconds, the
conversation exits `1` and says how to reconnect. A run this terminal started
that ends other than completed also makes the exit `1`.

The attached conversation reports the session's committed values and the
service's workspace at startup on standard error. Its status action shows the
committed configuration the service projects; host policy and trace state
belong to the service and are shown as absent.

The service's existing residency limits are unchanged. A daemon activates at
most 64 sessions in its lifetime, so a service left running eventually refuses
a new or resumed conversation until it is restarted; the refusal is shown as
the service returns it.

<a id="concept-adr-0071-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0071-daemon-attached-conversation-technical.md#technical-adr-0071-compatibility).

The foreground conversation keeps its grammar and exit semantics. `run`,
`resume`, `attach` and `sessions` keep theirs against a running service, with
ADR 0037's `--service`. A daemon started without a file behaves as M7
delivers it. Core gains no command and no record.

Every conversation action uses a delivered member of `loopex.experimental/4`.
The one protocol addition M8 makes is ADR 0037's `daemon.readiness`, which
also carries the workspace this record shows. The conversation status record
gains nullable host-owned members, a narrow amendment of ADR 0049.

Removing this capability removes a client and one startup input. No durable
session fact depends on which kind of terminal admitted a command.

## Open for the Maintainer

- **Helper roles under the service.** The delivered daemon serves no helper
  sessions. This record refuses to start a service whose file enables
  delegation, naming the member, so a foreground-only setting is never
  silently dropped. The alternative is to extend the daemon to create helper
  parents in M8, which P1's "M7's conversation" could be read to require.
  Recommendation: refuse in M8 and schedule helper serving as its own decision.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
