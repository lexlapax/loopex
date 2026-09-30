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
| `providers` | Required map of 1–16 supported provider names to exactly `{"credential":{"env":"NAME"}}`; ADR 0048 owns reference syntax and custody |
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
| `roles` | Optional map of at most 16 bounded role names to required `model`, `instructions_file` and optional `reasoning` defaulting to `default` |
| `delegation` | Optional `enabled` default false, `roles` list default empty; when enabled require nonempty enabled-role list, `max_children` from 1 to 128, positive `token_budget`, `child_bounds`; optional `max_tokens` default 4,096 |
| `delegation.child_bounds` | Required positive `max_turns`, `deadline_ms`, `token_budget`; no implicit spending defaults |
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
policy, tools, paths or limit overrides. The parent task definition's enum
contains only the explicitly enabled names. ADR 0046 freezes the catalog.

**Precedence.** Validate authored file values first. Then apply explicit CLI
value > `LOOPEX_HOME` for state root only > selected file > documented harmless
default. No other configuration environment aliases are introduced. Credential
variables are references resolved later, not setting overrides. Require workspace,
state root, policy, providers and conversational bounds before starting. Report
each effective value with `flag`, `env`, `file#pointer`, `default` or `committed`
origin; never resolve credentials for inspection. Mutually exclusive duplicate
flags refuse; repeated skill directories/modules replace their file arrays.

**Command grammar, proposed until implemented.**

```text
loopex config validate --config FILE
loopex config show --config FILE --effective
loopex chat --config FILE [--workspace DIR] [--state-root DIR] [--resume SESSION_ID]
```

The chat overrides are `--model`, `--reasoning`, `--max-steps`, `--deadline-ms`,
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
instructions, tools, resources and role catalog. Explicit conflicting flags
for those fields refuse and direct the operator to `/configure` for mutable
settings; immutable tool/catalog changes require a new session. New run bounds
come from validated invocation configuration; in-flight bounds stay committed.
Require matching workspace/policy identity and available routes for admitted
work. Trace/output are host-local options, not durable session configuration.

| Input | Behaviour |
| --- | --- |
| Plain nonempty line while settled | Submit prompt with a fresh idempotency identity |
| Plain line during active work | Refuse locally with instructions to use an explicit action |
| `/steer TEXT`, `/follow-up TEXT` | Existing admission and disposition rules |
| `/answer ID TEXT`, `/answer ID --choice CHOICE_ID` | Bound response to the pending interaction identity; duplicate/late replies follow ADR 0045 |
| `/compact` | Bounded settled compaction under ADR 0043; active use refuses |
| `/configure JSON` | Closed mutable fields from ADR 0044, with optional ADR 0042 instruction envelope; atomic settled update; raw credential/file/role fields refuse |
| `/abort` | Existing run abort and bounded cleanup |
| `/status` | Committed model/bounds, pending interaction and host trace/usage status |
| `/quit`, EOF | Abort foreground active work, wait bounded cleanup, stop trace/runtime, print truthful outcome and exit |
| Ctrl-C | Same cancellation path; second interrupt ends waiting with cleanup explicitly unknown |
| `//TEXT` | Literal prompt beginning `/TEXT` while settled |

All model-facing input obeys existing prompt/steer/follow-up limits. Chat exit is zero only when every admitted run/maintenance operation in that
invocation completed successfully and cleanup is conclusive. Any failed,
cancelled, bound-reached or unknown operation makes exit nonzero, even after a
later successful prompt. A locally refused command does not itself mark a run
failed; startup/configuration refusal is nonzero. Report each outcome separately. Existing `run`/`resume` exit semantics are unchanged.
No second durable conversation state lives in the terminal.

**Tracing.** `--trace`/`--no-trace`, `--trace-level calls|returns|arguments`,
repeatable `--trace-module`, `--trace-max-entry-bytes`,
`--trace-max-entries-per-second`, `--trace-max-queue-entries` map to ADR 0030.
Expose them on chat, ask and daemon startup only when that command owns the
runtime. Existing non-owning commands reject them. Absent modules use ADR 0030's
existing Loopex-only default. No arbitrary module atoms; reject unsupported
selectors. Limits may only lower 4,096 bytes/entry, 2,000 entries/second,
8,192 queued entries. The reference host uses the diagnostic sink and a bounded
consumer with 256-entry backlog, shedding excess entries with a separate drop
counter. Never enqueue unbounded output while stderr stalls. Startup failure
of an explicitly requested trace refuses instead of silently running untraced.
Stop on success/failure/interrupt or daemon shutdown; trace control has no new
client protocol method. JSON stdout excludes diagnostics.

<a id="technical-adr-0049-evidence"></a>
### Evidence

Concept: [Observable consequences](0049-explicit-host-configuration.md#concept-adr-0049-consequences).

- Closed-schema negatives, duplicate JSON/flags, bounded file reads, relative paths,
  no interpolation/discovery and no credential reads during effective inspection.
- Precedence/origin matrix, mandatory file limits, prompt replacement/append,
  provider mismatch, absent role models and disabled-role refusal.
- Public-facade conversation tests for each command state, non-TTY, EOF,
  interrupts, idempotent resubmission and old-command compatibility.
- Resume after file edits preserves committed configuration/catalog; explicit
  settled changes commit atomically; in-flight changes refuse.
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
