<a id="technical-depth"></a>
## Technical depth

Concept: [Explicit host configuration and conversation command](0049-explicit-host-configuration.md#concept).

<a id="technical-adr-0049-decision"></a>
### Contract

Concept: [Context and decision](0049-explicit-host-configuration.md#concept-adr-0049-decision).

**File contract.** UTF-8 JSON object, at most 256 KiB, schema version 1, closed
at every level. Reject duplicate keys, unknown members, invalid UTF-8, nulls,
unsupported versions and wrong types with a stable error class and JSON pointer,
never the offending value. Bounded identifiers are ASCII strings, never newly
created atoms. Paths are at most 4,096 bytes, resolved relative to the config
file's directory; CLI-relative paths resolve against invocation cwd. No tilde
or environment substitution. Read prompt files once as regular bounded UTF-8
files, retaining their exact bytes and digest; config selection is an explicit
host trust decision and is never inferred from a project file's name.

| Member | Closed content and default |
| --- | --- |
| `schema_version` | Required integer `1` |
| `paths` | Optional `workspace`, `state_root`; absolute after resolution |
| `providers` | Required map of 1–16 supported provider names to a credential binding under ADR 0048; durable chat requires `{"credential":{"env":"NAME"}}`, while existing credential-free ephemeral composition remains valid |
| `policy` | Required existing reference-host policy profile name, validated against its closed registry; no permissive default |
| `session` | Required `model` as exact `provider:model`, required `bounds`; optional `reasoning`, `max_tokens`, `context_token_budget`, `system_class_tokens`, `instructions`, `tools`, `skill_dirs`, `cleanup_grace_ms` |
| `session.bounds` | Required positive integers `max_turns`, `deadline_ms`, `token_budget`, even when flags override |
| `session.instructions` | Optional `system_file`, `append_file`; ADR 0042 section limits apply; missing means reference default/empty appendix |
| `session.reasoning` | `default` if absent; otherwise ADR 0044's closed levels |
| `session.max_tokens` | Positive integer, default 4,096 |
| `session.context_token_budget` | Positive integer or ADR 0041's calculation; never overrides the 65,536-byte record limit |
| `session.system_class_tokens` | Positive integer no greater than context budget, default 1,000 |
| `session.tools` | `coding`, `read-only`, `none`; default `coding`, same meanings as `ask`; policy still required |
| `session.skill_dirs` | Optional array, at most 16 bounded directory paths; default empty; admission unchanged |
| `session.cleanup_grace_ms` | Existing runtime bound/default, unchanged |
| `maintenance` | Optional closed `{model: "provider:model"}` with required exact model when present; absent means unconfigured, never inherit `session.model`. ADR 0043 fixes the thinking-off setting and maintenance bounds |
| `roles` | Optional map of at most 16 bounded role names to required `model`, `instructions_file` and optional `reasoning` defaulting to `default` |
| `delegation` | Optional `enabled` default false, `roles` list default empty; when enabled require nonempty enabled-role list, `max_children` from 1 to 128, positive `token_budget`, `child_bounds`; optional `max_tokens` default 4,096, `context_token_budget` derived from each child model under ADR 0041, `system_class_tokens` default 1,000 |
| `delegation.child_bounds` | Required positive `max_turns`, `deadline_ms` at most 600,000 under the fixed task generation, and `token_budget`; no implicit spending defaults |
| `trace` | Optional `enabled` default false, `level` default `calls`, `modules`, `max_entry_bytes`, `max_entries_per_second`, `max_queue_entries` |
| `output` | `text` only for chat; no new JSON conversation format in M7 |

Tool profiles select the existing base coding/read-only/empty set. Chat adds
`loopex.ask` to nonempty profiles, and adds `loopex.task` only with enabled
complete delegation configuration. `none` disables both; `none` with enabled
delegation refuses. The complete resulting set is frozen and measured under
ADR 0042, including all host tool definitions. Existing `ask --tools none`
keeps its empty-set meaning and gains no question/helper activation.

Role names match `[a-z][a-z0-9_-]{0,63}`. Each enabled role requires an exact
model and an admitted provider. There is no model inheritance or automatic
routing. Role instructions become the child's base, with host environment
facts and empty appendix; ADR 0042 bounds apply. Roles expose no credentials,
policy, tools, paths or limit overrides. One fixed task definition accepts a bounded role string. Frozen host instruction
facts name enabled roles and the catalog digest; dispatch checks membership
against ADR 0046's retained parent binding. Child budgets are validated
independently against each selected model; no parent-model inheritance is implied.

**Precedence.** Validate authored file values first. Then apply explicit CLI
value > `LOOPEX_HOME` for state root only > selected file > documented harmless
default. No other configuration environment aliases are introduced. Credential
variables are references resolved later, not setting overrides. Require workspace,
state root, policy, providers and conversational bounds before starting. Report
each effective value with `flag`, `env`, `file#pointer`, `default` or `committed`
origin; provider entries show configured provider identity and reference-form
validity only, with no claim of credential availability,
with environment-reference names redacted. Never resolve credentials for
inspection. Mutually exclusive duplicate
flags refuse; repeated skill directories/modules replace their file arrays.

**Command grammar, proposed until implemented.**

```text
loopex config validate --config FILE
loopex config show --config FILE --effective
loopex chat --config FILE [--workspace DIR] [--state-root DIR] [--resume SESSION_ID]
```

The chat overrides are `--model`, `--reasoning`, `--compaction-model`, `--max-steps`, `--deadline-ms`,
`--token-budget`, `--max-tokens`, `--context-token-budget`,
`--system-class-tokens`, `--cleanup-grace-ms`, `--system-prompt-file`,
`--append-system-prompt-file`, `--tools`, repeatable `--skill-dir`, `--policy`,
`--output text`, `--no-helpers` and the trace flags below. Provider selection
is part of exact `--model provider:model`; there is no redundant `--provider`.
Saved roles and allowance declarations are authored in the file, not flags.
Inspection commands accept the same overrides to show exactly what chat would
use. `--no-helpers` may narrow a new session's file configuration; it cannot
change an existing session's committed tool generation on resume.

On resume, file defaults do not reconfigure. Use committed model, reasoning,
instructions, max_tokens, context_token_budget, system_class_tokens, tools,
resources and role catalog. Explicit conflicting flags
for those fields refuse and direct the operator to `/configure` for mutable
settings; immutable tool/catalog changes require a new session. Only
max_turns, deadline_ms and token_budget for a new run come from validated
invocation configuration; in-flight bounds stay committed. A conflicting
`chat --resume S --max-tokens 8000` therefore refuses before dispatch and
directs the operator to settled `/configure`; it is not a run-bound override.
Require matching workspace/policy identity and available routes for admitted
work. Trace/output are host-local options, not durable session configuration.
`--compaction-model` overrides the file's `maintenance.model` for new episodes,
including on resume; it cannot redirect an admitted episode. Show configured
selection or `unconfigured`, its origin and any distinct active episode model
in effective/status output without resolving credentials. No flag invents a
default model or adds a provider binding. Composition validates the selected
model's admitted route and verified thinking-off mapping before startup.

Runtime-owning reference hosts inject the shared versioned maintenance block
through ADR 0043's `maintenance_instructions` composition option. Keep that
host code path common to chat and the existing reference entrypoints; add no
instruction config-file member, prompt-file override or trace-related fallback. Embedded
callers supply their own explicit block. Resume keeps an admitted episode's
captured block even if the host has changed; new episodes use the current block.
The separately selected `maintenance.model` / `--compaction-model` supplies
composition's exact-string `maintenance_model` option. Composition resolves it
to ADR 0043's closed plain runtime map. Other existing reference CLI commands
gain no new model flag/file loader; embedding hosts may pass the equivalent
explicit option. Missing model/instructions leave ordinary work valid but
refuse new compaction; invalid supplied configuration refuses startup. All
long-conversation examples and fixtures declare the summarizer explicitly.

| Input | Behaviour |
| --- | --- |
| Plain nonempty line while settled | Submit prompt with a fresh idempotency identity |
| Plain line during active work | Refuse locally with instructions to use an explicit action |
| `/steer TEXT`, `/follow-up TEXT` | Existing admission and disposition rules |
| `/answer ID --text JSON_STRING`, `/answer ID --choice CHOICE_ID`, `/decline ID` | Bound response to the pending interaction identity; duplicate/late replies follow ADR 0045 |
| `/compact` | Bounded settled compaction under ADR 0043; active use refuses |
| `/configure JSON` | Closed mutable fields from ADR 0044, with optional ADR 0042 instruction envelope; atomic settled update; raw credential/file/role fields refuse |
| `/abort` | Existing run abort and bounded cleanup |
| `/status` | Committed model/bounds, configured/active summarizer, pending interaction and host trace/usage status |
| `/wait` | Pause input until prior admitted work settles, needs an answer or reports recovery/cleanup uncertainty; report exact identities before reading the next line |
| `/quit`, EOF | Abort foreground active work, wait bounded cleanup, stop trace/runtime, print truthful outcome and exit |
| Ctrl-C | Same cancellation path; second interrupt ends waiting with cleanup explicitly unknown |
| `//TEXT` | Literal prompt beginning `/TEXT` while settled |

**Interactive and pipe framing.** Both consume UTF-8 newline-delimited input,
with interactive mode selected only when stdin is a TTY. Redirecting stdout
alone does not change input grammar or refusal semantics. Pipes select the
control records below, even when stdout is a terminal. Both modes
ignore empty lines and execute no input as shell syntax. Accept LF or CRLF;
strip only that terminator, and count the line cap before it. A bare CR is
invalid. Text answers require a JSON string after `--text`; decode once and
preserve its whitespace exactly, including literal `--choice` text. Reject NUL, invalid
UTF-8 and lines over 65,536 bytes before admission. An unterminated final pipe
fragment is malformed, never an implicit prompt. Existing prompt/steer/follow-up
limits still apply after framing. Process lines in order with an invocation-local
input sequence and fresh command ID. `/wait` stops reading input until all prior
admitted work settles, needs an answer or becomes uncertain. It does not extend
a deadline, answer a question or retry a command. A static sequence uses prompt,
`/wait`, prompt, `/wait`, then `/quit`. Question-capable producers read the actual
question ID through bidirectional pipes, answer that ID, then `/wait`; there is
no positional or future-question answer alias.

Pipe stdout carries transient host control lines prefixed `@loopex ` with
compact UTF-8 JSON, using ADR 0042's JSON encoding and existing protocol string
encodings for IDs. Each object has `v:1`, an `event` and exactly its branch:

| Event | Required fields; other members refuse |
| --- | --- |
| `input` | `input_sequence`, `command_id`, `disposition` from admitted/refused, `code` as the stable command disposition/error code |
| `question` | `session_id`, `run_id`, `interaction_id`, `producer`, `kind`, `question`, `choices` array, `expires_at_ms`; choices empty for text |
| `wait` | `input_sequence`, `state` from settled/question/uncertain, `session_id`, `run_id` or null, `interaction_id` or null, `outcome` or null; question requires interaction ID, uncertain requires its public uncertainty outcome |
| `status` | `input_sequence`, `session_id`, `run_id` or null, `state`, `configuration_version`, `model`, `reasoning`, `bounds`, `interaction_id` or null, `trace`, `maintenance`; no credential reference, role prompt or private continuation |
| `closing` | `exit_code`, `cleanup` from confirmed/unknown, `last_outcome` or null |
| `error` | `input_sequence` or null, `code` as a stable host error code |

Question content uses ADR 0045; policy-defer questions retain ADR 0024's bounds.
Each choice is exactly `{id, label}` using its producer's public choice grammar.
`outcome` and `last_outcome` use the public outcome object, including
the existing bound/uncertainty fields; they are never free-form diagnostic text.
Status state and bounds use the public session contract. Status trace is
exactly `{enabled, emitted, dropped}` with a Boolean and nonnegative counters;
disabled uses false and zero counts. `/status` and `/wait` receive their own
ordered `input` acknowledgement before their result record. Status `maintenance`
is exactly `{configured_model, active_model}`: each is an exact model string or
null. Null configured model means new episodes are unconfigured; null active
model means there is no admitted episode. A resumed episode may show a different
active model from the current configured selection. This host status view grants
no session mutation or provider authority. TTY rendering
shows the same identities, labeled choices, expiry and command syntax in human
readable form, without suggesting a default answer.
Publish an input admission record before question/wait output caused by that
input. Barriers report all earlier admitted work settled, the current question,
or uncertainty; a transient idle boundary before queued follow-up promotion
is not settled. Hosts use bounded generated identities for new work; maximum
encoded records, including legacy-resumed questions and choices, must be proved
by vectors before integration. The cap is 65,536 bytes. If an existing public
record cannot be represented, report `control_record_too_large` and perform
transport-failure cleanup, never truncate an ID or question. This is an explicit
presentation limit, not a new public identifier limit.

Frame content at LF boundaries and prefix every model/tool line with `> `.
Escape CR, ANSI and other nonprinting controls visibly before writing so they
cannot erase that prefix or spoof host records. Test forged markers and split
multibyte input. These control lines are bounded presentation from the facade;
they own no durable truth, reconnection protocol or remote authority. Chat stays
a text transcript, not `ask`'s JSON result format. Tracing stays on stderr.

Keep at most one line under construction and one command awaiting admission;
`/wait` relies on pipe backpressure. Output queues total at most 256 KiB, with
provider progress dropped first and drop counts reported. Never drop control
records or silently truncate non-progress output. Non-progress overflow triggers
transport-failure cleanup before accepting further input. A control record that
cannot drain within 5,000 ms, broken output, input failure or first SIGINT/SIGTERM
stops input and follows bounded abort/cleanup independently of the writer. Never
claim cleanup from a broken output channel. A second interrupt reports cleanup
unknown where possible and exits nonzero. EOF and `/quit` abort active work,
including pending questions; scripts must `/wait` before EOF for normal success.
Pipe syntax/state refusal stops further input and exits nonzero after cleanup.
Interactive local refusal leaves the conversation usable.

All model-facing input obeys existing prompt/steer/follow-up limits. Chat exit is zero only when every admitted run/maintenance operation in that
invocation completed successfully and cleanup is conclusive. Any failed,
cancelled, bound-reached or unknown operation makes exit nonzero, even after a
later successful prompt. An interactive locally refused command does not itself mark a run
failed; piped refusal and startup/configuration refusal are nonzero. Report each outcome separately. Existing `run`/`resume` exit semantics are unchanged.
No second durable conversation state lives in the terminal.

**Tracing.** `--trace`/`--no-trace`, `--trace-level calls|returns|arguments`,
repeatable `--trace-module`, `--trace-max-entry-bytes`,
`--trace-max-entries-per-second`, `--trace-max-queue-entries` map to ADR 0030.
Expose them on chat, ask and daemon startup only when that command owns the
runtime. Existing non-owning commands reject them. Absent modules use ADR 0030's
existing Loopex-only default. No arbitrary module atoms; reject unsupported
selectors. File/CLI modules contain at most 64 strings of at most 128 bytes,
resolved through the host's compiled trusted-module inventory. Accept exact
admitted module names and only the `Loopex.*` and `LoopexProtocol.*` wildcard
selectors; lookup never creates an atom from input. Limits may only lower 4,096 bytes/entry, 2,000 entries/second,
8,192 queued entries. These are the existing tracer limits, not a total host
memory bound. `Loopex.*` maps to ADR 0030's `:loopex` application selector and
`LoopexProtocol.*` to `:loopex_protocol`; neither performs a string-prefix scan
that could include modules from another application.

The private `diagnostics_to` drain and stderr writer are separate supervised
processes. This is the existing diagnostic sink, not a new subscription API.
The drain keeps consuming while the writer is stalled. Its explicit pending
output queue admits at most 256 bounded diagnostic entries; excess trace and
ordinary diagnostic entries are dropped with separate counters. Durable events,
control records and model results never enter this lossy queue. The writer
accepts one entry at a time and acknowledges completion before receiving another.
It has no additional pending-output queue or unbounded stream of IO requests.

Distinguish these bounds: ADR 0030's admitted asynchronous diagnostic-item
ceiling is 4,096; the
tracer has its own limits above; the drain's pending-output ceiling is 256 and
the writer holds one entry. The drain mailbox retains ADR 0030's best-effort
host-sink backpressure, not a hard capacity guarantee. Internal direct diagnostic
senders and drop summaries mean even a private sink cannot honestly claim a
hard 256-entry or 4,096-entry total mailbox limit. M7 trace flags do not redesign
that accepted diagnostic contract. Tests report observed mailbox growth and
drop counts separately from the proved pending-output/writer bounds.

Closing the consumer stops both processes within the owner's cleanup grace.
Count queued discarded entries by kind; an unacknowledged in-flight write is
delivery-unconfirmed, never definitely emitted or dropped. Startup failure
of an explicitly requested trace refuses instead of silently running untraced.
Stop when the owning command/runtime ends through success, failure, interrupt
or daemon shutdown. A prompt finishing in a live chat or ephemeral session does
not stop its startup-enabled trace. Trace control has no new
client protocol method. JSON stdout excludes diagnostics.

Extend the closed `LoopexComposition.Ephemeral` startup/one-shot option set with
`:trace`, absent meaning disabled. Its value uses this ADR's closed trace map,
with the same string selectors and limits; it admits no module callback, PID,
raw runtime reference or arbitrary sink. The existing private session owner
validates it before startup, installs the shared stderr drain/writer and
starts the runtime trace after capability binding and before model dispatch.
Trace startup failure unwinds the owned composition; every termination path
stops the trace and consumer within the existing owner cleanup contract.
The CLI `ask` flags pass this explicit option, rather than trying to access a
hidden runtime. Ordinary durable owners use the same consumer and existing
runtime API. This adds no per-prompt mutation or access to another runtime.

<a id="technical-adr-0049-evidence"></a>
### Evidence

Concept: [Observable consequences](0049-explicit-host-configuration.md#concept-adr-0049-consequences).

- Closed-schema negatives, duplicate JSON/flags, bounded file reads, relative paths,
  no interpolation/discovery and no credential reads during effective inspection.
- Precedence/origin matrix, mandatory file limits, prompt replacement/append,
  provider mismatch, absent role models and disabled-role refusal.
- Public-facade conversation tests for each command state, TTY and pipe ordering,
  barriers, dynamically identified answers/declines, EOF, input/output bounds,
  marker spoofing, output stalls, fail-fast pipe errors,
  interrupts, idempotent resubmission and old-command compatibility.
- Resume after file edits preserves committed configuration/catalog; explicit
  settled changes commit atomically; in-flight changes refuse.
- Separate summarizer file/flag precedence, unconfigured display/refusal and
  invalid supplied model/route/mapping refusal. Resume may select a new model
  for later episodes without redirecting an admitted one; status distinguishes
  active from configured model and never reads credentials.
- Trace enable/disable, invalid scopes/limits, dropped counters, stalled stderr,
  JSON separation, runtime isolation, credential exclusions and cleanup.
- Operator V12 exercises file-only, CLI override, malformed input and restart.

<a id="technical-adr-0049-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0049-explicit-host-configuration.md#concept-adr-0049-compatibility).

The new configuration is experimental version 1, unrelated to durable-store
format numbers. An unsupported version refuses before startup. The eventual
M8 discovery proposal must reuse this schema or propose an explicit migration;
no second role/provider definition is authorized. Home discovery and writers,
provider endpoint overrides, file/command credentials and remote chat attachment
are deferred. There is no installed release label in this decision.
