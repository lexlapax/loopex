<a id="technical-depth"></a>
## Technical depth

Concept: [Typed decision models as policy inputs](0035-typed-decision-models-as-policy-inputs.md#concept).

<a id="technical-adr-0035-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0035-typed-decision-models-as-policy-inputs.md#concept-adr-0035-decision).

### What the model is, exactly

Everything below was read from `req_llm` 1.24.0's own source on 2026-09-19,
not from a description of it.

- `ReqLLM.Evaluation.evaluate/4`, reached as `ReqLLM.evaluate/4`, takes a model
  input, a state that is a string, a map or a list, a map of questions, and a
  keyword option list. Its module documentation calls it "a model call, not a
  test run" and says an evaluation model need not support chat generation.
- A question is `%{type: :boolean | :choice | :score, instructions: …,
  criteria: …}`, keyed by the name the answer comes back under. `:choice`
  carries its options in `criteria`.
- The answers arrive in `result.object` under the question's name as **string**
  keys, with probabilities and confidence where the type has them. The provider
  normalises its own `noul` answer into a `probability` member. The original
  provider payload stays in `provider_meta.raw_response`.
- The options the schema admits, and no others, are `api_key`, `base_url`,
  `receive_timeout`, `total_timeout`, `max_retries`, `req_http_options`,
  `fixture` and `telemetry`; an unrecognised key is an error rather than being
  ignored.
- `ReqLLM.Providers.TypeSafe` declares `default_base_url
  "https://api.typesafe.ai"`, `default_env_key "TYPESAFE_API_KEY"`, posts to
  `/v1/systemone` with an `authorization: Bearer …` header, and refuses every
  operation except `:evaluate` with an explicit parameter error. It supports no
  chat, no text generation and no arbitrary JSON schema.
- `req_llm` 1.24.0 requires `llm_db >= 2026.9.3`, so the evaluation seam is not
  reachable on an older `llm_db`.

TypeSafe's own guidance, which shapes how the questions are written rather than
what the code does: questions atomic, batched into one call, their text stable
so probabilities stay comparable between calls, and actions gated on confidence
against thresholds the caller owns.

### The invariant, and where it is enforced

**A typed answer is data on the way to a decision, never the decision.**
Concretely:

- Every seam takes the answer as an *input to a host-owned function*. At the
  executor seam that function is the host's `Loopex.Policy` implementation,
  which `Loopex.Policy` already resolves exhaustively and fails closed on:
  anything but a well-shaped `{:allow, context}` or an enumerated
  `{:deny, category}` becomes `{:deny, :policy_unavailable}`, and a raising,
  exiting or slow callback denies. That table is unchanged and is what makes
  the invariant enforceable rather than merely stated — a policy that consults
  an evaluation and mishandles it denies.
- The thresholds are the host's. Loopex fixes no probability, no confidence
  floor and no default answer, because a threshold is a policy judgment about
  what the operator is willing to risk, and Loopex does not own those.
- An evaluation result never reaches the executor, a grant, a lease, an epoch,
  a fence or a receipt. It is not an argument to anything that validates
  authority.
- A missing answer is not a default answer. Where an evaluation does not
  return — no credential, refusal, timeout, malformed shape — the host decides
  exactly as it would with no evaluation configured. No seam has a code path
  that exists only when an answer arrives.

### The state that is sent

The state is bounded, redacted, provenance-typed data the runtime already
holds, staged under the same context-admission discipline that governs
anything else sent to a provider. The evaluation adds no new class of
sendable data and no new path to it: if something may not be staged for a
completion, it may not be staged for an evaluation. Credentials, PIDs, raw
workspace content that admission did not admit, and anything outside the
bounded plain-data contract stay out by the rules that already exclude them.

### Credentials

`TYPESAFE_API_KEY` is a **second** provider credential, and this is the one
place where this decision constrains an earlier one.
[ADR 0034](0034-provider-credential-handoff-over-bootstrap-channel.md#concept)
fixes a per-invocation credential reference the host owns and the sender
resolves. With a second provider it has to be **per provider**: the reference a
call carries names which credential is wanted, and a host composing both
providers supplies two references rather than one ambient value per process.
Nothing about resolution, custody, rotation or the failure table changes; only
the arity of what a host supplies does. This decision therefore depends on
ADR 0034 and cannot be implemented before it is accepted and its change has
landed.

### Seams, in the order they are worth doing

| # | Seam | What the questions ask | Who consumes the answer |
| --- | --- | --- | --- |
| 1 | Executor admission triage | Destructive; reaches outside the workspace; apparent intent; risk level | The host's `Loopex.Policy` implementation, with its own thresholds, through the existing seam the reference `AllowAll` and `Ask` occupy |
| 2 | Model routing per turn | Which model this turn should go to | The host's routing choice; the chosen model and the answer that informed it are journaled as a fact beside the run's existing provenance |
| 3 | Interaction escalation | "Does this need the operator", as a probability | The host that already owns whether to ask |
| 4 | Session classification | What kind of work a session is, for listing and residency | The daemon, over sessions it already holds; a daemon-side convenience with no durable effect |
| 5 | Offline transcript scoring | Whatever the release check wants to measure about retained transcripts | The release check, over retained evidence, on no live path |

Seams 1 to 4 belong to the milestone after M5 and are implemented in that
order, because each earlier one is the cheaper proof of the same invariant.
Seam 5 is the one piece admitted earlier; see below.

### The one experiment allowed inside M5

M5's provider workstream already moves to `req_llm` 1.24 for other reasons, so
the evaluation seam becomes reachable there. One bounded experiment is allowed
inside it, and only this one: an **offline scorer in the release check's
real-provider case** that calls `ReqLLM.evaluate/4` against the real endpoint
over retained transcript material, records the typed answers and the reported
`usage`, and touches no part of the agent loop. It exists to prove the 1.24 API
against the real service and to take the first latency and price measurement,
which this decision otherwise has to assert without evidence. It admits no
seam, changes no policy, journals nothing durable, and gates nothing: if it is
removed, the release check is exactly what it was. Anything beyond it waits for
this ADR's acceptance.

### Evidence

The negatives carry the decision and are written before the seams:

- for every seam, an answer at every extreme — probability 0, probability 1,
  confidence 1.0, a `:choice` concentrated on one option — produces exactly the
  decision the host would have made without an evaluation, proved by running
  each case twice, with the evaluation stubbed at that extreme and with it
  absent, and requiring identical decisions and identical durable records;
- no evaluation result appears in a grant, a lease, an epoch, a fence, a
  receipt or any executor argument, proved by the same drift-style scan that
  pins other forbidden reaches;
- a missing credential, a refusing provider, a timeout, an unrecognised option,
  a malformed `object` and an answer for a question that was not asked each
  leave every decision unchanged and are each reported as a bounded non-secret
  reason;
- nothing an evaluation returns shortens a path that would otherwise ask the
  operator;
- the state sent is proved to contain only what context admission admitted.

The real-provider case proves one call to the real endpoint returns the three
typed shapes and that `usage` is recorded. Latency and price are reported from
it as measurements, never as thresholds a later test may be weakened to meet.

### Alternatives

Parsing a text model's prose for the same judgments was rejected: it is
uncalibrated, it moves with phrasing in ways nothing can bound, and it produces
no value to journal, so a later reader cannot compare two runs. A text model
with a structured-output schema was rejected because a schema fixes the shape
of an answer but not its calibration — there is no probability and no
confidence to threshold on — and it costs a full generation to get less.
Putting thresholds in Loopex rather than the host was rejected because a
threshold is a statement about acceptable risk, which the development contract
assigns to host policy along with `allow`, `deny` and `defer`. Letting a
high-confidence answer skip the policy call was rejected outright: it is the
exemption predicate ADR 0009 refuses, arriving with a number attached.

<a id="technical-adr-0035-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0035-typed-decision-models-as-policy-inputs.md#concept-adr-0035-consequences).

Nothing public changes. The `Loopex.Policy` and `Loopex.Model` callbacks, the
public protocol and its generations, public events, snapshots, artifacts, the
executor protocol and every durable record are untouched. A runtime with no
evaluation configured is byte-for-byte the runtime that exists today. The one
compatibility effect is on host composition, and it is ADR 0034's: a credential
reference becomes per provider.

Rollback is removing the evaluation. Every seam is an input, so a host that
stops asking decides as it did before by the same path; a journaled answer
remains a true record of what was observed at the time and is not a premise
anything later depends on, so nothing has to be migrated or repaired. The
offline scorer, if it exists from M5, is deleted with no effect on the release
check's other cases.

Acceptance binds this complete pair at the exact candidate the maintainer names
in the governance record. Its claims remain unproved until the tests above
exist and pass and the real-provider case has run.
