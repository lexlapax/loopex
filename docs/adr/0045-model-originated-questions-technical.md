<a id="technical-depth"></a>
## Technical depth

Concept: [Model-originated questions](0045-model-originated-questions.md#concept).

<a id="technical-adr-0045-decision"></a>
### Contract

Concept: [Context and decision](0045-model-originated-questions.md#concept-adr-0045-decision).

A tool definition may specify `class: interaction`; absent class remains
`effect` semantically and keeps its original definition bytes. M7 admits class `interaction` only for the reviewed `loopex.ask` definition
and exact argument schema. Other interaction identifiers/schemas refuse at
registration; no generic owner dispatch framework is implied. Reference `loopex.ask` arguments
are `question` nonempty UTF-8 <=2 KiB and optional `choices`, one to eight
nonempty labels <=256 bytes. Derive unique stable choice IDs `choice-1` through
`choice-8` by order; duplicate labels refuse. No choices means kind `text`.

A text answer is `{text: nonempty UTF-8 <=8 KiB}`. Choice responses use the
stable choice ID. Explicit operator decline uses a separate `disposition: declined`
response, not a sentinel answer string. This additive response branch is included
in protocol vectors. Retain producer `model_tool` versus `policy_defer` in durable
state, argument digest, interaction identity and original call identity. Existing
ADR 0024 answer/admission/receipt digests and slot limits apply.

After validated arguments and policy `allow`, commit pending interaction before
publication. Build no executor intent/grant/job. Policy `deny` returns a denial;
policy `defer` for this tool resolves `policy_unavailable`, since a single call
cannot create nested questions. No second policy evaluation follows a model-tool
answer; policy-defer interactions retain their existing reevaluation. An answer
never grants a later effect.

Persist expiry as `min(created_at_ms + 600000, run_deadline_at_ms,
optional caller_deadline_at_ms)`. No provider invocation is in flight while
waiting. For `producer=model_tool`, one transaction settles interaction disposition,
original tool terminal result, response command identity/digest where present,
and the next run action. Terminal fields are producer, interaction/run/turn/call
identities, disposition, answer text or choice ID/label if answered, response
command ID/digest when supplied, and settlement sequence. No policy resolution
is owed. The open slot is released and `open_interaction` becomes null at that
same cursor; terminal facts remain in events/replay. Text/decline branches apply
only to model questions. Policy-defer keeps its existing choice-only response,
answered-but-resolution-owed state and bounded reevaluation. Abort/deadline precedence is the existing terminal rule and prevents
a new provider turn. Identical command replay returns historical disposition;
conflicting ID reuse, independent second answer and late answer refuse without
mutation. Snapshots and replay preserve pending producer/kind/choices and terminal
answer disposition; model-facing result includes the chosen label or text and
a distinct decline/expiry category.

**Ephemeral host interface.** `run/2` options gain `question_responder`, an explicit
host function taking a bounded DTO of interaction ID, prompt, kind, choice IDs/
labels and absolute expiry. It returns `{:text, binary}`, `{:choice, id}` or
`:decline`; invalid shape/exception becomes `responder_failed`, never a grant.
The function itself stays host-local, outside durable/plain boundary data. Run it
in a supervised monitored worker outside the session owner with no provider
credential passed in its DTO. Its answer returns through normal interaction
validation. Use one serial responder worker per pending question. On success,
decline, invalid return, exception, expiry, caller abort and run deadline, prove
the worker terminated and join it within existing cleanup grace before another
question or successful cleanup. Reject late messages by identity and runtime
epoch. If joining cannot be proved, return existing cleanup uncertainty,
not successful completion. Synchronous host callback work must not block the
owner's timer/cancellation path. Reuse the single ephemeral runtime through this
wait; do not recursively create another call/session. ADR 0039's credential,
one-call and cleanup rules otherwise remain unchanged.

<a id="technical-adr-0045-evidence"></a>
### Evidence

Concept: [Observable consequences](0045-model-originated-questions.md#concept-adr-0045-consequences).

- Commit-before-event, producer-specific lifecycle and no executor grant/job.
- Text/choice bounds, unique IDs, decline, no second policy evaluation and no
  privilege change; later tool policy still consulted.
- Answer/expiry/abort races, identical replay, conflicting reuse, late answers,
  durable restart with same pending question, truthful terminal precedence.
- New schema/generation negotiation, snapshots and independent Node client.
- Ephemeral answer success, no responder denial, exception/invalid reply,
  blocked responder, abort/deadline, late delivery and joined cleanup.
- Real attended question changes the fixture's implemented behavior; a one-call
  ephemeral host demonstration answers without claiming restart persistence.

<a id="technical-adr-0045-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0045-model-originated-questions.md#concept-adr-0045-compatibility).

An old protocol client must not silently receive a text interaction through an
unchanged schema. Unsupported negotiation fails before attachment. Old durable
readers require exact fixtures, and new producer/text records follow the M7
backup/reader matrix. Paused deadlines, general workflows and reusable ephemeral
conversations remain outside this decision.
