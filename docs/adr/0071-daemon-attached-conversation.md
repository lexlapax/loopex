<a id="concept"></a>
## Concept

Technical depth: [Attached conversation mapping, service configuration and evidence](0071-daemon-attached-conversation-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30; reconciled with the delivered M7 baseline on 2026-10-13; detailed for implementation on 2026-10-13; service-hosted helpers designed on 2026-10-13
- **Decision owner:** Maintainer
- **Supersedes:** nothing; it applies [ADR 0032](0032-daemon-attachment-residency-and-replay.md#concept) and [ADR 0033](0033-collaboration-controller-lease-and-takeover.md#concept) to the conversation command, extends the daemon's startup inputs with [ADR 0049](0049-explicit-host-configuration.md#concept)'s file, and applies [ADR 0046](0046-child-session-tool.md#concept), [ADR 0056](0056-host-helper-ledger-recipe.md#concept) and [ADR 0069](0069-helper-run-evidence-and-route-guard.md#concept) to the service. It narrowly amends ADR 0049's conversation status record so a service-owned value can be absent, ADR 0032's activation ceiling so it counts client activations and not helper children, and [ADR 0055](0055-remote-session-creation-options.md#concept)'s creation options on a helper-enabled service
- **Depends on:** [ADR 0049](0049-explicit-host-configuration.md#concept) and `loopex.experimental/4`, the daemon generation [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept) introduced, both delivered by M7; ADRs 0046, 0056 and 0069 as delivered by M7; [ADR 0037](0037-host-configuration-and-path-discovery.md#concept) for the home, the on-demand start and `daemon.readiness`
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
written and recorded here as decided. The maintainer also decided that the
service hosts helper roles in M8, so a configuration that works in the
foreground conversation works through the service; decision 10 records it.

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
   a missing credential reference, an unusable file and a trace that does not
   start are refused by name, each with its own exit status.
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
10. **The service hosts helper roles.** When the file enables delegation, the
    service runs read-only helper children exactly as the foreground
    conversation does under ADRs 0046, 0056 and 0069. Every session it creates
    is a helper parent with the file's saved roles frozen at the service's
    start. The parent's `task` tool starts one read-only child at a time
    within a per-run allowance kept in the service's private ledger; the child
    works in the service's workspace and cannot change it; and the result
    reports the child's usage, the run's delegation totals and the parent's
    own usage separately and combined. An attached conversation drives a
    helper parent like any other session. A helper child can be watched but
    never prompted, steered, configured, compacted, answered, aborted or
    resumed by any client; it stops only through its parent. When the service
    stops or fails while a helper runs, the next start recovers stop-only: the
    child is stopped and never prompted again, and the parent's call reports
    that it was interrupted, so the operator asks again. Until the next start
    has classified all retained helper history the service reports
    `classifying` and admits no session work.

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
most 64 sessions for its clients in its lifetime, so a service left running
eventually refuses a new or resumed conversation until it is restarted; the
refusal is shown as the service returns it. Helper children do not spend those
activations; each parent run's child count and token allowance bound them.

With helpers enabled, the attached conversation shows the parent's `task`
calls and their results as the foreground does: the role, model, child
session, outcome, bounded text and the separate and combined usage. The child
itself can be watched with `loopex attach --service CHILD --observe` while it
is active in this service lifetime. A second helper in the same parent while
one is active is refused before any work; independent parents may each run one
helper at the same time. A conversation started while the service is
classifying helper history is refused until the service serves.

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

Helper hosting adds no wire member, stored record or ledger format: the parent
binding, run ledger and receipts are ADR 0056's, written by the same
composition owner the foreground uses. A root whose helpers ran under the
service resumes under the foreground conversation and the reverse, because
both hosts classify and recover the same history. A service started with
delegation disabled still classifies and guards a root's helper history, as
M7 delivers. Core gains no command, record or public function; it gains one
undocumented detailed form of its existing exact-genesis creation call, so the
service accounts a helper parent's activation as it does any other session's.

Removing this capability removes a client and one startup input. No durable
session fact depends on which kind of terminal admitted a command.

## Open for the Maintainer

Decided on 2026-10-13: the service hosts helper roles in M8 (decision 10),
and the earlier refusal of a file that enables delegation is withdrawn.

- **Helper children and the activation ceiling.** The helper owner activates
  children inside the service's runtime, outside the daemon's admission relay,
  so ADR 0032's 64-activation lifetime ceiling does not count them, and Core
  has no deactivation. Each parent run is bounded by its `max_children` (at
  most 128) and token allowance, but a service left running accumulates idle
  child coordinators across many runs until it is restarted, as a long
  foreground conversation does today. The alternative is to count each child
  against the ceiling, which needs a permit from the daemon's registry inside
  the helper owner and a new refusal in ADR 0046's fixed order.
  Recommendation: do not count them in M8, state the cost in the operator
  runbook, and leave a bounded child lifetime to the successor that adds Core
  deactivation.
- **Daemon exit statuses across M8 records.** This record uses 111 to 115 and
  leaves 114 retired. ADR 0072 and ADR 0073 each also number their daemon
  statuses from 111. One order must be fixed when the three are accepted; this
  record proposes that ADR 0072's statuses follow 115 and ADR 0073's follow
  those.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
