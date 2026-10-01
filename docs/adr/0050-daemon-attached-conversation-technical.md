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

**Action mapping.** Every conversation action uses an existing member of the
delivered M7 daemon generation, under ADR 0033's controller checks:

| Conversation action | Daemon member | Authority |
| --- | --- | --- |
| Start a new conversation | `session.create`, then `session.acquire_control` and `session.attach` in either order | Create is uncontrolled; the first mutation needs the lease |
| Reach an existing conversation | `session.acquire_control` by ID, `session.resume` when dormant, `session.attach` | Lease and writer epoch; resume is the one mutation admitted without a live attachment |
| Prompt, steer, follow up | `session.prompt`, `session.steer`, `session.follow_up` with their closed `bounds` | Lease, matching writer epoch, live attachment |
| Answer or decline a question | `session.respond_interaction` | The same |
| Change model or reasoning between runs | `session.configure` | The same |
| Compact | `session.compact` with explicit bounds | The same |
| Abort the run | `session.abort` | The same |
| Status | `session.inspect` and the attachment snapshot's committed configuration record | Any attachment |
| Detach | `session.release_control`, then close | Holder only; a failed release leaves the lease to expire |

Before acceptance, check each row against the delivered generation's method,
record and error inventories. A row with no delivered member is a named
protocol addition with schemas, vectors and both Node clients updated in the
same change; it is not improvised in the command.

**Bounds and defaults.** The attached command sends authored bounds only where
the operator gave them. Omitted ordinary limits are captured by the service
from its own configuration at admission, as the daemon generation already
specifies for `session.prompt`. The client holds no copy of host defaults.

**Service configuration.** `loopex daemon --config FILE` runs ADR 0049's
reader and resolver once at startup, before the socket is created. Its
existing flags keep their meaning and take ADR 0049's precedence over file
values. The file supplies what a foreground chat's file supplies: providers and
references, roles, conversational and delegation limits, instructions,
summarizer, tools profile, policy profile and trace controls. Validation
failure refuses startup with the existing startup-refusal form. `session.create`
continues to reject remote input for provider capabilities, credential routes,
host catalogs, registry modules and derived tool bindings.

A daemon started without `--config` keeps M7's delivered behavior. Whether
that form remains supported in the installed layout, or the installed
lifecycle commands always supply the file, is ADR 0037's cell.

**Ordering and input.** The attached command keeps the foreground command's
ordered terminal and pipe input rules, explicit answers and declines, bounded
end-of-input handling and fail-fast pipe errors. It renders from committed
events and transient progress delivered by the attachment; it keeps no second
conversation state.

**Interrupt, detach and loss.**

| Event | Result |
| --- | --- |
| Interrupt while a run is active | `session.abort` for that run; the conversation continues |
| Interrupt or end of input while idle | Release control, close, exit |
| Explicit detach while a run is active | Release control, close, exit; the run continues |
| Terminal or client process lost | Nothing is sent; the lease expires on its term; the run continues |
| Service stops | `daemon.stopping` when delivered, otherwise the socket closes; the command exits nonzero and names reconnection |
| Slow reader | The existing bounded attachment rules apply; the command reattaches from its last cursor |

Exit status follows the foreground conversation's rule for the runs this
client admitted. A detach with a run still active exits zero and prints the
session identifier.

**Reconnect.** The command attaches with the snapshot-first cursor
transaction, deduplicates by session identifier, event sequence and event
identifier, and renders a pending question from the snapshot. On
`cursor_expired` it renders from the fresh snapshot. When another connection
holds an unexpired lease, the command observes and says who cannot be
displaced; it does not wait silently. Takeover uses ADR 0033's existing
`session.acquire_control` rules and is explicit.

**Open before acceptance.**

- The exact flag spelling and its interaction with ADR 0037's discovered
  socket.
- The method-mapping check above against the delivered generation.
- Whether observation-only attachment is offered on `chat` or left to the
  existing `attach --observe`.
- The startup report's workspace line and its source record.

<a id="technical-adr-0050-evidence"></a>
### Evidence

Concept: [Observable consequences](0050-daemon-attached-conversation.md#concept-adr-0050-consequences).

M8 must prove, against a real daemon process and socket:

- every action in the mapping on terminal and piped input, with the
  foreground command's ordered-input cases reused;
- refusal of each host and trace flag before a socket opens;
- detach during an active run, with run identity unchanged, no cancellation
  and the final result observed after reattach;
- a client killed mid-run, lease expiry, takeover from a second terminal and
  refusal of the stale writer epoch;
- a question pending across detach, service restart and reattach, answered
  once, and its expiry under ADR 0045's rule;
- two terminals on one session: one controller, one observer told it cannot
  mutate;
- `cursor_expired` and slow-reader recovery;
- service startup with a valid file, an invalid file and no file;
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
- *Implicit attachment whenever a service is running.* A command that changes
  which process owns the workspace, policy and credentials according to
  ambient state hides the most important fact about a session.
- *Client-supplied configuration.* Letting a client name roles, policy or
  provider bindings would move host authority across the socket, which ADR
  0032 and M7's `session.create` rules refuse.
- *A second conversation protocol for terminals.* The daemon generation
  already carries every action; a parallel surface would need its own vectors
  and would drift.
- *Network attachment.* The remote-ecosystem rung owns it, behind its own
  threat model.
