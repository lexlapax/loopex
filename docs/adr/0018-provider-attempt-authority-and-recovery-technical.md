# 0018. Provider attempt authority and recovery — technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Provider attempt authority and recovery](0018-provider-attempt-authority-and-recovery.md#concept).

<a id="technical-adr-0018-context"></a>
## Why Identity Is Not Authority

Concept: [Context](0018-provider-attempt-authority-and-recovery.md#concept-adr-0018-context).

The durable staged request answers exactly which canonical bytes one model
operation intended. It cannot observe the boundary between a local transport
construction and a remote provider accepting a request. The unresolved interval
therefore has three durable classes rather than a Boolean retry flag:

```text
not_dispatched
dispatched_or_unknown
settled_reply
```

Only the first class is retry authority. The second is accounting and terminal
truth, not executor effect truth: it does not create `outcome_unknown`, because
the provider call mutates no Loopex-controlled external effect domain that a
later reconciliation can safely complete. It instead conserves the possible
bill and ends the model operation.

The transient stream plane does not improve this evidence. A partial delta, a
closed relay, a dead worker, or the absence of all three can occur on either side
of provider acceptance. None is durable `not_dispatched` proof.

<a id="technical-adr-0018-decision"></a>
## The Exact Provider-Attempt Protocol

Concept: [Decision](0018-provider-attempt-authority-and-recovery.md#concept-adr-0018-decision).

### Attempt identity and versioned allowance

One staged model operation has stable `run_id`, `turn_id`, `operation_id`, and
`staged_request_digest`. `operation_id` remains the existing deterministic model
operation ID derived from run and turn; this ADR does not accept an adapter-
supplied identity.

Version 1 permits exactly these attempt positions:

```text
attempt 1: first attempt for the staged operation
attempt 2: one retry after attempt 1 durably settled not_dispatched
```

Attempt zero, an attempt above two, attempt two without the exact prior
settlement, or any reset of the count at owner succession is invalid history.
The policy is encoded by the `model_attempt_opened_v1` kind and its reducer, not
by a process attribute that replay cannot see. A different total or retry rule
requires a new record kind and a migration/compatibility decision.

Attempt dispatch authority is the exact six-key record:

```text
%{
  kind: "model_attempt_opened_v1",
  "run_id" => bounded_nonempty_binary,
  "turn_id" => bounded_nonempty_binary,
  "operation_id" => bounded_nonempty_binary,
  "attempt" => 1 | 2,
  "staged_request_digest" => lowercase_sha256_hex
}
```

Every member equals the current committed staged request. Attempt one is the
second row of one ordered first-staging transaction:

```text
[model_request_committed, model_attempt_opened_v1(attempt: 1)]
```

Only the first model operation in a run carries the matching `run.started`
event. Applying the request row alone installs
`model_request_pending_attempt_open`; it exposes no staged request, attempt,
stream domain, provider dispatch, conversation, accounting, queue effect, or
public start until the exact consecutive open row arrives. Page boundaries may
carry the marker. Head, intervening, duplicate, or mismatched rows are invalid
history. Commit-unknown re-presents the identical transaction and event bytes.

An exact attempt-one settlement with `next: retry` installs
`retry_permitted(next_attempt: 2)`. It does not open attempt two. After rereading
current run, ownership, abort, deadline, prior settlement, and version, Core may
commit exactly one attempt-two open record. Proved non-commit retains retry
permission; commit-unknown re-presents the same bytes. Applying the open record
consumes the permission permanently.

### One-use Control permit

After an attempt-open record is durably confirmed, the coordinator starts a
model worker that cannot invoke `Loopex.LLM.complete/3` until it receives one
fresh exact permit. The coordinator calls Control with:

- runtime/session identity;
- expected owner epoch, owner-incarnation ID, and coordinator PID;
- run, turn, operation, attempt, and staged-request digest;
- the committed journal version containing the open fact;
- worker PID and fresh permit reference; and
- the committed absolute deadline.

Inside one serialized Control handler, Control verifies the caller is still the
prepared current owner, every identity equals its registered state, the open
journal position is current, the full
`{session, run, turn, operation, attempt}` identity has never been permitted,
and the deadline has not elapsed. It atomically spends that full attempt
identity, binds its one admitted worker/reference pair, and sends the exact
permit directly to that worker before replying to the coordinator. A later
request for the same attempt refuses even when it supplies a fresh PID and
reference.

That send is the provider-dispatch linearization point. It satisfies ADR 0006's
current-owner fence. If ownership changes after the send but before the worker
runs, the already-linearized authorization remains valid for that attempt; the
successor cannot issue another. Control retains the spent attempt identity and
its bound worker/reference for the complete ownership generation; replacing the
coordinator or worker does not clear it. A wrong or duplicate reference, worker,
identity, or attempt is ignored by the worker and cannot call the adapter.

No finite timeout is a dispatch verdict. These cells are exact:

| Observation | Transport classification | Provider call authority |
| --- | --- | --- |
| Control refuses before sending for deadline, open-position, or worker mismatch while the same owner remains authoritative and durably settles that exact refusal | `not_dispatched` | none |
| Coordinator receives a positive reply | permit was sent; `dispatched_or_unknown` until result settlement | one call by the exact worker |
| Control dies or its reply is lost after the request could have been handled | `dispatched_or_unknown` | successor issues none |
| Worker dies before a permit can have been sent and Control proves refusal | `not_dispatched` | none |
| Worker dies after a possible permit send | `dispatched_or_unknown` | successor issues none |
| Ownership hands off before Control handles the request, so the predecessor cannot retain its ephemeral refusal | successor recovers the open attempt as `dispatched_or_unknown` | successor issues none |
| Ownership hands off after Control sends | `dispatched_or_unknown` | old worker retains only that one authorization; successor issues none |

The coordinator never receives `:ok` and then sends the permit. The worker never
calls Control for its own authorization. The permit is not journaled: durable
permission would still not prove whether transport happened and could be
mistaken for replayable dispatch authority.

### Model result boundary

The Model callback boundary is:

```text
{:ok, reply()}
| {:error, {:not_dispatched, "model_call_failed"}}
| {:error, {:dispatched_or_unknown, "model_call_failed"}}
| {:error, term()}
```

Only a conforming adapter that has neither invoked provider transport nor handed
request bytes to it may return `not_dispatched`. The shipped adapter may use it
for local credential, request-shape, model-resolution, or transport-construction
refusal before handoff. A wrong tag/category, throw, exit, task `DOWN`, timeout,
malformed reply, legacy error, provider-library result after invocation, or tag
contradicted by a transport canary is `dispatched_or_unknown`. Raw reasons are
bounded at the callback edge and retained nowhere.

The normalized reply's exact usage is one of:

```text
%{"status" => "reported", "input_tokens" => uint64,
  "output_tokens" => uint64}
%{"status" => "unreported", "category" =>
  "missing" | "partial" | "malformed" | "uint64_overflow"}
```

Classification order is overflow, both valid, exactly one present, both absent,
then malformed. Negative, non-integer, oversized, and unknown raw fields never
enter retained or rendered data. A complete reported pair is exact accounting;
every other dispatched cell uses the exact remaining allowance.

`bounded_adapter_reply_v2` is the exact nine-key map:

```text
%{
  "text" => valid_utf8_binary,
  "identity" => %{
    "provider" => nonempty_valid_utf8_binary,
    "model" => nonempty_valid_utf8_binary,
    "endpoint" => nonempty_valid_utf8_binary
  },
  "usage" => normalized_usage,
  "tool_calls" => [tool_call],
  "delta_count" => uint64,
  "streamed" => boolean,
  "provider_response_id" => nil | nonempty_valid_utf8_binary_at_most_256_bytes,
  "canonical_request_bytes" => binary_equal_to_committed_request,
  "staged_request_digest" => lowercase_sha256_hex_equal_to_committed_digest
}
```

`streamed` is true exactly when `delta_count > 0`. A non-streaming adapter is
normalized to the explicit pair `delta_count: 0, streamed: false`; omission is
not retained in v2. Each `tool_call` is exactly
`%{"id" => id, "name" => name, "arguments" => arguments}`; `id` and `name`
are nonempty valid UTF-8 binaries, and `arguments` is a plain map accepted by
ADR 0017's depth/cardinality/key normalizer. No extra key is accepted at any
level named here.

The echoed `canonical_request_bytes` is validated for byte-for-byte equality
with the already admitted committed request and then excluded from reply-size
measurement. It does not make the callback map a second durable Store item and
does not create a combined request-plus-response ceiling. Core applies the
normalizer's structural limits to the newly supplied reply members, projects
the eight-key durable reply below, and applies the 65,536-byte item ceiling to
that projection inside the complete settlement record. The staged request and
the intended durable reply must each fit their own owning record; their sum need
not fit one item.

The exact durable `bounded_canonical_reply_v2` is the eight-key map obtained by
omitting only `canonical_request_bytes` from the validated adapter reply. It
retains the other values byte-for-byte; it does not rebuild identity, calls,
usage, response ID, stream evidence, or digest during replay.

### Atomic settlement

The exact twelve-key settlement record is:

```text
%{
  kind: "model_attempt_settled_v1",
  "run_id" => bounded_nonempty_binary,
  "turn_id" => bounded_nonempty_binary,
  "operation_id" => bounded_nonempty_binary,
  "attempt" => 1 | 2,
  "staged_request_digest" => lowercase_sha256_hex,
  "transport" => "not_dispatched" | "dispatched_or_unknown",
  "termination" => nil | "abort" | "deadline" | "owner_loss",
  "conversation" => "canonical" | "evidence_only" | "none",
  "next" => "retry" | "continue" | "terminal",
  "result" => result_projection,
  "accounting" => accounting_projection
}
```

`result_projection` is exactly one of:

```text
%{"kind" => "reply", "reply" => bounded_canonical_reply_v2}
%{"kind" => "error", "category" =>
  "model_call_failed" | "unreadable_model_answer"}
```

Accounting is exactly one of:

```text
%{"source" => "none", "basis" => "not_dispatched"}
%{"source" => "reported", "input_tokens" => uint64,
  "output_tokens" => uint64}
%{"source" => "estimated", "basis" => "remaining_allowance"}
```

Applying settlement is indivisible. `none` changes no counter. `reported` adds
the exact two usage members with checked arbitrary-precision arithmetic.
`estimated` sets cumulative tokens to the committed run token budget and adds
exactly `token_budget - cumulative_tokens_before_attempt` to the estimated
subtotal. No later row supplies or revises a charge.

The closed valid-combination table is:

1. A canonical reply is dispatched-or-unknown, has no termination, enters the
   canonical conversation, and uses reported accounting only for complete valid
   usage; otherwise it uses estimated accounting. Tool calls select `continue`;
   a no-tool reply selects the normal completed terminal.
2. An abort or deadline committed first is the termination winner. A late valid
   reply is evidence-only and a late error enters no conversation. Complete
   usage remains reported; every other possibly dispatched result is estimated.
   Exact pre-permit `not_dispatched` remains uncharged. Next is the already
   selected run terminal.
3. A live ambiguous error and a recovered open attempt are
   dispatched-or-unknown, use bounded `model_call_failed`, estimated accounting,
   no conversation, and terminal. Recovered open uses `owner_loss` unless an
   earlier abort or deadline wins.
4. Exact `not_dispatched` has no conversation and no accounting. Attempt one
   selects retry only when no termination has won; attempt two selects terminal
   model-call failure because version 1 has no remaining allowance.
5. A reply that passed request/usage validation but whose complete durable
   settlement cannot fit becomes compact `unreadable_model_answer`, enters no
   conversation or tools, preserves complete reported usage when available and
   otherwise estimates the remainder, and is terminal unless an earlier abort
   or deadline already selected the run terminal.

All other combinations are invalid history, including a reply tagged
not-dispatched, attempt-one retry without exact transport proof, attempt-two
retry, dispatched accounting none, reported accounting without matching reply
usage, estimated accounting short of the exact remaining allowance, or owner-
loss settlement for a retry-permitted between-attempt state.

Before commit, Core uses ADR 0017's shared Store normalizer and exact item sizer
on the intended settlement and any paired terminal. It proposes those normalized
items, never a rebuilt value. If a reply settlement does not fit, Core preflights
and commits the compact unreadable settlement instead. An unexpected refusal of
that bounded compact pair makes the session unavailable and fabricates no
settlement, accounting, conversation, tool dispatch, or terminal.

When `next` is terminal, one transaction contains exactly:

```text
[model_attempt_settled_v1, run_terminal_committed]
```

Applying the first row installs `model_attempt_pending_terminal` and no semantic
effect until the exact consecutive terminal arrives. Page boundary is valid;
head, intervening, duplicate, or mismatched rows are invalid. Retry and continue
settlements are one-record transactions. Commit-unknown always re-presents
identical bytes and fences publication, retry, next turn, closure, and terminal.

### Abort, deadline, and recovery

An open-attempt deadline admission is:

```text
%{
  kind: "model_termination_admitted_v1",
  "run_id" => run_id,
  "turn_id" => turn_id,
  "operation_id" => operation_id,
  "attempt" => 1 | 2,
  "staged_request_digest" => lowercase_sha256_hex,
  "cause" => "deadline",
  "deadline" => uint64,
  "observed" => uint64
}
```

Every identity matches the open attempt and `observed >= deadline`. Abort keeps
ADR 0011's durable command admission. The first committed of settlement, abort,
and deadline classifies the attempt; abort versus deadline is likewise journal
order. A stop signal is cleanup only and never durable authority.

Recovery distinguishes three states:

- `model_request_pending_attempt_open`: complete or resolve the original staging
  transaction; never dispatch from the request row alone.
- `retry_permitted(next_attempt: 2)`: reread abort, deadline, ownership, and the
  exact attempt-one settlement; either terminate between attempts or propose the
  one attempt-two open record.
- open attempt without settlement: never redispatch. First honor a committed
  abort; otherwise admit an elapsed deadline if required; otherwise settle
  dispatched-or-unknown with owner-loss evidence, estimated remaining allowance,
  and terminal model-call failure.

A prior attempt's `not_dispatched` proof never transfers to a newly opened
attempt. A late origin may submit evidence, but ADR 0006 fences its durable
write; the current owner alone settles. An authoritative origin, or one whose
retained result already proves the closure, closes from durable settlement
before outcome publication. Separately, a notified live-model predecessor keeps
ADR 0014's terminate, drain, and `abandoned` closure even though it cannot write
new durable settlement after handoff. A successor applies settlement and
terminal truth but never fabricates a closure for the predecessor's dead
transient stream.

Terminal precedence remains: canonical no-tool completion wins after its
settlement; a tool reply continues until ordinary later run truth; abort wins by
admission order; deadline commits `bound_reached(:deadline)`; ambiguous provider
failure with neither winner commits non-retryable `model_call_failed`; exact
not-dispatched retries once then fails uncharged if the second attempt also
refuses. Estimated accounting reaching the token limit is not itself
`bound_reached`; the ordinary next pre-staging check remains the selector.

<a id="technical-adr-0018-alternatives"></a>
## Alternative Costs

Concept: [Alternatives](0018-provider-attempt-authority-and-recovery.md#concept-adr-0018-alternatives).

Unconditional same-byte recovery maximizes liveness but can duplicate a billed
call. Coordinator-mediated wakeup adds one ownership gap. Worker-mediated
Control calls invert the established readiness ordering. A durable permit makes
an ephemeral capability look replayable without proving transport. A finite
timeout improves responsiveness but provides no truth. More than one retry adds
cost and replay states without M2 evidence. Provider-specific reconciliation is
the future extensibility seam: it may add stronger evidence without weakening
the default or moving provider structures into Core.

<a id="technical-adr-0018-consequences"></a>
## Compatibility, Rollback, and Evidence

Concept: [Consequences](0018-provider-attempt-authority-and-recovery.md#concept-adr-0018-consequences).

Compatibility is behavioral, not source-breaking. Existing Model
implementations still compile; an unclassified error now fails conservatively
rather than retrying. Control's permit operation and all record kinds are
private. No provider structure crosses Core, Store, public events, progress,
diagnostics, fixtures, or operator rendering.

Required evidence includes named cases and clause-derived mutants for:

- provider invocation before durable attempt open;
- request-row-only dispatch across page boundary and recovery;
- attempt zero, attempt three, attempt two without exact attempt-one
  not-dispatched settlement, and succession resetting the count;
- worker invocation without a permit; a second fresh worker/reference request
  for the same full attempt identity; and duplicate, wrong, or stale permits;
- coordinator wakeup after Control returns and worker-initiated Control calls;
- handoff immediately before and immediately after Control's permit send;
- Control death or lost reply before and after a possible send;
- worker death before proved refusal and after possible permit;
- deadline refusal immediately before permit send and deadline after send;
- adapter `not_dispatched` before a transport canary versus the same tag after
  the canary;
- every arbitrary error, malformed tag/reply, timeout, task `DOWN`, incomplete
  stream, and recovered-open cell;
- complete reported usage, missing, partial, malformed, negative, non-integer,
  and uint64-overflow usage;
- exact remaining-allowance accounting and no false `bound_reached` or executor
  `outcome_unknown`;
- atomic settlement/accounting/conversation/next/terminal application and every
  commit-unknown boundary;
- compact unreadable-reply preflight one below, at, and above each Store limit;
- a staged request and durable reply that each fit independently while the
  nine-key callback map containing both would exceed 65,536 bytes; a mutant that
  measures the callback aggregate rather than the durable projection must fail;
- result-first, abort-first, and deadline-first ordering, including late
  evidence-only replies;
- retry opening exactly one new stream domain and no successor redispatch of an
  unresolved predecessor attempt;
- origin relay closure from settlement and no successor-fabricated closure; and
- credential-shaped raw errors absent from every prohibited plane.

The decisive non-vacuity mutations delete the production comparison or fence
each case names: call before open, send outside Control, accept a second permit,
permit attempt three, treat timeout as not-dispatched, retry recovered open,
carry attempt-one proof into attempt two, undercharge ambiguous usage, apply
settlement before its terminal pair, or close the dead predecessor stream. Each
must turn at least one protected case red, and selective mutants must name the
affected cell rather than failing on unrelated history shape.

The rollback unit is the three private record kinds, pending reducer states,
version-1 attempt allowance, Control permit path, Model error and usage
normalization, settlement/accounting projection, stream-domain retry behavior,
recovery and precedence logic, reference adapter declarations, operator and
compatibility documentation, and their tests. Restore or remove them atomically.
The prior reducer refuses these unreleased record kinds; the new reducer refuses
incompatible legacy attempt history. No Store object migration is required.
