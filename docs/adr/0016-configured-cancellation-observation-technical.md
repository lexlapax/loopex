# 0016. Configured cancellation observation — Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Configured cancellation observation](0016-configured-cancellation-observation.md#concept).

<a id="technical-adr-0016-context"></a>
## Clock and Authority Boundary

Concept: [Context](0016-configured-cancellation-observation.md#concept-adr-0016-context).

The job carries two different kinds of time:

- `effective_job_deadline` is an immutable wall-clock instant. It remains the
  canonical ADR 0009 request fact and is validated as such at the boundary.
- effect admission, cancellation, retention, cache work, and command backstops
  run against private monotonic deadlines. They are process-control facts and
  are never serialized as wall instants.

At Local handoff, one clock provider returns a paired sample
`{wall_now_ms, monotonic_now_ms}`. Local computes:

```text
remaining_ms = max(0, effective_job_deadline - wall_now_ms)
effect_action_deadline = checked_add(monotonic_now_ms, remaining_ms)
```

Subtraction is wall from wall; addition is duration to monotonic. Overflow,
invalid samples, or a deadline already reached refuses before effect. The
derived action deadline is immutable for that admitted job. Every later
effect-authorizing transition rechecks both independent fences:

```text
current_wall_ms < effective_job_deadline
current_monotonic_ms < effect_action_deadline
```

A backward wall jump therefore cannot extend authority beyond the unchanged
monotonic fence, while a forward wall jump expires authority by wall truth. A
wall jump never changes the private monotonic deadline and neither clock's
instant is compared with the other clock's instant. Monotonic waits use
positive, VM-safe slices and recompute remaining duration against the same
deadline after each slice.

<a id="technical-adr-0016-decision"></a>
## Exact Decision Mechanics

Concept: [Decision](0016-configured-cancellation-observation.md#concept-adr-0016-decision).

### Public and cross-application surface

Core exposes:

```text
default_cleanup_grace_ms() -> 5_000

cancellation_bounds(grace_ms) ->
  {:ok, %{
    executor_observe_ms: max(10_000, grace_ms + 2_000),
    receipt_retention_ms: max(1, ceil_div(grace_ms, 4)),
    execute_result_reserve_ms: max(1, ceil_div(grace_ms, 4)) + 2_000,
    terminal_reserve_ms: max(10_000,
      max(1, ceil_div(grace_ms, 4)) + 2_000),
    session_cache_ms: max(10_000,
      max(1, ceil_div(grace_ms, 4)) + 2_000),
    cli_backstop_ms: max(10_000, grace_ms + 2_000)
      + max(1, ceil_div(grace_ms, 4)) + 2_000
      + max(10_000, max(1, ceil_div(grace_ms, 4)) + 2_000)
  }}
  | {:error, :invalid_cleanup_grace}

cancel(module, reference, job_id, grace_ms) ->
  {:ok, :cleaned} | {:ok, :unconfirmed}
  | {:error, :invalid_cleanup_grace}

prepare_resume_session(runtime, session_id, command_id) ->
  {:ok, {:prepared, ResumeActivation.t()}}
  | {:ok, {:replayed, session_id}}
  | {:error, reason}

prepare_resume_known_session(state_root, runtime, session_id, command_id) ->
  {:ok, {:prepared, ResumeActivation.t()}}
  | {:ok, {:replayed, session_id}}
  | {:error, reason}

activate_resume(ResumeActivation.t()) -> {:ok, session_id} | {:error, reason}
abandon_resume(ResumeActivation.t()) -> :ok | {:error, reason}
```

`grace_ms` is exactly `1..18_446_744_073_709_551_615`. Direct scalar APIs
return `invalid_cleanup_grace` outside that domain before a callback. Runtime,
composition, CLI, and Local construction preserve their existing error shapes.
The executor behaviour callback remains `cancel/2`; `cancel/4` supplies the
configured observation bound around it. `cancel/3` retains ADR 0012's 60-second
defensive behavior and is never selected by production coordination.

The interrupt boundary retains `install/1` for compatibility. Production uses
configured installation and prepared installation with the opaque recovery
capability. The capability is neither serializable nor public truth; only the
current prepared owner may activate or abandon it. Handler installation alone
does not schedule recovered work.

The additive cross-application entries are `Interrupt.install/2`,
`Interrupt.install_prepared/3`, and `Interrupt.abandon_resume/2`. The Local
placement boundary adds
`Loopex.Executor.Local.prepare_placement(ledger_root, executor_identity,
cleanup_grace_ms)`, which validates or exclusively creates the generation and
returns the private prepared ledger authority. Local also exposes
`default_cleanup_grace_ms/1`; its retained `cleanup_grace_ms/1` name is a
compatibility alias for that startup default, never the value of an active job.

### Durable session and request facts

The exact genesis shape is:

```text
session_genesis_v2 = %{
  kind: "session_genesis_v2",
  "options" => normalized_session_options,
  "runtime_configuration" => %{
    "cleanup_grace_ms" => positive_uint64
  }
}
```

The outer key set and the runtime-configuration key set are closed. The complete
canonical item is at most 65,536 bytes. An over-ceiling item returns
`session_configuration_too_large` before owner acquisition. The new reducer
refuses legacy `session_genesis`; the prior reducer refuses
`session_genesis_v2`. No decoder supplies a missing cleanup value.

`JobRequest.cleanup_grace_ms` and `session_status.cleanup_grace_ms` equal the
committed value. The job field participates in the existing canonical request
digest. The complete effect-intent item is normalized and measured before its
Store transaction; one byte above the Store ceiling commits the ordinary
pre-effect failed result `effect_intent_record_too_large` and dispatches
nothing.

Every terminal executor receipt adds exactly:

```text
cleanup_confirmation = confirmed | unconfirmed
receipt_retention_bound_ms = exact committed positive uint64 duration
```

`cleanup_confirmation` is captured-process-group truth, independent of outcome.
An unconfirmed cleanup is conforming only with `outcome_unknown`. Missing,
malformed, or contradictory cleanup facts fail closed. A descendant that leaves
the captured group is outside both M2 kill authority and confirmation; this ADR
does not widen that accepted boundary or claim that every escaped descendant is
gone. ADRs 0009 and 0012 use “owned process tree” for the job scope named by its
captured kill identity; for Local, that exact scope is the captured process
group, not all later descendants. Local captures the nonnegative
`observed_at_ms` at effect admission and
carries that same value to terminal construction; it does not resample
completion time.

Receipt-fit preflight measures every mandatory terminal variant before effect
permission. Local may spill below the model-facing output ceiling or shorten the
visible prefix solely to keep the exact receipt within its bounded envelope. A
valid artifact result is always carried and preserves full-byte reconstruction.
Refusal or malformed artifact output selects a bounded retention-unavailable
receipt and never claims the missing suffix is reconstructible.

### Local durable ledger schemas

All records below are exact-key, canonical external-term values. Unknown keys,
wrong relations, invalid encodings, symlinks, replacements, or records above
their stated ceiling make the ledger unavailable rather than absent. Local
checks the raw file byte size against the record's ceiling before external-term
decode, then applies the same ceiling to the canonical re-encoding.

The effect-admission marker, installed before the effect permit, is:

```text
%{
  ledger_kind: "local_effect_admission_v1",
  "job_id" => exact_job_id,
  "canonical_request_digest" => exact_attempt_bound_digest,
  "operation_id" => exact_operation_id,
  "attempt" => positive_integer,
  "cleanup_grace_ms" => exact_committed_positive_uint64,
  "admission_nonce" => lowercase_64_hex
}
```

The admission-marker record ceiling is 65,536 bytes.

The exact durable pre-effect refusal is:

```text
%{
  ledger_kind: "local_pre_effect_refusal_v1",
  "job_id" => exact_job_id,
  "canonical_request_digest" => exact_attempt_bound_digest,
  "operation_id" => exact_operation_id,
  "attempt" => positive_integer,
  "reason" => %{
    "code" => bounded_reason_code,
    "field" => nil | bounded_binding_field
  }
}
```

Allowed reason codes are `cancelled_before_start`,
`workspace_lease_not_held`, `workspace_lease_lost`,
`workspace_lease_mismatch`, `executor_prestart_mismatch`,
`invalid_job_request`, `canonical_job_request_mismatch`,
`tool_definition_mismatch`, `host_policy_allow_required`, `invalid_grant`,
`invalid_tool_arguments`, `receipt_record_shape_too_large`,
`effective_deadline_reached`, `effect_start_authority_unavailable`,
`missing_binding`, and `binding_mismatch`. `field` is non-null only for the
last two codes and then is one of ADR 0007's grant-binding names. The record
ceiling is 65,536 bytes.

The open-authority entry is:

```text
%{
  ledger_kind: "local_open_effect_v1",
  "job_id" => exact_job_id,
  "canonical_request_digest" => exact_attempt_bound_digest,
  "executor_identity" => exact_executor_identity,
  "origin_executor_epoch" => exact_epoch,
  "cleanup_grace_ms" => exact_committed_positive_uint64
}
```

The open-entry record ceiling is 65,536 bytes.

Its pathname is the lowercase SHA-256 of the decoded job ID. The directory
contains at most 1,024 entries. A complete root observation is a closed,
bytewise-ordered snapshot binding generation digest, root binding, root-claim
nonce, entry count, and for each entry its basename, raw-byte digest, decoded
job/request/executor/epoch/grace fields. The canonical snapshot is at most
4,194,304 bytes. This snapshot is administrative evidence, not a public record.

The generation record is at most 2,048 bytes:

```text
%{
  ledger_kind: "local_executor_generation_v1",
  "executor_identity" => exact_configured_executor_identity,
  "executor_epoch" => positive_integer_at_most_2^256_minus_1,
  "generation_id" => lowercase_64_hex_encoding_of_that_epoch,
  "root_binding" => lowercase_64_hex_sha256_of_domain_path_device_and_inode
}
```

Initial creation draws a nonzero 256-bit epoch, uses exclusive no-symlink
publication, syncs file and parent, and reads back before Local starts. The
root-binding digest input is:

```text
<<"loopex:local-root-binding:v1", 0,
  byte_size(expanded_root)::unsigned-64-big,
  expanded_root::binary,
  major_device::unsigned-64-big,
  inode::unsigned-64-big>>
```

`expanded_root` is exactly the binary returned by `Path.expand(ledger_root)` at
placement preparation; no realpath or Unicode normalization is applied. After
durably creating the directory and before reading or creating the generation,
Local calls `File.stat(expanded_root, time: :posix)`, requires `type: :directory`
and nonnegative unsigned-64-bit `major_device` and `inode`, and uses those exact
two fields above. `File.stat/2` intentionally follows any path symlink, while
the expanded path bytes still bind the alias the caller supplied. Every later
root-claim acquisition repeats the same expansion and stat and refuses a path,
device, or inode mismatch before reading a ledger byte. Exact vectors therefore
have one reproducible path and filesystem observation procedure.

The private prepared authority contains the canonical ledger root, generation
record digest, and exact root binding. Local and `WorkspaceLease` may carry it;
Core Runtime and all public, durable job, grant, receipt, event, progress,
diagnostic, and log planes may not.

### Linearization and fail-closed rules

The implementation may choose private processes, messages, monitors, and state
names, but it must preserve these observable and durable invariants:

1. A root-wide exclusive administrative claim orders admission, refusal or
   receipt replacement, open-entry removal, and startup reconciliation. A
   per-entry claim is nested inside the root claim. Claims are never timed out
   or reaped into permission.
2. Admission publishes and parent-syncs the marker and open entry before the
   one effect permit. The permit follows the serialized in-memory reservation
   immediately; no second Local can observe an admissible gap.
3. Publication is first-writer-wins. A refusal or receipt may replace only the
   exact marker it names, under the exact claim, followed by parent sync. A
   stale or late writer cannot overwrite newer truth.
4. A queued cancellation or pre-marker deadline may create the exact refusal
   without inventing a marker. It answers clean only after durable publication,
   unchanged-root proof, and authority release. An absent ID has no request
   digest and answers unconfirmed without durable cancellation state.
5. Once effect admission wins, cancellation joins one cleanup episode. It does
   not start another episode or claim no effect. Worker or owner death is not
   cleanup proof.
6. Receipt preparation, optional artifact retention, publication, lease-loss
   handoff, sync recovery, and open-entry removal share one monotonic retention
   deadline. No phase refreshes it and no timeout is a verdict.
7. A receipt is replayable only after exact file and parent-sync proof. Every
   terminal-plus-open decision additionally acquires the root-wide claim, reads
   one complete bounded snapshot while mutation is excluded, and fixes its
   decision before releasing the claim. Claim refusal, malformed truth, or an
   incomplete snapshot is bounded ledger-unavailable, never permission. No
   unlocked observation is replay, cancellation, reconciliation, or admission
   authority. An open entry is removed only after a matching durable refusal,
   confirmed captured-group cleanup receipt, proved no-effect cleanup, or other
   exact accepted authority proof. An `outcome_unknown` receipt with unconfirmed
   cleanup leaves the root quarantined.
8. Duplicate request identity joins or replays the one operation. A conflicting
   digest conflicts. Capacity limits count live, publication, recovery, and
   quarantined authority; they never evict unresolved effect truth.
9. Every external or filesystem worker is owned and monitored before it may act.
   Owner loss terminates exact guarded authority. Numeric PID/PGID observations
   never become signal authority. Late, malformed, or mismatched results change
   no state. Command confirmation is limited to the captured process group;
   escaped descendants remain outside the accepted M2 guarantee.
10. Recovery reconciles the complete open index before Local accepts new work.
    Unresolved truth refuses new effects with reconciliation required. Startup
    may use one fresh bounded reconciliation deadline, but it cannot refresh an
    admitted job's deadlines.

### Trusted-root posture

The root is one trusted atomic administrative unit. Its generation binding
detects an ordinary whole-root move presented at a different expanded path,
replacement, and isolated generation-file copy. M2 refuses those operations and
supplies no migration command. Retargeting the original path through an
administrator-created alias, partial copy/delete, snapshot rollback, inode
reuse, and administrator rewriting are outside the integrity boundary and may
erase or counterfeit local authority. They are unsupported, not silently
repaired.

Recovery from a retired or ambiguous root leaves that root quarantined. A fresh
empty root with a new generation may be activated only after positive
termination of every Local instance, guard, captured worker group, and other
effect authority from the old generation. If any termination is unconfirmed,
the host must reboot first; selecting another path in the same boot is not a
rollback and may not admit effects. A future migration must first close every
old open authority and then create a new generation; it may not copy the old
generation as authority.

### Recovery and command ordering

New session creation commits the normalized value. Resume and cancel recover it
before scheduling. An omitted CLI option uses the retained value; an explicit
conflict is refused only after the prepared owner is safely abandoned. Unknown
session or placement mismatch reaches neither Store recovery nor owner
activation.

Prepared recovery returns an opaque, one-use activation capability. Interrupt
installation and holder transfer are one serialized handoff: preparer death
before the handoff invalidates it, while death after acknowledgement does not.
Resume activates ordinary work exactly once only while no abort has begun.
Cancel admits abort while work stays paused. An accepted abort permanently
invalidates activation; pending, unavailable, or commit-unknown abort admission
never permits recovered work.

The interrupt handler owns one abort command identity. Concurrent signals join
one admission attempt. It arms the admission backstop before entering a possibly
blocking Store call. A proved refusal or non-commit disarms and rotates only
after the worker terminates. Acceptance freezes the identity and extends the
deadline once to `max(admission_deadline, accepted_at + cli_backstop_ms)`.
Replays cannot repeatedly extend it. Expiry halts for recovery; it never proves
whether abort committed.

<a id="technical-adr-0016-alternatives"></a>
## Alternative Failure Modes

Concept: [Alternatives](0016-configured-cancellation-observation.md#concept-adr-0016-alternatives).

Fixed waits undercut large valid configurations. Caller-selected waits make the
durable value advisory. Executor queries couple Core to one adapter. Process-
local state cannot fence another Local or restart. Overwrite publication lets a
late writer erase newer truth. Automatic stale-claim cleanup converts elapsed
time into effect authority. PID re-probing retains the identifier-reuse race.
The selected design instead pays with bounded refusal and quarantine.

<a id="technical-adr-0016-consequences"></a>
## Compatibility, Rollback, and Evidence

Concept: [Consequences](0016-configured-cancellation-observation.md#concept-adr-0016-consequences).

Compatibility is source-additive at the public facade but data- and behavior-
breaking for the unreleased M2 session/job/receipt formats. Legacy convenience
entries preserve their former direct-caller bounds; production paths must not
select them for a configured session. Executor implementations retain
`cancel/2` but must emit the new receipt facts and honor the committed job
value. No decoder upgrades legacy genesis or ledger bytes.

Rollback uses the prior source with a fresh empty state root and new sessions
only after every old effect authority has positively terminated, or after a
mandatory host reboot when that proof is unavailable. It does not rewrite
`session_genesis_v2`, strip receipt fields, downgrade a generation, reopen a
quarantined root, or admit the fresh root merely because it has another path.
The old root and all evidence bytes remain available for audit. The
receipt-fitting consumer is removed before ADR 0017's
Store normalization/measurement API or ADR 0015's compact object/use reference,
or all three dependent pieces are removed atomically; removing either provider
first is not a compatible intermediate state.

Required evidence classes are:

- formula properties at floor, default, former fixed waits, large valid values,
  unsigned-64 boundaries, rounding points, strict deadline ordering, and exact
  public error propagation;
- clock-domain tests with deliberately divergent wall and monotonic origins,
  forward and backward wall jumps after handoff, already-expired wall deadlines,
  checked-arithmetic overflow, VM timer slicing, and proof that both the wall
  truth fence and the immutable monotonic action deadline independently control
  every later effect-authorizing transition;
- a delayed-effect receipt case proving `observed_at_ms` is the one sample taken
  at effect admission, plus a mutant that resamples at completion and must fail
  that case;
- exact genesis, job, receipt, marker, refusal, open-entry, root-snapshot, and
  generation vectors, including closed-key, relation, canonicalization, size,
  digest, sync, and old/new decoder compatibility negatives;
- concurrency and fault injection at admission-versus-cancel/deadline,
  duplicate-versus-conflict, Local-versus-Local root claims, publication-versus-
  lease loss, owner/worker/guard death, late results, restart reconciliation,
  capacity, and all fail-closed quarantine outcomes;
- mutation evidence deleting each durable compare, parent-sync requirement,
  root-read claim, owner/permit fence, deadline non-refresh rule,
  cleanup-field validation, receipt-fit/artifact fallback, recovered-value
  propagation, and legacy-production-path exclusion;
- process evidence that captured command groups and filesystem workers cannot
  outlive their exact Local authority, that numeric identifiers are never used
  as cleanup authority, and that confirmed cleanup requires positive captured-
  group quiescence; escaped descendants are explicitly outside this proof;
- rollback evidence that an ambiguous open authority refuses fresh-root
  activation in the same boot, that positive termination admits it, and that a
  mutant treating a new path or stopped application as termination fails;
- recovery and CLI evidence for matching, omitted, and conflicting configuration,
  prepared holder transfer, signal/activation ordering, single-flight abort,
  admission and accepted backstops, and no dispatch while recovery is paused;
- security-plane inventories proving credentials, root paths, generation
  authority, activation capability, nonces, monitors, and private publication
  authority never enter forbidden durable or public planes;
- trusted-root negative demonstrations for whole-root move/replacement and
  isolated generation copy, plus an explicit retained limitation for partial
  copy/delete, rollback, inode reuse, and administrator rewrite;
- real reference-stack evidence with a non-default cleanup value spanning
  creation, effect dispatch, cancellation, receipt, process restart, resume, and
  cancel recovery.

Evidence should lock observable contracts and durable transitions. Exact private
BEAM state constructors, message tuple layouts, monitor arrival orders, helper
process counts, and exhaustive interleaving scripts remain implementation and
test design, not accepted ADR bytes.
