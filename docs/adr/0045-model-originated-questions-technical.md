<a id="technical-depth"></a>
## Technical depth

Concept: [Model-originated questions](0045-model-originated-questions.md#concept).

<a id="technical-adr-0045-decision"></a>
### Contract

Concept: [Context and decision](0045-model-originated-questions.md#concept-adr-0045-decision).

A tool definition may specify `class: interaction`; absent class remains
`effect` semantically and keeps its original definition bytes. M7 admits class `interaction` only for the reviewed `loopex.ask` definition
and exact argument schema. Its new definition-format generation retains the
normal identity/schema fields and adds `class: interaction`; declare
`effect_class: read_only`, `idempotency_class: never_blind_retry`, and explicit
budgets `wall_time_ms: 600000`, `output_bytes: 16384`, `artifact_bytes: 0`.
The owner applies the stricter interaction/run limits below, not executor
dispatch defaults. Versioned definition validation admits zero artifact budget
only for this interaction class, whose results retain no output artifacts.
Other interaction identifiers/schemas refuse at
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
a distinct decline/expiry category. Preserve the exact bounded answer in
ordinary projection; ADR 0041's 2,048-byte executor-result excerpt rule does not
apply. Final request byte/token preflight still applies; irreducible oversized
content refuses before ordinary provider dispatch. Once the complete group is
eligible old history, ADR 0043 may use a marked excerpt for maintenance source.
The complete original answer remains readable, without an executor receipt or
implicit artifact reference.

**Ephemeral host interface.** Preserve released `start_session/1`, `ask/3`,
`answer/3`, history and stop semantics. Extend `answer/3` with tagged text, choice
and decline responses while retaining the choice-ID shorthand for existing
callers. Validate producer/kind through the same serial owner and mutation slot.
Creator ownership, call deadlines, `last_result`, cancellation and cleanup remain.
A manually hosted live session can answer without a callback.

| Entry point | New options and ownership |
| --- | --- |
| `start_session/1` | Startup `questions`, ADR 0048 `provider_bindings`, ADR 0049 `trace`; reject `question_responder` |
| `run/2` | Same startup options plus one-shot-only `question_responder`; consume the responder locally and pass only startup options to `start_session/1` |
| `ask/3` | Existing per-call options unchanged; startup configuration belongs to the live session |

Both `start_session/1` and `run/2` add closed Boolean option `questions`,
default false. False preserves the existing frozen tool definitions and adds
no question tool. True adds the exact reviewed question generation before
creation, except that an empty base tool profile with questions enabled
refuses, matching ADR 0049's `none` contract. This does not make existing
policy-defer interactions model questions. The one-shot wrapper with questions
enabled but no responder denies model questions before opening an interaction.

The one-shot `run/2` options gain `question_responder`, an explicit
host function taking a bounded DTO of interaction ID, prompt, kind, choice IDs/
labels and absolute expiry. It returns `{:text, binary}`, `{:choice, id}` or
`:decline`. Invalid shape or exception initiates ordinary run abort; it is not
a new question disposition. Join the worker and runtime cleanup, then return
`responder_failed` if cleanup is proved. Cleanup uncertainty takes precedence.
No failed callback leaves its question live waiting for expiry or grants authority.
The function itself stays host-local, outside durable/plain boundary data. Run it
in a supervised monitored worker outside the session owner with no provider
credential passed in its DTO. Its answer returns through the same extended `answer/3` validation path. Use one serial responder worker per pending question. On success,
decline, invalid return, exception, expiry, caller abort and run deadline, prove
the worker terminated and join it within existing cleanup grace before another
question or successful cleanup. Reject late messages by identity and runtime
epoch. If joining cannot be proved, return existing cleanup uncertainty,
not successful completion. Synchronous host callback work must not block the
owner's timer/cancellation path. Reuse the single ephemeral runtime through this
wait; do not recursively create another call/session. ADR 0039's credential,
one-call and cleanup rules otherwise remain unchanged.
Supplying a responder while `questions` is false refuses as conflicting
configuration. Abort/expiry may forcibly terminate the callback mid-effect;
there is no rollback of host effects. Non-recursion is a documented obligation
of trusted host code, not a claimed sandbox or an enforceable code-inspection
rule. The callback worker is part of the owning call's monitored cleanup tree.

<a id="technical-adr-0045-evidence"></a>
### Evidence

Concept: [Observable consequences](0045-model-originated-questions.md#concept-adr-0045-consequences).

- Commit-before-event, producer-specific lifecycle and no executor grant/job.
- Text/choice bounds, answers above 2,048 bytes preserved through restart,
  encoded-size overflow refusal, unique IDs, decline, no second policy evaluation and no
  privilege change; later tool policy still consulted.
- Answer/expiry/abort races, identical replay, conflicting reuse, late answers,
  durable restart with same pending question, truthful terminal precedence.
- New schema/generation negotiation, snapshots and independent Node client.
- Ephemeral answer success, no responder denial, exception/invalid reply,
  blocked responder, abort/deadline, late delivery and joined cleanup.
- Omitted/false question option preserves old staged tool-definition bytes;
  true selects the exact new generation, and conflicting options refuse.
- Real attended question changes the fixture's implemented behavior; a one-call
  ephemeral host demonstration answers without claiming restart persistence.

<a id="technical-adr-0045-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0045-model-originated-questions.md#concept-adr-0045-compatibility).

ADR 0044's coordinated new-generation-only policy refuses old protocol clients;
it never sends a text interaction under an unchanged schema. Unsupported
negotiation fails before attachment. Old durable
readers require exact fixtures, and new producer/text records follow the M7
backup/reader matrix. Paused deadlines and general workflows remain outside
this decision. Existing multi-prompt ephemeral sessions remain supported; the
one-shot wrapper still stops its session before returning.
