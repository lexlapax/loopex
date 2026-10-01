<a id="technical-depth"></a>
## Technical depth

Concept: [Daemon-attached conversation](0050-daemon-attached-conversation.md#concept).

<a id="technical-adr-0050-decision"></a>
### Contract

Concept: [Context and decision](0050-daemon-attached-conversation.md#concept-adr-0050-decision).

**Selection.** The attached form is requested by naming the service's socket,
as `run`, `resume`, `attach` and `sessions` already do with `--daemon SOCKET`.
The installed host may supply the home's socket path under ADR 0037; the
request to attach stays explicit either way. The exact spelling is fixed
against the delivered M7 parser before acceptance.

```text
loopex chat --daemon SOCKET [--resume SESSION_ID] [session overrides]
loopex daemon --config FILE [existing daemon flags]
```

**Refused on the attached form, before any socket is opened:** `--config`,
`--workspace`, `--state-root`, `--policy`, `--tools`, `--skill-dir`,
`--system-prompt-file`, `--append-system-prompt-file`, `--cleanup-grace-ms`,
`--no-helpers` and every trace flag. These are host values. The message names
the service as their owner. Session overrides are limited to the members the
daemon generation's `session.create` options and `session.configure` update
already accept from a remote client.

**Action mapping.** Each conversation action uses a member of the delivered
M7 daemon generation, under ADR 0033's controller checks:

| Conversation action | Daemon member | Authority |
| --- | --- | --- |
| Start a new conversation | `session.create`, then `session.acquire_control` and `session.attach` in either order | Create is uncontrolled; the first mutation needs the lease |
| Reach an existing conversation | `session.acquire_control` by ID, `session.resume` when dormant, `session.attach` | Lease and writer epoch; resume is the one mutation admitted without a live attachment |
| Prompt, follow up | `session.prompt` and `session.follow_up` with their closed `bounds` | Lease, matching writer epoch, live attachment |
| Steer | `session.steer`; it carries no bounds | The same |
| Answer or decline a question | `session.respond_interaction` | The same |
| Change model or reasoning between runs | `session.configure` | The same |
| Compact | `session.compact`, whose bounds are required | The same |
| Abort the run | `session.abort` | The same |
| Status | `session.inspect` and the attachment snapshot's committed configuration record | No lease |
| Detach | `session.release_control`, then close | Holder only; a failed release leaves the lease to expire |

Before acceptance, check each row against the delivered generation's method,
record and error inventories, including the authority `session.inspect`
requires. A row with no delivered member is a named protocol addition with
schemas, vectors and both Node clients updated in the same change.

**Bounds and defaults.** The attached command sends authored bounds only where
the operator gave them. Omitted ordinary prompt limits are captured by the
service from its own configuration at admission, as the daemon generation
already specifies for `session.prompt`. The client holds no copy of host
defaults. `session.compact` requires explicit `max_attempts`, `deadline_ms`
and `token_budget`, and the foreground `/compact` action takes none from the
operator, so their source in the attached form is open: either the member
gains service-side defaults, or the action accepts authored bounds.

**Status.** The attached status action shows the committed configuration
record the daemon projects: configuration version, model and reasoning,
effective reply, context and system limits, instruction version and digest,
configured and active summarizer where projected, and the pending
interaction. It omits the foreground status's host policy and trace state.

**Service configuration.** `loopex daemon --config FILE` runs ADR 0049's
reader and resolver once at startup, before the socket is created. The file
supplies what a foreground chat's file supplies: providers and references,
roles, conversational and delegation limits, instructions, summarizer, tools
profile, policy profile and trace controls. Validation failure refuses startup
with the existing startup-refusal form. `session.create` continues to reject
remote input for provider capabilities, credential routes, host catalogs,
registry modules and derived tool bindings.

The daemon today gives each input one source: a flag, else its environment
variable (`LOOPEX_HOME`, `LOOPEX_WORKSPACE`, `LOOPEX_PROVIDER_LAUNCH`,
`LOOPEX_POLICY`), with one credential from `LOOPEX_PROVIDER_API_KEY`. ADR 0049
admits `LOOPEX_HOME` as the only configuration environment alias, its file has
no provider-launch member, and ADR 0048 makes startup reject a legacy
credential together with provider bindings. Before acceptance this record
fixes, for a daemon given `--config`: which existing flags remain and their
precedence over file members; whether the three other environment inputs are
honored, refused or ignored; where the provider launch path comes from; and
that the legacy credential is refused when the file declares bindings. Each
conflict has a named refusal.

A daemon started without `--config` keeps M7's delivered behavior. Whether
that form remains supported in the installed layout, or the installed
lifecycle commands always supply the file, is ADR 0037's cell.

**Ordering and input.** The attached command keeps the foreground command's
ordered terminal and pipe input rules, explicit answers and declines and
fail-fast pipe errors. It does not keep the foreground end-of-input rule. It
renders from committed events and transient progress delivered by the
attachment; it keeps no second conversation state.

**Leaving and loss.**

| Event | Result |
| --- | --- |
| `/abort` | `session.abort` for the active run; the conversation continues |
| `/quit`, end of input, `SIGINT`, `SIGTERM`, `SIGHUP`, `SIGQUIT`, idle or active | Stop reading, release control waiting at most the existing five seconds, print the detach line and the session identifier, exit `0`; the run continues |
| `SIGKILL` or host loss | Nothing is sent; the lease lapses at the end of its term; the run continues |
| Service stops | `daemon.stopping` when delivered, otherwise the socket closes; exit nonzero and name reconnection |
| Slow reader | The existing bounded attachment rules apply; the command reattaches from its last cursor |
| Pipe syntax or state refusal | Stop further input, detach, exit nonzero |

Exit status follows the foreground conversation's rule with one exception: a
detach is not a failure, so an admitted run that is still active at detach
does not make the exit nonzero. A run this client admitted and saw fail,
cancel, reach a bound or settle unknown does. A script that needs a result
uses `/wait` before its input ends.

**Reconnect and contention.** The command attaches with the snapshot-first
cursor transaction, deduplicates by session identifier, event sequence and
event identifier, and renders a pending question from the snapshot. On
`cursor_expired` it renders from the fresh snapshot. When acquisition is
refused because another connection holds an unexpired lease, the command
exits nonzero, says the holder cannot be displaced until its lease lapses,
and names `attach --observe`. The refusal carries no holder identity, so none
is shown. A lapsed lease is acquired under ADR 0033's existing rules.

**Retained limits.** ADR 0032's residency ceilings apply unchanged, including
64 activations per daemon lifetime; `session.create` and a resume each spend
one. The refusal is shown as the service returns it.

**Open before acceptance.**

- The exact flag spelling and its interaction with ADR 0037's discovered
  socket.
- The method-mapping check above against the delivered generation.
- The daemon's flag, environment and legacy-credential rules under `--config`.
- The source of `session.compact` bounds.
- Whether the client is shown the service's workspace, and the record that
  carries it.

<a id="technical-adr-0050-evidence"></a>
### Evidence

Concept: [Observable consequences](0050-daemon-attached-conversation.md#concept-adr-0050-consequences).

M8 must prove, against a real daemon process and socket:

- every action in the mapping on terminal and piped input, with the
  foreground command's ordered-input cases reused;
- refusal of each host and trace flag before a socket opens;
- `/quit`, end of input and each signal during an active run: control
  released, exit `0`, run identity unchanged, no cancellation, and the final
  result observed after reattach;
- `/abort` ending the run while the conversation continues;
- a client killed mid-run, lease expiry, acquisition from a second terminal
  and refusal of the stale writer epoch;
- a question pending across detach, service restart and reattach, answered
  once, and its expiry under ADR 0045's rule;
- a second conversation refused while the first holds control, and
  `attach --observe` watching the same session;
- `cursor_expired` and slow-reader recovery;
- service startup with a valid file, an invalid file, no file, and each named
  flag, environment and legacy-credential conflict;
- the activation-ceiling refusal shown to the operator;
- the foreground conversation's refusal of a root the service holds;
- an attended reconnect in the installed demonstration.

No fake transport replaces the socket in these cases. Controller and replay
conformance suites run unchanged.

<a id="technical-adr-0050-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0050-daemon-attached-conversation.md#concept-adr-0050-compatibility).

The command is one more peer over the daemon generation. It adds no core
command, record or facade function, and the session coordinator remains the
sole writer. The lease stays in daemon memory under ADR 0033.

**Alternatives rejected.**

- *A daemon the conversation starts and owns privately.* It makes the terminal
  the owner of session lifetime again and excludes a second terminal.
- *Abort on interrupt, as the foreground conversation does.* The foreground
  rule exists because its runtime dies with the terminal. Attached, it would
  make the most common way of leaving a terminal destroy the work the service
  exists to keep, and would differ from every existing daemon command.
- *Implicit attachment whenever a service is running.* A command that changes
  which process owns the workspace, policy and credentials according to
  ambient state hides the most important fact about a session.
- *Client-supplied configuration.* Letting a client name roles, policy or
  provider bindings would move host authority across the socket, which ADR
  0032 and M7's `session.create` rules refuse.
- *An observer mode on the conversation command.* `attach --observe` already
  exists; a second spelling adds grammar and no capability.
- *A second conversation protocol for terminals.* The daemon generation
  already carries the actions; a parallel surface would need its own vectors
  and would drift.
- *Network attachment.* The remote-ecosystem rung owns it, behind its own
  threat model.
